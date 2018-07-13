//
//  FlacParser.swift
//  APlay
//
//  Created by lincoln on 2018/5/29.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import CoreGraphics
import Foundation

final class FlacParser {
    private lazy var _outputStream = Delegated<MetadataParser.Event, Void>()
    private lazy var _data = Data()
    private lazy var _backupHeaderData = Data()
    private lazy var _isHeaderParserd = false
    private lazy var _state: MetadataParser.State = .initial
    private lazy var _queue = DispatchQueue(concurrentName: "FlacParser")
    private var _flacMetadata: FlacMetadata?
    init(config _: ConfigurationCompatible) {}
}

extension FlacParser: MetadataParserCompatible {
    var outputStream: Delegated<MetadataParser.Event, Void> {
        return _outputStream
    }

    func acceptInput(data: UnsafeMutablePointer<UInt8>, count: UInt32) {
        guard _state.isNeedData else { return }
        _queue.async(flags: .barrier) { self.appendTagData(data, count: count) }
        _queue.sync {
            if _state == .initial, _data.count < 4 { return }
            parse()
        }
    }
}

// MARK: - Private

extension FlacParser {
    private func appendTagData(_ data: UnsafeMutablePointer<UInt8>, count: UInt32) {
        let bytesSize = Int(count)
        let raw = malloc(bytesSize)!.assumingMemoryBound(to: UInt8.self)
        defer { free(raw) }
        memcpy(raw, data, bytesSize)
        let dat = Data(bytes: raw, count: bytesSize)
        _data.append(dat)
        _backupHeaderData.append(dat)
    }

    private func parse() {
        if _state == .initial {
            guard let head = String(data: _data[0 ..< 4], encoding: .ascii), head == FlacMetadata.tag else {
                _state = .error("Not a flac file")
                return
            }
            _data = _data.advanced(by: 4)
            _state = .parsering
        }
        var hasBlock = true
        while hasBlock {
            guard _data.count >= FlacMetadata.Header.size else { return }
            let bytes = _data[0 ..< FlacMetadata.Header.size]
            let header = FlacMetadata.Header(bytes: bytes)
            let blockSize = Int(header.metadataBlockDataSize)
            let blockLengthPosition = FlacMetadata.Header.size + blockSize
            guard _data.count >= blockLengthPosition else { return }
            _data = _data.advanced(by: FlacMetadata.Header.size)
            switch header.blockType {
            case .streamInfo:
                let streamInfo = FlacMetadata.StreamInfo(data: _data, header: header)
                _flacMetadata = FlacMetadata(streamInfo: streamInfo)
            case .seektable:
                let tables = FlacMetadata.SeekTable(bytes: _data, header: header)
                _flacMetadata?.seekTable = tables
            case .padding:
                let padding = FlacMetadata.Padding(header: header, length: UInt32(header.metadataBlockDataSize))
                _flacMetadata?.addPadding(padding)
            case .application:
                let app = FlacMetadata.Application(bytes: _data, header: header)
                _flacMetadata?.application = app
            case .cueSheet:
                let cue = FlacMetadata.CUESheet(bytes: _data, header: header)
                _flacMetadata?.cueSheet = cue
            case .vorbisComments:
                let comment = FlacMetadata.VorbisComments(bytes: _data, header: header)
                _flacMetadata?.vorbisComments = comment
            case .picture:
                let picture = FlacMetadata.Picture(bytes: _data, header: header)
                _flacMetadata?.picture = picture
            case .undifined: print("Flac metadta header error, undifined block type")
            }
            _data = _data.advanced(by: blockSize)
            hasBlock = header.isLastMetadataBlock == false
            if hasBlock == false {
                _state = .complete
                if var value = _flacMetadata {
                    _outputStream.call(.tagSize(value.totalSize()))
                    if let meta = value.vorbisComments?.asMetadata() {
                        _outputStream.call(.metadata(meta))
                    }
                    let size = value.totalSize()
                    value.headerData = Data(_backupHeaderData[0 ..< Int(size)])
                    _backupHeaderData = Data()
                    _outputStream.call(.flac(value))
                }
                _outputStream.call(.end)
            }
        }
    }
}

// MARK: - FlacMetadata

/// https://xiph.org/flac/format.html#metadata_block_data
public struct FlacMetadata {
    static let tag = "fLaC"
    public let streamInfo: StreamInfo
    fileprivate(set) var headerData: Data = Data()
    public fileprivate(set) var vorbisComments: VorbisComments?
    public fileprivate(set) var picture: Picture?
    public fileprivate(set) var application: Application?
    public fileprivate(set) var seekTable: SeekTable?
    public fileprivate(set) var cueSheet: CUESheet?
    public fileprivate(set) var paddings: [Padding]?

    init(streamInfo: StreamInfo) { self.streamInfo = streamInfo }

    mutating func addPadding(_ padding: Padding) {
        var value = paddings ?? [Padding]()
        value.append(padding)
        paddings = value
    }

    func totalSize() -> UInt32 {
        var total: UInt32 = 4
        let headers = [streamInfo.header, vorbisComments?.header, picture?.header, application?.header, seekTable?.header, cueSheet?.header].compactMap({ $0 }) + (paddings?.compactMap({ $0.header }) ?? [])
        total += headers.reduce(0, { $0 + $1.metadataBlockDataSize })
        total += UInt32(headers.count * Header.size)
        return total
    }

    func nearestOffset(for time: TimeInterval) -> (TimeInterval, UInt64)? {
        guard let table = seekTable, table.points.count > 0 else { return nil }
        var delta: TimeInterval = 999
        var targetTime: TimeInterval = time
        var offset: UInt64 = 0
        let sampleRate = TimeInterval(streamInfo.sampleRate)
        for point in table.points {
            let pointTime = TimeInterval(point.sampleNumber) / sampleRate
            let pointDelta = abs(time - pointTime)
            if pointDelta < delta {
                delta = pointDelta
                targetTime = pointTime
                offset = point.streamOffset
            }
        }
        return (targetTime, offset)
    }

    public struct Header {
        static let size = 4
        public let isLastMetadataBlock: Bool
        public let blockType: BlockType
        public let metadataBlockDataSize: UInt32

        public enum BlockType: UInt8 {
            case streamInfo
            case padding
            case application
            case seektable
            case vorbisComments
            case cueSheet
            case picture
            case undifined

            init?(bytes: UInt8) {
                let type = bytes & 0x7F
                if let value = BlockType(rawValue: type) { self = value }
                else { return nil }
            }
        }

        public init(bytes: Data) {
            var data = bytes.advanced(by: 0)
            isLastMetadataBlock = (data[0] & 0x80) != 0
            let type = BlockType(bytes: data[0]) ?? .undifined
            blockType = type
            data = data.advanced(by: 1)
            metadataBlockDataSize = Array(data[0 ..< 3]).unpack()
        }
    }

    public struct StreamInfo {
        public let header: Header
        public let minimumBlockSize: UInt32
        public let maximumBlockSize: UInt32
        public let minimumFrameSize: UInt32
        public let maximumFrameSize: UInt32
        public let sampleRate: UInt32
        public let channels: UInt32
        public let bitsPerSample: UInt32
        public let totalSamples: UInt64
        public let md5: String

        // https://github.com/xiph/flac/blob/64b7142a3601717a533cd0d7e6ef19f8aaba3db8/src/libFLAC/metadata_iterators.c#L2177-L2200
        init(data: Data, header: Header) {
            self.header = header
            let point0 = data.startIndex
            let point2 = point0 + 2
            let point4 = point2 + 2
            let point7 = point4 + 3
            let point10 = point7 + 3
            let point12 = point10 + 2
            let point13 = point12 + 1
            let point14 = point13 + 1
            let point18 = point14 + 4
            let point34 = point18 + 16

            minimumBlockSize = Array(data[point0 ..< point2]).unpack()
            maximumBlockSize = Array(data[point2 ..< point4]).unpack()
            minimumFrameSize = Array(data[point4 ..< point7]).unpack()
            maximumFrameSize = Array(data[point7 ..< point10]).unpack()

            let a = Array(data[point10 ..< point12]).unpack() << 4
            sampleRate = a | (UInt32(data[point12]) & 0xF0) >> 4
            channels = (UInt32(data[point12]) & 0x0E) >> 1 + 1
            bitsPerSample = (UInt32(data[point12]) & 0x01) << 4 | (UInt32(data[point13]) & 0xF0) >> 4 + 1
            totalSamples = (UInt64(data[point13]) & 0x0F) << 32 | Array(data[point14 ..< point18]).unpackUInt64()
            md5 = data[point18 ..< point34].compactMap({ Optional(String(format: "%02x", $0)) }).joined()
        }
    }
    // https://github.com/xiph/flac/blob/64b7142a3601717a533cd0d7e6ef19f8aaba3db8/src/libFLAC/metadata_iterators.c#L2303-L2353
    public struct VorbisComments {
        public let header: Header
        public let vendor: String
        public let metadata: [Field: String]
        public let rawMeta: [String]

        init(bytes: Data, header: Header) {
            self.header = header
            var data = bytes.advanced(by: 0)
            let vendorLength = Int(Array(data[0 ..< 4]).unpack(isLittleEndian: true))
            data = data.advanced(by: 4)
            let vendorData = data[0 ..< vendorLength]
            vendor = String(data: vendorData, encoding: .utf8) ?? ""
            data = data.advanced(by: vendorLength)
            let commentsCount = Array(data[0 ..< 4]).unpack(isLittleEndian: true)
            data = data.advanced(by: 4)
            var map: [Field: String] = [:]
            var metas: [String] = []
            for _ in 0 ..< commentsCount {
                let length = Int(Array(data[0 ..< 4]).unpack(isLittleEndian: true))
                data = data.advanced(by: 4)
                let strData = data[0 ..< length]
                guard let value = String(data: strData, encoding: .utf8) else { continue }
                data = data.advanced(by: length)
                metas.append(value)
                let kv = value.split(separator: "=")
                if kv.count == 2, let key = Field(rawValue: String(kv[0])) {
                    map[key] = String(kv[1])
                }
            }
            rawMeta = metas
            metadata = map
        }

        public func asMetadata() -> [MetadataParser.Item] {
            var ret: [MetadataParser.Item] = []
            for (key, value) in metadata {
                switch key {
                case .album: ret.append(.album(value))
                case .title: ret.append(.title(value))
                case .trackNumber: ret.append(.track(value))
                case .atrist: ret.append(.artist(value))
                case .genre: ret.append(.genre(value))
                case .date: ret.append(.year(value))
                case .contact: ret.append(.comment(value))
                default: break
                }
            }
            return ret
        }

        public enum Field: String {
            case title = "TITLE"
            case version = "VERSION"
            case album = "ALBUM"
            case trackNumber = "TRACKNUMBER"
            case atrist = "ARTIST"
            case performer = "PERFORMER"
            case copyright = "COPYRIGHT"
            case license = "LICENSE"
            case organization = "ORGANIZATION"
            case description = "DESCRIPTION"
            case genre = "GENRE"
            case date = "DATE"
            case location = "LOCATION"
            case contact = "CONTACT"
            case isrc = "ISRC"
        }
    }

    public struct Picture {
        public let header: Header
        public let type: MetadataParser.PictureType
        public let mimeType: String
        public let desc: String
        public let size: CGSize
        public let colorDepth: UInt32
        /// For indexed-color pictures (e.g. GIF), the number of colors used, or 0 for non-indexed pictures.
        public let colorUsed: UInt32
        public let length: UInt32
        public let picData: Data

        init(bytes: Data, header: Header) {
            self.header = header
            var data = bytes.advanced(by: 0)
            let value = Array(data[0 ..< 4]).unpack()
            type = MetadataParser.PictureType(rawValue: UInt8(value)) ?? .undifined
            data = data.advanced(by: 4)
            let mimeTypeLength = Int(Array(data[0 ..< 4]).unpack())
            data = data.advanced(by: 4)
            let mimeTypeData = data[0 ..< mimeTypeLength]
            mimeType = String(data: mimeTypeData, encoding: .ascii) ?? ""
            data = data.advanced(by: mimeTypeLength)
            let descLength = Int(Array(data[0 ..< 4]).unpack())
            data = data.advanced(by: 4)
            if descLength > 0 {
                let descData = data[0 ..< descLength]
                desc = String(data: descData, encoding: .utf8) ?? ""
                data = data.advanced(by: descLength)
            } else {
                desc = ""
            }
            let width = Array(data[0 ..< 4]).unpack()
            data = data.advanced(by: 4)
            let height = Array(data[0 ..< 4]).unpack()
            data = data.advanced(by: 4)
            size = CGSize(width: CGFloat(width), height: CGFloat(height))
            colorDepth = Array(data[0 ..< 4]).unpack()
            data = data.advanced(by: 4)
            colorUsed = Array(data[0 ..< 4]).unpack()
            data = data.advanced(by: 4)
            length = Array(data[0 ..< 4]).unpack()
            data = data.advanced(by: 4)
            picData = data[0 ..< Int(length)]
        }
    }

    public struct Padding {
        public let header: Header
        /// in bytes
        public let length: UInt32
    }

    public struct CUESheet {
        public let header: Header
        public let mediaCatalogNumber: String
        public let leadIn: UInt64
        public let isCD: Bool
        public let tracks: [Track]

        init(bytes: Data, header: Header) {
            self.header = header

            var data = bytes.advanced(by: 0)
            mediaCatalogNumber = String(data: data[0 ..< 128], encoding: .ascii)?.trimZeroTerminator() ?? ""
            data = data.advanced(by: 128)
            leadIn = Array(data[0 ..< 8]).unpackUInt64()
            data = data.advanced(by: 8)
            isCD = (UInt32(data[0]) & 0x80) != 0
            data = data.advanced(by: 258 + 1)
            let tracksCount = data[0]
            data = data.advanced(by: 1)
            var tracks: [Track] = []
            for _ in 0 ..< tracksCount {
                let offset = Array(data[0 ..< 8]).unpackUInt64()
                data = data.advanced(by: 8)
                let number = data[0]
                data = data.advanced(by: 1)
                let isrc = String(data: data[0 ..< 12], encoding: .ascii)?.trimZeroTerminator() ?? ""
                data = data.advanced(by: 12)
                let isAudio = UInt32(data[0]) & 0x80 == 0
                let isPreEmphasis = UInt32(data[0]) & 0x70 != 0
                data = data.advanced(by: 1 + 13)
                let numberOfIndexPoints = data[0]
                data = data.advanced(by: 1)
                var indexPoints: [Track.Index] = []
                if numberOfIndexPoints > 0 {
                    for _ in 0 ..< numberOfIndexPoints {
                        let size = Track.Index.size
                        let pointData = data[0 ..< size]
                        data = data.advanced(by: size)
                        let offset = Array(pointData[0 ..< 8]).unpackUInt64()
                        let number = pointData[8]
                        let idx = Track.Index(offset: offset, number: number)
                        indexPoints.append(idx)
                    }
                }
                let track = Track(offset: offset, number: number, isrc: isrc, isAudio: isAudio, isPreEmphasis: isPreEmphasis, numberOfIndexPoints: numberOfIndexPoints, indexPoints: indexPoints)
                tracks.append(track)
            }
            self.tracks = tracks
        }

        public struct Track {
            public let offset: UInt64
            public let number: UInt8
            public let isrc: String
            public let isAudio: Bool
            public let isPreEmphasis: Bool
            public let numberOfIndexPoints: UInt8
            public let indexPoints: [Index]

            public struct Index {
                static let size = 8 + 1 + 3
                public let offset: UInt64
                public let number: UInt8
            }
        }
    }

    public struct Application {
        public let header: Header
        public let name: String
        public let data: Data

        init(bytes: Data, header: Header) {
            self.header = header
            let point0 = bytes.startIndex
            let point4 = point0 + 4
            let value = Array(bytes[point0 ..< point4]).unpack()
            name = String(from: value)?.trimZeroTerminator() ?? "\(value)"
            data = Data(bytes[point4 ..< Int(header.metadataBlockDataSize)])
        }
    }

    public struct SeekTable {
        public let header: Header
        public let points: [SeekPoint]

        init(bytes: Data, header: Header) {
            self.header = header
            let size = Int(header.metadataBlockDataSize)
            let totalPoints = Int(size / 18)
            var pointTable: [SeekPoint] = []
            let startIndex = bytes.startIndex
            for i in 0 ..< totalPoints {
                let offset = i * 18 + startIndex
                let end = offset + 18
                let point = SeekPoint(bytes: bytes[offset ..< end])
                pointTable.append(point)
            }
            points = pointTable.sorted(by: { $0.sampleNumber < $1.sampleNumber })
        }

        public struct SeekPoint: Hashable, CustomStringConvertible {
            private static let placeHolder: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
            public let sampleNumber: UInt64
            public let streamOffset: UInt64
            public let frameSamples: UInt32

            init(bytes: Data) {
                let point0 = bytes.startIndex
                let point8 = point0 + 8
                let point16 = point8 + 8
                let point18 = point16 + 2
                sampleNumber = bytes[point0 ..< point8].compactMap({ $0 }).unpackUInt64()
                streamOffset = bytes[point8 ..< point16].compactMap({ $0 }).unpackUInt64()
                frameSamples = bytes[point16 ..< point18].compactMap({ $0 }).unpack()
            }

            public var description: String {
                let clz = "\(type(of: self))"
                if sampleNumber == SeekPoint.placeHolder { return "\(clz).PlaceHolder" }
                return "\(clz)(sampleNumber: \(sampleNumber), streamOffset:\(streamOffset), frameSamples:\(frameSamples))"
            }
        }
    }
}
