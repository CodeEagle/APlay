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
