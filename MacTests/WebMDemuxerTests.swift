//
//  WebMDemuxerTests.swift
//
//  Pins the pure-Swift EBML reader behind `APlayOpus`: the bundled fixtures
//  demux to an A_OPUS track with real packets, and synthetic containers cover
//  the lacing, the unknown segment size and the non-Opus case.
//

import XCTest
import APlayOpus
import AudioToolbox
import CoreAudio
@testable import APlay
@testable import APlayOpus

final class WebMDemuxerTests: XCTestCase {

    private let harness = DecoderTestHarness()

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try harness.fixture(name, ext)
    }

    // MARK: - Bundled fixtures

    /// The WebM fixture carries one A_OPUS track at 48 kHz stereo.
    func testParsesTheWebMFixture() throws {
        let data = try Data(contentsOf: try fixture("tone", "webm"))
        let parsed = try XCTUnwrap(WebMDemuxer.parse(data))
        let track = try XCTUnwrap(parsed.track)
        XCTAssertEqual(track.codecID, "A_OPUS")
        XCTAssertEqual(track.sampleRate, 48000)
        XCTAssertEqual(track.channels, 2)
        XCTAssertGreaterThan(parsed.packets.count, 90, "the two-second clip holds ~100 packets")
        XCTAssertTrue(parsed.packets.allSatisfy { !$0.isEmpty })
        // FFmpeg's WebM muxer writes only its own ENCODER/DURATION bookkeeping.
        XCTAssertTrue(parsed.metadata.allSatisfy { item in
            if case .other = item { return true } else { return false }
        }, "the WebM muxer wrote no content tags: \(parsed.metadata)")
    }

    /// The Matroska fixture carries the same track plus the scripted tags.
    func testParsesTheMatroskaFixture() throws {
        let data = try Data(contentsOf: try fixture("tone", "mka"))
        let parsed = try XCTUnwrap(WebMDemuxer.parse(data))
        XCTAssertEqual(parsed.track?.sampleRate, 48000)
        XCTAssertGreaterThan(parsed.packets.count, 90)
        XCTAssertEqual(parsed.duration, 2.008, accuracy: 0.01)
        XCTAssertEqual(parsed.metadata.prefix(3).map { String(describing: $0) }, [
            "title(\"APlay WebM/Opus tone\")",
            "artist(\"APlay\")",
            "album(\"Fixtures\")",
        ], "got: \(parsed.metadata)")
    }

    // MARK: - Synthetic containers

    /// A track that is not A_OPUS is demuxed but not claimed, so the decoder
    /// can hand the URL back to the fallback.
    func testIgnoresANonOpusTrack() {
        var file = ebml()
        file.append(contentsOf: segment(size: nil) {
            tracks(codecID: "A_VORBIS")
        })
        let parsed = WebMDemuxer.parse(Data(file))
        XCTAssertNotNil(parsed, "it is still an EBML file")
        XCTAssertNil(parsed?.track, "a Vorbis track is not ours")
    }

    /// An unknown segment size — what FFmpeg writes when it cannot seek back —
    /// reads to the end of the file rather than desyncing.
    func testHandlesAnUnknownSegmentSize() {
        var file = ebml()
        file.append(contentsOf: segment(size: nil) {
            var tracks = tracks(codecID: "A_OPUS")
            tracks.append(contentsOf: cluster(packets: [Data(repeating: 0x11, count: 8)]))
            return tracks
        })
        let parsed = WebMDemuxer.parse(Data(file))
        XCTAssertEqual(parsed?.track?.sampleRate, 48000)
        XCTAssertEqual(parsed?.packets.count, 1, "the segment ran to the end of the file")
    }

    /// A SimpleBlock without lacing holds a single packet.
    func testSplitsAnUnlacedBlock() {
        let parsed = WebMDemuxer.parse(Data(container(block: .unlaced(payload: 15))))
        XCTAssertEqual(parsed?.packets.count, 1)
        XCTAssertEqual(parsed?.packets.first?.count, 15)
    }

    /// Xiph lacing carries every frame but the last as a 0xFF-chained size; the
    /// final frame is whatever the block has left.
    func testSplitsAXiphLacedBlock() {
        let parsed = WebMDemuxer.parse(Data(container(block: .xiph(sizes: [10, 255 * 2 + 5]))))
        XCTAssertEqual(parsed?.packets.count, 3, "two sizes plus the remainder")
        XCTAssertEqual(parsed?.packets.map(\.count), [10, 515, 20],
                       "the last frame is the leftover payload")
    }

    /// Fixed lacing splits the payload into equal frames.
    func testSplitsAFixedLacedBlock() {
        let parsed = WebMDemuxer.parse(Data(container(block: .fixed(frameCount: 3, frameSize: 7))))
        XCTAssertEqual(parsed?.packets.count, 3)
        XCTAssertTrue(parsed?.packets.allSatisfy { $0.count == 7 } ?? false)
    }

    /// A block that declares reserved lacing yields no packets rather than
    /// garbage.
    func testReservedLacingYieldsNothing() {
        let parsed = WebMDemuxer.parse(Data(container(block: .reserved)))
        XCTAssertEqual(parsed?.packets.count, 0)
    }

    /// Bytes that are not EBML at all are rejected, not half-parsed.
    func testRefusesNonEBMLBytes() {
        XCTAssertNil(WebMDemuxer.parse(Data(repeating: 0x42, count: 256)))
        XCTAssertNil(WebMDemuxer.parse(Data()))
    }

    // MARK: - Static readers

    /// Every tag name the demuxer knows maps, and the names ffmpeg writes for
    /// its own bookkeeping ride along instead of being dropped.
    func testMapsEverySupportedTagName() {
        func mapped(_ name: String, _ value: String) -> String {
            guard let item = WebMDemuxer.metadataItem(name: name, value: value) else { return "nil" }
            return String(describing: item)
        }
        XCTAssertEqual(mapped("TITLE", "T"), "title(\"T\")")
        XCTAssertEqual(mapped("title", "T"), "title(\"T\")", "tag names are case-insensitive")
        XCTAssertEqual(mapped("ARTIST", "A"), "artist(\"A\")")
        XCTAssertEqual(mapped("ALBUM", "B"), "album(\"B\")")
        XCTAssertEqual(mapped("GENRE", "G"), "genre(\"G\")")
        XCTAssertEqual(mapped("TRACK", "1"), "track(\"1\")")
        XCTAssertEqual(mapped("TRACKNUMBER", "9"), "track(\"9\")")
        XCTAssertEqual(mapped("DATE", "2026"), "year(\"2026\")")
        XCTAssertEqual(mapped("YEAR", "2026"), "year(\"2026\")")
        XCTAssertEqual(mapped("COMMENT", "C"), "comment(\"C\")")
        XCTAssertEqual(mapped("DESCRIPTION", "D"), "comment(\"D\")")
        XCTAssertEqual(mapped("ENCODER", "Lavf61.1.100"), "other([\"ENCODER\": \"Lavf61.1.100\"])")
        XCTAssertEqual(mapped("DURATION", "2"), "other([\"DURATION\": \"2\"])",
                       "the muxer's own fields ride along as other")
    }

    /// An OpusHead that is missing, short, mislabeled or empty in its rate or
    /// channel count describes no track.
    func testRejectsABadOpusHead() {
        XCTAssertNil(WebMDemuxer.opusTrack(codecID: "A_OPUS", head: nil))
        XCTAssertNil(WebMDemuxer.opusTrack(codecID: "A_OPUS", head: Data(repeating: 0x2A, count: 18)),
                     "a head shorter than 19 bytes has no rate field")
        XCTAssertNil(WebMDemuxer.opusTrack(codecID: "A_OPUS", head: Data(repeating: 0x2A, count: 19)),
                     "the magic must be OpusHead")

        var head = Data(opusHead)
        head[9] = 0
        XCTAssertNil(WebMDemuxer.opusTrack(codecID: "A_OPUS", head: head),
                     "zero channels is not a track")
        head[9] = 2
        head[12] = 0; head[13] = 0; head[14] = 0; head[15] = 0
        XCTAssertNil(WebMDemuxer.opusTrack(codecID: "A_OPUS", head: head),
                     "a zero rate is not a track")

        let track = WebMDemuxer.opusTrack(codecID: "A_OPUS", head: Data(opusHead))
        XCTAssertEqual(track?.codecID, "A_OPUS")
        XCTAssertEqual(track?.channels, 2)
        XCTAssertEqual(track?.sampleRate, 48000)
    }

    // MARK: - Malformed blocks

    /// A block that cannot be split yields no packets rather than garbage; each
    /// guard is pinned so a malformed body cannot desync the track behind it.
    func testMalformedBlocksYieldNoPackets() {
        func packets(_ body: [UInt8]) -> [Data] {
            WebMDemuxer.parse(Data(container(block: .raw(body))))?.packets ?? []
        }
        XCTAssertEqual(packets([]), [], "an empty body has no track number")
        XCTAssertEqual(packets([0x00]), [], "a zero byte is never a track number")
        XCTAssertEqual(packets([0x40]), [], "an element ID that runs off the end")
        XCTAssertEqual(packets([0x81]), [], "no room for the timecode and flags")
        XCTAssertEqual(packets([0x81, 0x00, 0x00]), [], "flags but no frames")
        XCTAssertEqual(packets([0x81, 0x00, 0x00, 0x00]), [], "an unlaced block needs a frame")
        XCTAssertEqual(packets([0x81, 0x00, 0x00, 0x02]), [], "a Xiph block needs its sizes")
        XCTAssertEqual(packets([0x81, 0x00, 0x00, 0x02, 0x01, 0xFF, 0xFF]),
                       [], "the size chain runs off the end")
        XCTAssertEqual(packets([0x81, 0x00, 0x00, 0x02, 0x01, 0x0A, 0x2A, 0x2A]),
                       [], "the declared sizes overstate the payload")
        XCTAssertEqual(packets([0x81, 0x00, 0x00, 0x04]), [], "a fixed block needs a frame")
        XCTAssertEqual(packets([0x81, 0x00, 0x00, 0x04, 0x02,
                                0x2A, 0x2A, 0x2A, 0x2A, 0x2A, 0x2A, 0x2A]),
                       [], "the payload is not evenly divisible")
    }

    /// Truncated elements end the walk at their guard instead of reading past
    /// the buffer.
    func testTruncatedElementsEndTheWalk() {
        func parse(_ body: [UInt8]) -> WebMDemuxer.File? {
            var file = ebml()
            file.append(contentsOf: segment(size: nil) { body })
            return WebMDemuxer.parse(Data(file))
        }

        let parsed = parse([0x00])
        XCTAssertNotNil(parsed, "the file itself parsed up to the zero byte")
        XCTAssertNil(parsed?.track, "a zero byte ends the walk before any track")

        // Each leaves the element half-read: an ID with no size at all, a size
        // that is a zero byte, and a size VINT that is truncated.
        for body in [elementID(0xAE), elementID(0xAE) + [0x00], elementID(0xAE) + [0x40]] {
            let truncated = parse(body)
            XCTAssertNil(truncated?.track, "a truncated element must not produce a track")
            XCTAssertEqual(truncated?.packets.count, 0)
        }
    }

    /// An empty Title and an empty TagString carry no value, so neither emits a
    /// metadata item.
    func testSkipsEmptyTextElements() {
        let title = element(0x7BA9, [])
        let tag = element(0x1254C367, element(0x7373, element(0x67C8,
            element(0x45A3, Array("GENRE".utf8)) + element(0x4487, []))))

        var file = ebml()
        file.append(contentsOf: segment(size: nil) {
            element(0x1549A966, title) + tag
        })
        let parsed = WebMDemuxer.parse(Data(file))
        XCTAssertEqual(parsed?.metadata.count, 0, "empty text elements carry nothing")
    }

    /// A Duration is only meaningful when a TimecodeScale precedes it, and a
    /// short Duration is zero rather than garbage bits.
    func testDurationNeedsAScaleAndEightBytes() {
        func parse(_ infoBody: [UInt8]) -> Double {
            var file = ebml()
            file.append(contentsOf: segment(size: nil) { element(0x1549A966, infoBody) })
            return WebMDemuxer.parse(Data(file))?.duration ?? -1
        }

        let scale = element(0x2AD7B1, [0x01])            // 1 ns per tick
        let short = element(0x4489, [0x40, 0x00])        // two bytes, not eight
        var oneSecond = [UInt8]()                        // 1e9 ticks, big-endian
        for shift in stride(from: 56, through: 0, by: -8) {
            oneSecond.append(UInt8((1_000_000_000.0.bitPattern >> shift) & 0xFF))
        }

        XCTAssertEqual(parse(short), 0, "a Duration without a scale is unreadable")
        XCTAssertEqual(parse(scale + short), 0, "a Duration shorter than eight bytes is zero")
        XCTAssertEqual(parse(scale + element(0x4489, oneSecond)), 1, accuracy: 1e-6,
                       "scale first, then the ticks in seconds")
    }

    /// A file can carry several tracks; the first `A_OPUS` one is kept and a
    /// later one never displaces it.
    func testKeepsTheFirstOpusTrack() {
        func file(_ entries: [(codecID: String, head: [UInt8]?)]) -> Data {
            var body: [UInt8] = []
            for entry in entries {
                var fields = element(0x86, Array(entry.codecID.utf8))
                if let head = entry.head { fields += element(0x63A2, head) }
                body += element(0xAE, fields)
            }
            var file = ebml()
            file.append(contentsOf: segment(size: nil) { element(0x1654AE6B, body) })
            return Data(file)
        }

        let vorbisThenOpus = WebMDemuxer.parse(file([("A_VORBIS", nil), ("A_OPUS", opusHead)]))
        XCTAssertEqual(vorbisThenOpus?.track?.codecID, "A_OPUS",
                       "a Vorbis entry is skipped for the Opus one behind it")
        XCTAssertEqual(vorbisThenOpus?.track?.sampleRate, 48000)

        let twoOpus = WebMDemuxer.parse(file([("A_OPUS", opusHead), ("A_OPUS", otherOpusHead)]))
        XCTAssertEqual(twoOpus?.track?.sampleRate, 48000, "the first A_OPUS entry wins")
        XCTAssertEqual(twoOpus?.track?.channels, 2)
    }

    // MARK: - EBML builders

    private enum Lacing {
        case unlaced(payload: Int)
        case xiph(sizes: [Int])
        case fixed(frameCount: Int, frameSize: Int)
        case reserved
        /// Arbitrary block bytes, for the malformed bodies the guards reject.
        case raw([UInt8])
    }

    /// `body` bytes for one SimpleBlock carrying `lacing`.
    private func blockBody(_ lacing: Lacing) -> [UInt8] {
        var body: [UInt8] = [0x81, 0x00, 0x00]   // track 1, zero timecode
        switch lacing {
        case let .unlaced(payload):
            body.append(0x00)                    // flags: no lacing
            body.append(contentsOf: repeatElement(0x2A, count: payload))
        case let .xiph(sizes):
            body.append(0x02)                    // flags: Xiph lacing
            body.append(UInt8(sizes.count))
            for size in sizes {
                size.encodingLacingSize().forEach { body.append($0) }
            }
            body.append(contentsOf: repeatElement(0x2A, count: sizes.reduce(0, +) + 20))
        case let .fixed(frameCount, frameSize):
            body.append(0x04)                    // flags: fixed lacing
            body.append(UInt8(frameCount - 1))
            body.append(contentsOf: repeatElement(0x2A, count: frameCount * frameSize))
        case .reserved:
            body.append(0x06)                    // flags: reserved lacing
        case let .raw(bytes):
            return bytes
        }
        return body
    }

    /// A whole file: EBML header plus a segment holding the track and a block.
    private func container(block: Lacing) -> [UInt8] {
        let cluster = element(0x1F43B675, element(0xA3, blockBody(block)))
        var entry = element(0x86, Array("A_OPUS".utf8))
        entry.append(contentsOf: element(0x63A2, opusHead))
        var file = ebml()
        file.append(contentsOf: segment(size: nil) {
            var tracks = element(0x1654AE6B, element(0xAE, entry))
            tracks.append(contentsOf: cluster)
            return tracks
        })
        return file
    }

    /// The EBML header every file starts with.
    private func ebml() -> [UInt8] {
        element(0x1A45DFA3, [0x42, 0x86, 0x01,     // EBML version
                             0x42, 0xF7, 0x01,     // read version
                             0x42, 0x82] + Array("webm".utf8))
    }

    /// A Segment element; `size == nil` encodes the unknown length.
    private func segment(size: Int?, body: () -> [UInt8]) -> [UInt8] {
        let bytes = body()
        var element = elementID(0x18538067)
        if let size {
            element.append(contentsOf: elementSize(size))
        } else {
            element.append(contentsOf: [0x01] + repeatElement(0xFF, count: 7))
        }
        element.append(contentsOf: bytes)
        return element
    }

    /// A Tracks element holding one entry with `codecID`.
    private func tracks(codecID: String) -> [UInt8] {
        var entry = element(0x86, Array(codecID.utf8))
        if codecID == "A_OPUS" { entry.append(contentsOf: element(0x63A2, opusHead)) }
        return element(0x1654AE6B, element(0xAE, entry))
    }

    /// A Cluster element holding `packets`, one SimpleBlock each.
    private func cluster(packets: [Data]) -> [UInt8] {
        var body: [UInt8] = []
        for packet in packets {
            var block: [UInt8] = [0x81, 0x00, 0x00, 0x00]
            block.append(contentsOf: packet)
            body.append(contentsOf: element(0xA3, block))
        }
        return element(0x1F43B675, body)
    }

    /// A 19-byte OpusHead: 48 kHz stereo, matching the fixtures.
    private let opusHead: [UInt8] = [
        0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64,   // "OpusHead"
        0x01,                                               // version
        0x02,                                               // channels
        0x38, 0x01,                                         // pre-skip
        0x80, 0xBB, 0x00, 0x00,                             // 48000 Hz
        0x00, 0x00, 0x00,                                   // gain, mapping
    ]

    /// A 19-byte OpusHead for 24 kHz mono — a second track the demuxer must not
    /// promote over the first.
    private let otherOpusHead: [UInt8] = [
        0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64,   // "OpusHead"
        0x01,                                               // version
        0x01,                                               // channels
        0x38, 0x01,                                         // pre-skip
        0xC0, 0x5D, 0x00, 0x00,                             // 24000 Hz
        0x00, 0x00, 0x00,                                   // gain, mapping
    ]

    /// One element: its ID, its size, then its body.
    private func element(_ id: UInt64, _ body: [UInt8]) -> [UInt8] {
        var element = elementID(id)
        element.append(contentsOf: elementSize(body.count))
        element.append(contentsOf: body)
        return element
    }
}

/// EBML encoding helpers for the synthetic containers.
private extension WebMDemuxerTests {

    /// Encodes an element ID in its shortest form.
    func elementID(_ id: UInt64) -> [UInt8] {
        for length in 1...8 {
            guard id < 1 << (8 * length),
                  UInt8(truncatingIfNeeded: id >> (8 * (length - 1))) & (0x80 >> (length - 1)) != 0
            else { continue }
            return (0..<length).reversed().map { UInt8(truncatingIfNeeded: id >> (8 * $0)) }
        }
        return []
    }

    /// Encodes an element size in its shortest form.
    func elementSize(_ size: Int) -> [UInt8] {
        for length in 1...8 {
            guard size <= (1 << (8 * length - length)) - 1 else { continue }
            var bytes = (0..<length).reversed().map { index -> UInt8 in
                UInt8(truncatingIfNeeded: size >> (8 * index))
            }
            bytes[0] |= 0x80 >> (length - 1)
            return bytes
        }
        return []
    }
}

private extension Int {
    /// A lacing size: one byte per 255, the remainder last.
    func encodingLacingSize() -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: self / 255)
        bytes.append(UInt8(self % 255))
        return bytes
    }
}
