//
//  WavPackDecoderTests.swift
//
//  Pins the optional `APlayWavPack` product: a local WavPack file decodes to
//  canonical PCM through the vendored library, and every other URL still
//  reaches the fallback decoder.
//

import XCTest
import APlayWavPack
import AudioToolbox
import CoreAudio
@testable import APlay
@testable import APlayWavPack

final class WavPackDecoderTests: XCTestCase {

    private let harness = DecoderTestHarness()

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try harness.fixture(name, ext)
    }

    private func wait(for collector: OutputCollector, minBytes: Int) -> Bool {
        harness.waitForDecodedBytes(collector, minBytes: minBytes)
    }

    private func fileSize(of url: URL) -> UInt {
        UInt((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    // MARK: - Decoding

    /// A local WavPack file reaches the vendored decoder and decodes to PCM in
    /// the pipeline's canonical format.
    func testDecodesWavPack() throws {
        let url = try fixture("tone", "wv")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayWavPack.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .wavpack)
        streamer.contentLength = fileSize(of: url)

        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "WavPack decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "WavPack emitted \(collector.errors.count) errors")
        XCTAssertEqual(collector.titles, ["APlay WavPack tone"],
                       "the APEv2 trailer must surface as Now Playing metadata")
        XCTAssertEqual(decoder.info.dstFormat.mSampleRate, 44100, accuracy: 1,
                       "the wrapper delivers canonical PCM")
        XCTAssertEqual(decoder.info.dstFormat.mChannelsPerFrame, 2)
        XCTAssertTrue(decoder.seekable(), "a buffered local file must report seekable")
    }

    // MARK: - Lifecycle

    /// Decoding runs to the end of the file and reports it via `.empty`.
    func testReachesEndOfTheFile() throws {
        let url = try fixture("tone", "wv")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayWavPack.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .wavpack)
        streamer.contentLength = fileSize(of: url)
        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, collector.emptyCount == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(collector.totalBytes, 100_000,
                             "the whole clip should decode before the end is reported")
        XCTAssertEqual(collector.emptyCount, 1,
                       "the decoder must report the end of the file exactly once")
        XCTAssertTrue(collector.errors.isEmpty)
    }

    /// Pausing suspends the render timer and resuming picks it back up.
    func testPauseAndResume() throws {
        let url = try fixture("tone", "wv")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayWavPack.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .wavpack)
        streamer.contentLength = fileSize(of: url)
        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)
        XCTAssertTrue(wait(for: collector, minBytes: 20_000))

        decoder.pause()
        let paused = collector.totalBytes
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(collector.totalBytes, paused, "a paused decoder must keep decoding")

        decoder.resume()
        XCTAssertTrue(wait(for: collector, minBytes: paused + 20_000),
                      "a resumed decoder must keep decoding")
    }

    // MARK: - Routing

    /// Direct construction (no fallback) refuses a non-WavPack URL with a
    /// parser error instead of mishandling it.
    func testDirectConstructionRefusesAnMp3() throws {
        let url = try fixture("tone-cbr", "mp3")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = WavPackDecoder(config: config)

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0)) { error in
            guard case .parser = error as? APlay.Error else {
                XCTFail("expected a parser error, got \(error)"); return
            }
        }
        XCTAssertFalse(decoder.seekable(), "nothing was opened, so the decoder is not seekable")
    }
    /// A file the library cannot open reports a parser error rather than
    /// crashing.
    func testCorruptFileReportsAnError() throws {
        let url = try fixture("tone", "wv")
        let corrupt = url.deletingLastPathComponent()
            .appendingPathComponent("corrupt-\(UUID().uuidString).wv")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayWavPack.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(corrupt, .wavpack)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0))
        XCTAssertEqual(collector.errors.count, 1)
    }

    /// A format the WavPack library does not own must still reach the fallback,
    /// so adding the product never regresses any other format. Routing only —
    /// whether the fallback actually decodes is its own test suite's job.
    func testMp3ReachesTheFallback() throws {
        let fake = FakeDecoder()
        let url = try fixture("tone-cbr", "mp3")
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)
        fake.setAttached(streamer)

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayWavPack.decoder(fallback: { _ in fake })(config)
        try decoder.prepare(for: streamer, at: 0)

        XCTAssertEqual(fake.prepareCalls.count, 1, "the fallback decoder must prepare for a local mp3")
        XCTAssertEqual(fake.prepareFileHints, [.mp3])
    }

    /// Whatever the fallback emits must surface through this decoder's stream
    /// and its bytes must reach it: the pipeline subscribes to the wrapper, not
    /// to the fallback, so a missing relay would silence every other format.
    func testFallbackEventsAndBytesReachThePipeline() throws {
        let fake = FakeDecoder()
        fake.recordInput()
        fake.seekableValue = true
        let url = try fixture("tone-cbr", "mp3")
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)
        fake.setAttached(streamer)

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayWavPack.decoder(fallback: { _ in fake })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }
        try decoder.prepare(for: streamer, at: 0)

        fake.outputStream.call(.bitrate(32_000))
        fake.outputStream.call(.seekable(true))
        XCTAssertEqual(collector.bitrateEvents, 1, "the fallback's bitrate event was lost")
        XCTAssertEqual(collector.seekableEvents, 1, "the fallback's seekable event was lost")
        XCTAssertTrue(decoder.info === fake.info, "a handed-off URL must expose the fallback's info")
        XCTAssertTrue(decoder.seekable(), "a handed-off URL must report the fallback's seekability")

        var byte: UInt8 = 0x42
        decoder.inputStream.call((withUnsafePointer(to: &byte) { $0 }, 1, true))
        XCTAssertEqual(fake.inputPackets.count, 1, "streamer bytes must reach the fallback")
    }

    // MARK: - APEv2 tag parsing

    /// A synthetic APEv2 trailer parses without needing an encoded fixture.
    func testParsesSyntheticAPEv2Tag() {
        let items = APEv2TagParser.parse(syntheticAPEv2())
        XCTAssertEqual(items?.count, 2, "got: \(items ?? [])")
        if case let .title(value)? = items?.first {
            XCTAssertEqual(value, "APlay", "Title comes first in file order")
        } else {
            XCTFail("expected a title item, got: \(String(describing: items?.first))")
        }
        if case let .artist(value)? = items?.last {
            XCTAssertEqual(value, "SelfStudio")
        } else {
            XCTFail("expected an artist item, got: \(String(describing: items?.last))")
        }
    }

    /// The bundled fixture carries the tags `generate-fixtures.sh` writes.
    /// FFmpeg also appends its own `ENCODER` item, so only the scripted tags
    /// are pinned, in file order.
    func testParsesFixtureTag() throws {
        let url = try fixture("tone", "wv")
        let data = try Data(contentsOf: url)
        let items = try XCTUnwrap(APEv2TagParser.parse(data))
        XCTAssertEqual(items.prefix(3).map { String(describing: $0) }, [
            "title(\"APlay WavPack tone\")",
            "artist(\"APlay\")",
            "album(\"Fixtures\")",
        ], "got: \(items)")
    }

    /// A file without a trailer yields no items rather than an error.
    func testUntaggedFileYieldsNoItems() {
        XCTAssertNil(APEv2TagParser.parse(Data(repeating: 0x42, count: 128)))
    }

    private func syntheticAPEv2() -> Data {
        func appendLE32(_ data: inout Data, _ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        var data = Data(repeating: 0x42, count: 64)  // pretend audio

        var item = Data()
        appendLE32(&item, 5)                        // value size
        appendLE32(&item, 0)                        // flags: text
        item.append("Title\0".data(using: .utf8)!)
        item.append("APlay".data(using: .utf8)!)
        data.append(item)

        var item2 = Data()
        appendLE32(&item2, 10)
        appendLE32(&item2, 0)
        item2.append("Artist\0".data(using: .utf8)!)
        item2.append("SelfStudio".data(using: .utf8)!)
        data.append(item2)

        var footer = Data()
        footer.append("APETAGEX".data(using: .utf8)!)
        appendLE32(&footer, 2_000)                  // version
        appendLE32(&footer, UInt32(item.count + item2.count + 32))  // size
        appendLE32(&footer, 2)                      // item count
        appendLE32(&footer, 0)                      // flags
        footer.append(Data(repeating: 0, count: 8)) // reserved
        data.append(footer)
        return data
    }
}
