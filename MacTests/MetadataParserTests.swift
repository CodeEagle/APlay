//
//  MetadataParserTests.swift
//
//  Byte-level tests for the built-in tag parsers. Both parsers are fed
//  hand-rolled minimal headers so the assertions pin the exact decode
//  behaviour (sizes, sample rate, channel/bits unpacking) without depending
//  on any sample asset.
//

import XCTest
@testable import APlay

final class MetadataParserTests: XCTestCase {

    /// Thread-safe collector for the parser's `outputStream` events, which can
    /// arrive on the parser's private barrier queue.
    final class Collector {
        private let lock = NSLock()
        private var _events: [MetadataParser.Event] = []

        func append(_ event: MetadataParser.Event) {
            lock.lock()
            _events.append(event)
            lock.unlock()
        }

        var events: [MetadataParser.Event] {
            lock.lock()
            defer { lock.unlock() }
            return _events
        }
    }

    let collector = Collector()
    let config = APlay.Configuration()

    func testFlacParserDecodesStreamInfo() throws {
        let parser = FlacParser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }

        // A minimal FLAC file: "fLaC" + one last-flagged STREAMINFO block.
        var bytes: [UInt8] = []
        bytes.append(contentsOf: [0x66, 0x4C, 0x61, 0x43]) // "fLaC"
        // Header: last-metadata-block flag set, type 0 (STREAMINFO), size 34.
        bytes.append(contentsOf: [0x80, 0x00, 0x00, 0x22])

        // --- STREAMINFO body (34 bytes) ---
        bytes.append(contentsOf: [0x10, 0x00]) // min blocksize 4096
        bytes.append(contentsOf: [0x10, 0x00]) // max blocksize 4096
        bytes.append(contentsOf: [0x00, 0x00, 0x00]) // min framesize
        bytes.append(contentsOf: [0x00, 0x00, 0x00]) // max framesize
        // 20-bit sample rate 44100 = 0x0AC44, split across bytes 10-12
        bytes.append(contentsOf: [0x0A, 0xC4])
        // low nibble of sample rate | (channels-1)<<1 | top bit of (bitsPerSample-1)
        // channels 2 -> 1<<1; bps 16 -> 15 = 0b01111, top bit 0
        bytes.append(0x42)
        // rest of (bitsPerSample-1) in high nibble, low nibble starts total samples
        bytes.append(0xF0)
        // total samples = 1000 (36-bit, fits in the low 32)
        bytes.append(contentsOf: [0x00, 0x00, 0x03, 0xE8])
        // 16-byte MD5
        bytes.append(contentsOf: Array(repeating: 0xAB, count: 16))

        XCTAssertEqual(bytes.count, 4 + 4 + 34)

        bytes.withUnsafeBufferPointer { ptr in
            parser.acceptInput(data: UnsafeMutablePointer(mutating: ptr.baseAddress!), count: UInt32(bytes.count))
        }

        let flac = try waitForFlacEvent()
        let info = flac.streamInfo
        XCTAssertEqual(info.sampleRate, 44100)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.bitsPerSample, 16)
        XCTAssertEqual(info.totalSamples, 1000)
        XCTAssertEqual(info.minimumBlockSize, 4096)
        XCTAssertEqual(info.maximumBlockSize, 4096)
        XCTAssertEqual(info.md5, String(repeating: "ab", count: 16))
    }

    func testID3ParserRejectsNonID3Input() throws {
        let parser = ID3Parser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }

        // Random bytes that are not an ID3v2 header — the parser must not crash
        // and must not emit metadata.
        let bytes: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B]
        bytes.withUnsafeBufferPointer { ptr in
            parser.acceptInput(data: UnsafeMutablePointer(mutating: ptr.baseAddress!), count: UInt32(bytes.count))
        }

        let expectation = expectation(description: "parser settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        let metadataEvents = collector.events.filter {
            if case .metadata = $0 { return true }
            return false
        }
        XCTAssertTrue(metadataEvents.isEmpty, "non-ID3 bytes must not produce metadata")
    }

    // MARK: - Byte constructors

    private func feed(_ parser: MetadataParserCompatible, bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { ptr in
            parser.acceptInput(data: UnsafeMutablePointer(mutating: ptr.baseAddress!), count: UInt32(bytes.count))
        }
    }

    /// Sync-safe (7 bits/byte) ID3v2 size.
    private func syncsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
         UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    private func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Little-endian 4-byte length (FLAC vorbis comments are LE).
    private func le32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    /// FLAC metadata block header: last-flag + type, then a 3-byte size.
    private func flacHeader(isLast: Bool, type: UInt8, size: Int) -> [UInt8] {
        [(isLast ? 0x80 : 0x00) | (type & 0x7F),
         UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]
    }

    /// 34-byte STREAMINFO body (44.1 kHz, 2 ch, 16 bit, 1000 samples).
    private func streamInfoBody() -> [UInt8] {
        var body: [UInt8] = []
        body.append(contentsOf: [0x10, 0x00]) // min blocksize 4096
        body.append(contentsOf: [0x10, 0x00]) // max blocksize 4096
        body.append(contentsOf: [0x00, 0x00, 0x00]) // min framesize
        body.append(contentsOf: [0x00, 0x00, 0x00]) // max framesize
        body.append(contentsOf: [0x0A, 0xC4]) // sample rate 44100 (high 16 bits)
        body.append(0x42) // rate low nibble | (channels-1)<<1 | bps high bit
        body.append(0xF0) // bps low bits | total samples high nibble
        body.append(contentsOf: [0x00, 0x00, 0x03, 0xE8]) // total samples 1000
        body.append(contentsOf: Array(repeating: UInt8(0xAB), count: 16)) // md5
        XCTAssertEqual(body.count, 34)
        return body
    }

    /// VORBIS_COMMENT body: little-endian lengths throughout.
    private func vorbisBody(vendor: String, comments: [String]) -> [UInt8] {
        var body: [UInt8] = []
        let vendorBytes = Array(vendor.utf8)
        body.append(contentsOf: le32(vendorBytes.count))
        body.append(contentsOf: vendorBytes)
        body.append(contentsOf: le32(comments.count))
        for comment in comments {
            let bytes = Array(comment.utf8)
            body.append(contentsOf: le32(bytes.count))
            body.append(contentsOf: bytes)
        }
        return body
    }

    /// ID3v2 header: "ID3", version, revision, flags, sync-safe tag size.
    private func v2Header(version: UInt8, flags: UInt8, tagSize: Int) -> [UInt8] {
        Array("ID3".utf8) + [version, 0x00, flags] + syncsafe(tagSize)
    }

    /// ID3v2.3 frame: 4-byte name, 4-byte size, 2-byte flags, body.
    private func v23Frame(_ name: String, body: [UInt8]) -> [UInt8] {
        Array(name.utf8) + be32(body.count) + [0x00, 0x00] + body
    }

    /// ID3v2.4 frame: same layout as 2.3 but the size is sync-safe.
    private func v24Frame(_ name: String, body: [UInt8]) -> [UInt8] {
        Array(name.utf8) + syncsafe(body.count) + [0x00, 0x00] + body
    }

    /// ID3v2.2 frame: 3-byte name, 3-byte size, body (no flags).
    private func v22Frame(_ name: String, body: [UInt8]) -> [UInt8] {
        let n = body.count
        return Array(name.utf8) + [UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + body
    }

    /// Text frame body: encoding byte (default UTF-8) + text + terminator.
    private func textBody(_ text: String, encoding: UInt8 = 0x03) -> [UInt8] {
        [encoding] + Array(text.utf8) + [0x00]
    }

    /// 128-byte ID3v1 tag; a non-nil `track` makes it a v1.1 tag.
    private func v1Tag(title: String, artist: String, album: String, year: String,
                       comment: String, track: UInt8? = nil, genre: UInt8 = 17) -> [UInt8] {
        func pad(_ s: String, _ length: Int) -> [UInt8] {
            var bytes = Array(s.utf8)
            bytes.append(contentsOf: Array(repeating: 0, count: max(0, length - bytes.count)))
            return bytes
        }
        var bytes = Array("TAG".utf8)
        bytes.append(contentsOf: pad(title, 30))
        bytes.append(contentsOf: pad(artist, 30))
        bytes.append(contentsOf: pad(album, 30))
        bytes.append(contentsOf: pad(year, 4))
        if let track = track {
            bytes.append(contentsOf: pad(comment, 28))
            bytes.append(0x00)
            bytes.append(track)
        } else {
            bytes.append(contentsOf: pad(comment, 30))
        }
        bytes.append(genre)
        XCTAssertEqual(bytes.count, 128)
        return bytes
    }

    /// Pulls the associated string out of a metadata item list, or nil.
    private func stringItem(_ items: [MetadataParser.Item], _ kind: String) -> String? {
        for item in items {
            switch (item, kind) {
            case (.title(let v), "title"), (.artist(let v), "artist"), (.album(let v), "album"),
                 (.track(let v), "track"), (.year(let v), "year"), (.comment(let v), "comment"),
                 (.genre(let v), "genre"):
                return v
            default:
                break
            }
        }
        return nil
    }

    /// A path that does not exist: `processingID3V1FromLocal` fails to open it, so
    /// the v1 state settles to an error and `dispatchEvent` can fire for a v2-only
    /// feed.
    private func missingFileURL() -> URL {
        URL(fileURLWithPath: "/tmp/APlayTests-missing-\(UUID().uuidString).mp3")
    }

    /// Feeds junk bytes so the v2 state settles to an error — `dispatchEvent`
    /// only fires once both the v1 and v2 states are done, so a v1-only parse
    /// still needs the v2 side to settle.
    private func settleV2WithError(_ parser: ID3Parser) {
        feed(parser, bytes: Array(repeating: UInt8(0x41), count: 10))
    }

    /// Waits for the parser's barrier queue to flush a `.metadata` event.
    @discardableResult
    private func waitForMetadata(timeout: TimeInterval = 2) throws -> [MetadataParser.Item] {
        let expectation = expectation(description: "metadata delivered")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if self.collector.events.contains(where: { if case .metadata = $0 { return true }; return false }) {
                timer.invalidate()
                expectation.fulfill()
            }
        }
        defer { timer.invalidate() }
        wait(for: [expectation], timeout: timeout)
        guard case let .metadata(items)? = collector.events.first(where: { if case .metadata = $0 { return true }; return false }) else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "no .metadata event delivered"])
        }
        return items
    }

    // MARK: - ID3v2

    func testID3v23DecodesTextFrames() throws {
        let parser = ID3Parser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        let frames = v23Frame("TIT2", body: textBody("Title")) +
            v23Frame("TPE1", body: textBody("Artist")) +
            v23Frame("TALB", body: textBody("Album")) +
            v23Frame("TRCK", body: textBody("3")) +
            v23Frame("COMM", body: textBody("Comment")) +
            v23Frame("TDAT", body: textBody("2026"))
        var bytes = v2Header(version: 0x03, flags: 0x00, tagSize: frames.count)
        bytes.append(contentsOf: frames)
        feed(parser, bytes: bytes)
        parser.parseID3V1Tag(at: missingFileURL())
        let items = try waitForMetadata()
        XCTAssertEqual(stringItem(items, "title"), "Title")
        XCTAssertEqual(stringItem(items, "artist"), "Artist")
        XCTAssertEqual(stringItem(items, "album"), "Album")
        XCTAssertEqual(stringItem(items, "track"), "3")
        XCTAssertEqual(stringItem(items, "comment"), "Comment")
        XCTAssertEqual(stringItem(items, "year"), "2026")
    }

    func testID3v22DecodesThreeLetterFrames() throws {
        let parser = ID3Parser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        let frames = v22Frame("TT2", body: textBody("Title22")) +
            v22Frame("TP1", body: textBody("Artist22")) +
            v22Frame("TAL", body: textBody("Album22")) +
            v22Frame("TRK", body: textBody("7")) +
            v22Frame("COM", body: textBody("Comment22")) +
            v22Frame("TDA", body: textBody("2022"))
        var bytes = v2Header(version: 0x02, flags: 0x00, tagSize: frames.count)
        bytes.append(contentsOf: frames)
        feed(parser, bytes: bytes)
        parser.parseID3V1Tag(at: missingFileURL())
        let items = try waitForMetadata()
        XCTAssertEqual(stringItem(items, "title"), "Title22")
        XCTAssertEqual(stringItem(items, "artist"), "Artist22")
        XCTAssertEqual(stringItem(items, "album"), "Album22")
        XCTAssertEqual(stringItem(items, "track"), "7")
        XCTAssertEqual(stringItem(items, "comment"), "Comment22")
        XCTAssertEqual(stringItem(items, "year"), "2022")
    }

    func testID3v24DecodesSyncSafeFrameSize() throws {
        let parser = ID3Parser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        let frames = v24Frame("TIT2", body: textBody("Title24")) +
            v24Frame("TALB", body: textBody("Album24"))
        var bytes = v2Header(version: 0x04, flags: 0x00, tagSize: frames.count)
        bytes.append(contentsOf: frames)
        feed(parser, bytes: bytes)
        parser.parseID3V1Tag(at: missingFileURL())
        let items = try waitForMetadata()
        XCTAssertEqual(stringItem(items, "title"), "Title24")
        XCTAssertEqual(stringItem(items, "album"), "Album24")
    }

    func testID3v23SkipsExtendedHeader() throws {
        let parser = ID3Parser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        // The v2.3 extended header size field counts itself (6 bytes here).
        let extended = be32(6) + [0x00, 0x00]
        let frames = v23Frame("TIT2", body: textBody("AfterExtendedHeader"))
        let payload = extended + frames
        var bytes = v2Header(version: 0x03, flags: 0x40, tagSize: payload.count)
        bytes.append(contentsOf: payload)
        feed(parser, bytes: bytes)
        parser.parseID3V1Tag(at: missingFileURL())
        let items = try waitForMetadata()
        XCTAssertEqual(stringItem(items, "title"), "AfterExtendedHeader")
    }

    func testID3UnknownFrameBecomesOther() throws {
        let parser = ID3Parser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        let frames = v23Frame("TXXX", body: textBody("CustomValue"))
        var bytes = v2Header(version: 0x03, flags: 0x00, tagSize: frames.count)
        bytes.append(contentsOf: frames)
        feed(parser, bytes: bytes)
        parser.parseID3V1Tag(at: missingFileURL())
        let items = try waitForMetadata()
        let other = items.compactMap { item -> [String: String]? in
            if case let .other(map) = item { return map }
            return nil
        }.first
        XCTAssertEqual(other?["TXXX"], "CustomValue\u{0}")
    }

    func testID3DecodesApicCover() throws {
        let parser = ID3Parser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        // APIC body: encoding + mime + \0 + picture type + description \0 + image.
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        let body: [UInt8] = [0x00] + Array("image/jpeg\u{0}".utf8) + [0x03, 0x00] + jpeg
        var frame = v23Frame("APIC", body: body)
        // Trailing padding keeps the buffer long enough for the cover slice,
        // which the parser takes relative to the frame body.
        frame.append(contentsOf: Array(repeating: 0x00, count: 32))
        var bytes = v2Header(version: 0x03, flags: 0x00, tagSize: frame.count)
        bytes.append(contentsOf: frame)
        feed(parser, bytes: bytes)
        parser.parseID3V1Tag(at: missingFileURL())
        let items = try waitForMetadata()
        let cover = items.compactMap { item -> Data? in
            if case let .cover(data) = item { return data }
            return nil
        }.first
        XCTAssertNotNil(cover)
        let coverBytes = Array(cover ?? Data())
        XCTAssertTrue(coverBytes.contains(0xFF))
        XCTAssertTrue(coverBytes.contains(0xD8))
    }

    // MARK: - ID3v1

    func testID3v1TagDecodesLocalFile() throws {
        let parser = ID3Parser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        // The reader seeks to the last 128 bytes, so lead with audio padding.
        let url = URL(fileURLWithPath: "\(NSTemporaryDirectory())APlayTests-v1-\(UUID().uuidString).mp3")
        var file = Array(repeating: UInt8(0x00), count: 4096)
        file.append(contentsOf: v1Tag(title: "V1Title", artist: "V1Artist", album: "V1Album",
                                      year: "1999", comment: "V1Comment"))
        try Data(file).write(to: url)
        settleV2WithError(parser)
        parser.parseID3V1Tag(at: url)
        let items = try waitForMetadata()
        XCTAssertEqual(stringItem(items, "title"), "V1Title")
        XCTAssertEqual(stringItem(items, "artist"), "V1Artist")
        XCTAssertEqual(stringItem(items, "album"), "V1Album")
        XCTAssertEqual(stringItem(items, "year"), "1999")
        XCTAssertEqual(stringItem(items, "comment"), "V1Comment")
        XCTAssertEqual(stringItem(items, "genre"), "Rock")
    }

    func testID3v11TagAddsTrackNumber() throws {
        let parser = ID3Parser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        let url = URL(fileURLWithPath: "\(NSTemporaryDirectory())APlayTests-v11-\(UUID().uuidString).mp3")
        var file = Array(repeating: UInt8(0x00), count: 4096)
        file.append(contentsOf: v1Tag(title: "V11Title", artist: "V11Artist", album: "V11Album",
                                      year: "2001", comment: "V11Comment", track: 9))
        try Data(file).write(to: url)
        settleV2WithError(parser)
        parser.parseID3V1Tag(at: url)
        let items = try waitForMetadata()
        XCTAssertEqual(stringItem(items, "title"), "V11Title")
        XCTAssertEqual(stringItem(items, "track"), "9")
        XCTAssertEqual(stringItem(items, "comment"), "V11Comment")
    }

    func testID3v1RejectsFileWithoutTag() throws {
        let parser = ID3Parser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        let url = URL(fileURLWithPath: "\(NSTemporaryDirectory())APlayTests-notag-\(UUID().uuidString).mp3")
        try Data(Array(repeating: UInt8(0x41), count: 4096)).write(to: url)
        parser.parseID3V1Tag(at: url)
        // A file without a trailing "TAG" must settle without metadata.
        let expectation = expectation(description: "settles without metadata")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        let metadataEvents = collector.events.filter {
            if case .metadata = $0 { return true }
            return false
        }
        XCTAssertTrue(metadataEvents.isEmpty)
    }

    // MARK: - FLAC

    func testFlacDecodesVorbisComments() throws {
        let parser = FlacParser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        var bytes: [UInt8] = [0x66, 0x4C, 0x61, 0x43] // "fLaC"
        bytes.append(contentsOf: flacHeader(isLast: false, type: 0, size: 34))
        bytes.append(contentsOf: streamInfoBody())
        let comments = ["TITLE=FlacTitle", "ALBUM=FlacAlbum", "ARTIST=FlacArtist",
                        "TRACKNUMBER=5", "GENRE=Jazz", "DATE=2020"]
        let vorbis = vorbisBody(vendor: "test", comments: comments)
        bytes.append(contentsOf: flacHeader(isLast: true, type: 4, size: vorbis.count))
        bytes.append(contentsOf: vorbis)
        feed(parser, bytes: bytes)
        let items = try waitForMetadata()
        XCTAssertEqual(stringItem(items, "title"), "FlacTitle")
        XCTAssertEqual(stringItem(items, "album"), "FlacAlbum")
        XCTAssertEqual(stringItem(items, "artist"), "FlacArtist")
        XCTAssertEqual(stringItem(items, "track"), "5")
        XCTAssertEqual(stringItem(items, "genre"), "Jazz")
        XCTAssertEqual(stringItem(items, "year"), "2020")
    }

    func testFlacSkipsPaddingBeforeComments() throws {
        let parser = FlacParser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        var bytes: [UInt8] = [0x66, 0x4C, 0x61, 0x43]
        bytes.append(contentsOf: flacHeader(isLast: false, type: 0, size: 34))
        bytes.append(contentsOf: streamInfoBody())
        let padding = Array(repeating: UInt8(0x00), count: 20)
        bytes.append(contentsOf: flacHeader(isLast: false, type: 1, size: padding.count))
        bytes.append(contentsOf: padding)
        let vorbis = vorbisBody(vendor: "test", comments: ["TITLE=AfterPadding"])
        bytes.append(contentsOf: flacHeader(isLast: true, type: 4, size: vorbis.count))
        bytes.append(contentsOf: vorbis)
        feed(parser, bytes: bytes)
        let items = try waitForMetadata()
        XCTAssertEqual(stringItem(items, "title"), "AfterPadding")
    }

    func testFlacIgnoresUndefinedBlockType() throws {
        let parser = FlacParser(config: config)
        parser.outputStream.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        var bytes: [UInt8] = [0x66, 0x4C, 0x61, 0x43]
        bytes.append(contentsOf: flacHeader(isLast: false, type: 0, size: 34))
        bytes.append(contentsOf: streamInfoBody())
        // Type 8 is not a defined block type; the parser must skip it, not crash.
        let junk = Array(repeating: UInt8(0x7F), count: 12)
        bytes.append(contentsOf: flacHeader(isLast: false, type: 8, size: junk.count))
        bytes.append(contentsOf: junk)
        let vorbis = vorbisBody(vendor: "test", comments: ["TITLE=AfterUndefined"])
        bytes.append(contentsOf: flacHeader(isLast: true, type: 4, size: vorbis.count))
        bytes.append(contentsOf: vorbis)
        feed(parser, bytes: bytes)
        let items = try waitForMetadata()
        XCTAssertEqual(stringItem(items, "title"), "AfterUndefined")
    }

    /// Waits for the parser's barrier queue to flush a `.flac` event.
    private func waitForFlacEvent(timeout: TimeInterval = 2) throws -> FlacMetadata {
        let expectation = expectation(description: "flac metadata delivered")
        // Poll briefly — the parser emits from a barrier queue asynchronously.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if self.collector.events.contains(where: { if case .flac = $0 { return true }; return false }) {
                timer.invalidate()
                expectation.fulfill()
            }
        }
        defer { timer.invalidate() }
        wait(for: [expectation], timeout: timeout)
        guard case let .flac(value)? = collector.events.first(where: { if case .flac = $0 { return true }; return false }) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no .flac event delivered"])
        }
        return value
    }
}
