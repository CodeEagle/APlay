//
//  ID3Parser.swift
//  APlay
//
//  Created by lincoln on 2018/6/6.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation
final class ID3Parser: @unchecked Sendable {
    private lazy var _outputStream = Delegated<MetadataParser.Event, Void>()
    private lazy var _data = Data()
    private lazy var _queue = DispatchQueue(concurrentName: "ID3Parser")
    // parser stuff
    private lazy var _nextParseStartAt = 0
    private lazy var _metadatas: [Version: [MetadataParser.Item]] = [:]
    private lazy var _isSkippedExtendedHeader = false
    private lazy var _isDeunsynchronised = false
    private unowned let _config: ConfigurationCompatible

    private var _v2Info: ID3V2? {
        didSet {
            guard let info = _v2Info else { return }
            debug_log("\(info)")
        }
    }

    private var _v2State = MetadataParser.State.initial { didSet { dispatchEvent() } }
    private var _v1State = MetadataParser.State.initial { didSet { dispatchEvent() } }

    init(config: ConfigurationCompatible) {
        _config = config
    }
}

// MARK: - State Handler

private extension ID3Parser {
    func dispatchEvent() {
        guard _v1State.isDone, _v2State.isDone else { return }
        _data = Data()
        var size = _v2Info?.size ?? 0
        if case MetadataParser.State.complete = _v1State {
            size += 128
        }
        outputStream.call(.tagSize(size))
        var metas: [MetadataParser.Item] = _metadatas[.v1] ?? (_metadatas[.v11] ?? [])
        for (ver, list) in _metadatas {
            guard ver != .v1, ver != .v11 else { continue }
            metas.append(contentsOf: list)
        }
        outputStream.call(.metadata(metas))
        debug_log("ID3Parser parse done, read \(_nextParseStartAt) bytes")
    }
}

// MARK: - MetadataParserCompatible

extension ID3Parser: MetadataParserCompatible {
    var outputStream: Delegated<MetadataParser.Event, Void> { return _outputStream }

    func acceptInput(data: UnsafeMutablePointer<UInt8>, count: UInt32) {
        guard _v2State.isNeedData else { return }
        // Copy synchronously so the raw pointer never crosses an async boundary.
        let chunk = Data(bytes: data, count: Int(count))
        _queue.async(flags: .barrier) { self.appendTagData(chunk) }
        _queue.sync {
            if _v2State == .initial, _data.count < 10 { return }
            parse()
        }
    }

    func parseID3V1Tag(at url: URL) {
        guard _v1State.isDone == false else { return }
        let scheme = url.scheme?.lowercased()
        let isLocal = scheme == "file"
        _queue.async(flags: .barrier) {
            isLocal ? self.processingID3V1FromLocal(url: url) : self.processingID3V1FromRemote(url: url)
        }
    }
}

// MARK: - ID3v2 Parse

extension ID3Parser {
    private func appendTagData(_ chunk: Data) {
        if let size = _v2Info?.size, _data.count >= size, _v2State != .initial { return }
        _data.append(chunk)
    }

    /// <http://id3.org/id3v2-00>, <http://id3.org/id3v2.3.0>, <http://id3.org/id3v2.4.0-structure>
    private func parse() {
        // Parser ID3V2 Header
        if _v2State == .initial {
            guard let header = String(data: _data[ID3V2.header], encoding: .ascii), header == ID3V2.tag else {
                _v2State = .error("Not A ID3V2 File")
                return
            }
            let headerCount = ID3V2.header.count
            let length = ID3V2.headerFrameLength - headerCount
            _data = _data.advanced(by: headerCount)
            _v2Info = ID3V2(_data[0 ..< length])
            _data = _data.advanced(by: length)
            _nextParseStartAt += ID3V2.headerFrameLength
            _v2State = .parsering
        }
        guard _v2State == .parsering, let info = _v2Info else { return }
        // Undo v2.2/v2.3 unsynchronisation once, over the whole tag body, so the
        // frame sizes and bodies read as written. Only applied once the tag is
        // fully buffered, since a partial body would leave half-desynchronised
        // bytes next to freshly appended ones. v2.4 sizes are already sync-safe.
        if info.version < 4, info.flags.contains(.unsynchronisation), _isDeunsynchronised == false, _data.count >= Int(info.size) - ID3V2.headerFrameLength {
            _isDeunsynchronised = true
            _data = Data(deunsynchronise(_data))
        }
        // Skip Extended Header
        if info.version >= 3, _isSkippedExtendedHeader == false, info.hasExtendedHeader {
            guard _data.count >= 4 else { return }
            let size = Int(_data[0 ..< 4].compactMap({ $0 }).unpack())
            guard _data.count >= size else { return }
            _data = _data.advanced(by: size)
        }
        // Start Parse Tag
        while true {
            // The remaining buffer in not enough for a frame, consider it as padding, parse complete
            guard _data.count >= info.minimumByteForFrame, _nextParseStartAt < Int(info.size) else {
                _v2State = .complete
                break
            }
            // Retrieve Frame Name And Calculate Frame Size
            var frameSize: Int = 0
            let frameNameData: Data
            var readlength = 0
            if info.version >= 3 {
                frameNameData = _data[0 ..< 4]
                readlength = 4
            } else {
                frameNameData = _data[0 ..< 3]
                readlength = 3
            }
            guard let frameName = String(data: frameNameData, encoding: .utf8)?.trimZeroTerminator() else {
                _v2State = .error("pasering wrong frame")
                break
            }

            let pos = readlength
            if info.version == 4 {
                frameSize = Int([_data[pos] & 0x7F, _data[pos + 1] & 0x7F, _data[pos + 2] & 0x7F, _data[pos + 3] & 0x7F].unpack(offsetSize: 7))
                readlength += 6
            } else if info.version == 3 {
                /*
                 Frame ID       $xx xx xx xx (four characters)
                 Size           $xx xx xx xx
                 Flags          $xx xx
                 */
                frameSize = Int([_data[pos], _data[pos + 1], _data[pos + 2], _data[pos + 3]].unpack())
                // skip 2 byte for flags
                readlength += 6
            } else {
                /*
                 Frame size                   $xx xx xx
                 */
                frameSize = Int([_data[pos], _data[pos + 1], _data[pos + 2]].unpack())
                readlength += 3
            }

            // Maybe just padding, add minimum frame size and continue parsing
            guard frameSize > 0 else {
                let realLength: Int
                if info.version >= 3 {
                    // No flags bytes, minus 2 bytes
                    realLength = readlength - 2
                } else {
                    realLength = readlength
                }
                _data = _data.advanced(by: realLength)
                _nextParseStartAt += realLength
                continue
            }

            // Make sure data size is enough for parsing
            guard _data.count >= readlength + frameSize else {
                if frameName == "", Int(info.size) - _nextParseStartAt < info.minimumByteForFrame {
                    _v2State = .complete
                }
                break
            }

            // If frame name is empty..., maybe is end of file
            if frameName == "", Int(info.size) - _nextParseStartAt < info.minimumByteForFrame {
                _v2State = .complete
                break
            }
            _data = _data.advanced(by: readlength)
            _nextParseStartAt += readlength
            readlength = 0

            // Text encoding is counted in frame size
            let encodingIndex = _data[0]
            readlength = 1

            if frameName == "APIC" || frameName == "PIC" {
                /*
                 <Header for 'Attached picture', ID: "APIC">
                 Text encoding      $xx
                 MIME type          <text string> $00
                 Picture type       $xx
                 Description        <text string according to encoding> $00 (00)
                 Picture data       <binary data>
                 */
                let mimeTypeStartIndex = readlength
                var mimeTypeEndIndex = mimeTypeStartIndex
                while mimeTypeEndIndex < _data.count, _data[mimeTypeEndIndex] != 0 {
                    mimeTypeEndIndex += 1
                }
                guard mimeTypeEndIndex < _data.count else {
                    _v2State = .error("APIC mime type is not terminated")
                    break
                }

                guard let mimeType = String(data: _data[mimeTypeStartIndex ..< mimeTypeEndIndex], encoding: .utf8) else {
                    _v2State = .error("Not retreive mime type for image")
                    break
                }

                // Picture type follows the mime type's terminator.
                let picTypeIndex = mimeTypeEndIndex + 1
                guard picTypeIndex < _data.count else {
                    _v2State = .error("APIC picture type is missing")
                    break
                }
                let picType = MetadataParser.PictureType(rawValue: _data[picTypeIndex]) ?? .undifined
                // Description is a \0-terminated string; skip past it.
                var descEnd = picTypeIndex + 1
                while descEnd < _data.count, _data[descEnd] != 0 {
                    descEnd += 1
                }
                guard descEnd < _data.count else {
                    _v2State = .error("APIC description is not terminated")
                    break
                }
                readlength = descEnd + 1
                // The picture occupies the rest of the frame body, so the slice
                // ends at the frame size, not at `readlength + frameSize`.
                let data = Data(_data[readlength ..< frameSize])
                var meta = _metadatas[info.ver] ?? []
                meta.append(.cover(data))
                _metadatas[info.ver] = meta
                _config.logger.log("(\(frameName))(\(mimeType))(\(picType))(\(frameSize)bytes)", to: .metadataParser)
            } else {
                if let encoding = StringEncoding(rawValue: encodingIndex) {
                    var d = _data[readlength ..< frameSize].compactMap({ $0 })
                    if let text = CFStringCreateWithBytes(kCFAllocatorDefault, &d, d.count, encoding.enc, encoding.isExternalRepresentation) as String?, text.isEmpty == false {
                        let value = text.trimZeroTerminator()
                        var meta = _metadatas[info.ver] ?? []
                        switch frameName {
                        case "TIT2", "TT2": meta.append(.title(value))
                        case "TALB", "TAL": meta.append(.album(value))
                        case "TPE1", "TP1": meta.append(.artist(value))
                        case "TRCK", "TRK": meta.append(.track(value))
                        case "COMM", "COM": meta.append(.comment(value))
                        case "TDAT", "TDA": meta.append(.year(value))
                        default: meta.append(.other([frameName: value]))
                        }
                        _metadatas[info.ver] = meta
                        _config.logger.log("(\(frameName))(\(frameSize)bytes)=\"\(value)\"", to: .metadataParser)
                    }
                } else {
                    _config.logger.log("(\(frameName))(\(frameSize)bytes)", to: .metadataParser)
                }
            }
            _data = _data.advanced(by: frameSize)
            _nextParseStartAt += frameSize
        }
    }
}

// MARK: - Unsynchronisation

private extension ID3Parser {
    /// Removes the $00 padding inserted after every $FF (ID3v2.2/2.3 scheme).
    func deunsynchronise(_ data: Data) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var previousWasFF = false
        for byte in data {
            if previousWasFF, byte == 0 {
                previousWasFF = false
                continue
            }
            out.append(byte)
            previousWasFF = (byte == 0xFF)
        }
        return out
    }
}

// MARK: - ID3V1 Logic

private extension ID3Parser {
    func processingID3V1FromRemote(url: URL) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringCacheData, timeoutInterval: 60)
        request.setValue("bytes=-128", forHTTPHeaderField: "Range")
        _config.session.dataTask(with: request) { [weak self] data, _, _ in
            guard let d = data, let sself = self else { return }
            sself.processingID3V1(data: d)
        }.resume()
    }

    func processingID3V1FromLocal(url: URL) {
        let name = url.asCFunctionString()
        guard let file = fopen(name, "r") else {
            _v1State = .error("can not open file at \(url)")
            return
        }
        defer { fclose(file) }
        fseek(file, -128, SEEK_END)
        var bytes: [UInt8] = Array(repeating: 0, count: 128)
        fread(&bytes, 1, 128, file)
        processingID3V1(data: Data(bytes))
    }

    // Ref: <http://id3.org/ID3v1>
    func processingID3V1(data: Data) {
        func emptyV1Tag() {
            _v1State = .error("not validate id3v1 tag")
        }
        guard data.count == 128 else {
            emptyV1Tag()
            return
        }
        let isVersion11 = data[ID3V1.flagv11] == 0
        let version = isVersion11 ? Version.v11 : Version.v1
        let header = String(data: data[ID3V1.header], encoding: .utf8)
        guard header == ID3V1.tag else {
            emptyV1Tag()
            return
        }
        let enc: String.Encoding = .isoLatin1
        let basic: [Range<Int>] = [ID3V1.title, ID3V1.artist, ID3V1.album, ID3V1.year]
        var metas: [MetadataParser.Item] = []
        for (index, range) in basic.enumerated() {
            let sub = data[range]
            guard let content = String(data: sub, encoding: enc)?.trimZeroTerminator(), content.isEmpty == false else { continue }
            switch index {
            case 0: metas.append(.title(content))
            case 1: metas.append(.artist(content))
            case 2: metas.append(.album(content))
            case 3: metas.append(.year(content))
            default: break
            }
        }
        if isVersion11 {
            let sub = data[ID3V1.commentv11]
            if let comment = String(data: sub, encoding: enc)?.trimZeroTerminator(), comment.isEmpty == false {
                metas.append(.comment(comment))
            }
            let trackData = data[ID3V1.trackv11]
            metas.append(.track("\(trackData)"))
        } else {
            let sub = data[ID3V1.comment]
            if let comment = String(data: sub, encoding: enc)?.trimZeroTerminator(), comment.isEmpty == false {
                metas.append(.comment(comment))
            }
        }
        let genre = data[ID3V1.genre]
        let style: String
        if let value = MetadataParser.genre[ap_safe: Int(genre)] {
            style = value
        } else {
            style = "\(genre)"
        }
        metas.append(.genre(style))
        _metadatas[version] = metas
        _v1State = .complete
    }
}

// MARK: - Models

private extension ID3Parser {
    enum Version: Int {
        case v1
        case v11
        case v22
        case v23
        case v24
    }

    enum StringEncoding: UInt8 {
        case isoLatin1
        case utf16WithExternalRepresentation
        case utf16be
        case utf8

        var isExternalRepresentation: Bool {
            switch self {
            case .utf16WithExternalRepresentation: return true
            default: return false
            }
        }

        var enc: CFStringEncoding {
            var encoding: CFStringBuiltInEncodings
            switch self {
            case .isoLatin1: encoding = .isoLatin1
            case .utf16WithExternalRepresentation: encoding = .UTF16
            case .utf16be: encoding = .UTF16BE
            case .utf8: encoding = .UTF8
            }
            return encoding.rawValue
        }
    }

    struct ID3V2 {
        static let headerFrameLength = 10
        static let tag: String = "ID3"
        static var header: Range<Int> { return Range(0 ... 2) }
        static var size: Range<Int> { return Range(6 ... 9) }

        let ver: Version
        let version: UInt8
        let reversion: UInt8
        let flags: Flag
        var hasExtendedHeader: Bool {
            return flags.contains(.extendedHeader)
        }

        let size: UInt32

        var minimumByteForFrame: Int {
            // A tag must contain at least one frame. A frame must be at least 1 byte big, excluding the 6-byte header.
            if version == 2 { return 7 }
            /// A tag must contain at least one frame. A frame must be at least 1 byte big, excluding the 10-byteheader.
            else if version == 3 || version == 4 { return 11 }
            return 7
        }

        init(_ bytes: Data) {
            let data = bytes
            let rawVersion = data[0]
            reversion = data[1]
            let bit7HasData = (data[2] & 0b1000_0000) != 0
            let bit6HasData = (data[2] & 0b0100_0000) != 0
            var rawFlags: Flag = []
            var rawSize = [data[3] & 0x7F, data[4] & 0x7F, data[5] & 0x7F, data[6] & 0x7F].unpack(offsetSize: 7)
            if bit7HasData { rawFlags = rawFlags.union(.unsynchronisation) }
            if rawVersion == 2 {
                if bit6HasData { rawFlags = rawFlags.union(.compression) }
            } else if rawVersion == 3 || rawVersion == 4 {
                if bit6HasData { rawFlags = rawFlags.union(.extendedHeader) }
                let bit5HasData = (data[2] & 0b0010_0000) != 0
                if bit5HasData { rawFlags = rawFlags.union(.experimentalIndicator) }
                if rawVersion == 4 {
                    let bit4HasData = (data[2] & 0b0001_0000) != 0
                    if bit4HasData { rawFlags = rawFlags.union(.footerPresent) }
                }
                if rawFlags.contains(.footerPresent) {
                    rawSize += 10 // footer size
                }
            }
            version = rawVersion
            ver = Version(rawValue: Int(version)) ?? .v23
            size = rawSize + 10 // 10 for header bytes
            flags = rawFlags
        }

        struct Flag: OptionSet {
            let rawValue: Int
            static let unsynchronisation = Flag(rawValue: 1 << 0)
            static let compression = Flag(rawValue: 1 << 1)
            // 2.3
            static let extendedHeader = Flag(rawValue: 1 << 2)
            static let experimentalIndicator = Flag(rawValue: 1 << 3)
            // 2.4
            static let footerPresent = Flag(rawValue: 1 << 4)
        }
    }

    struct ID3V1 {
        static let tag: String = "TAG"
        static var header: Range<Int> { return Range(0 ... 2) }
        static var title: Range<Int> { return Range(3 ... 32) }
        static var artist: Range<Int> { return Range(33 ... 62) }
        static var album: Range<Int> { return Range(63 ... 92) }
        static var year: Range<Int> { return Range(93 ... 96) }
        static var comment: Range<Int> { return Range(97 ... 126) }
        static var commentv11: Range<Int> { return Range(97 ... 124) }
        static var flagv11: Int { return 125 }
        static var trackv11: Int { return 126 }
        static var genre: Int { return 127 }
    }
}
