//
//  OpusDecoderTests.swift
//
//  Pins the optional `APlayOpus` product: a local WebM/Matroska Opus file
//  decodes to canonical PCM through Core Audio, and every other URL still
//  reaches the fallback decoder.
//

import XCTest
import APlayOpus
import AudioToolbox
import CoreAudio
@testable import APlay
@testable import APlayOpus

final class OpusDecoderTests: XCTestCase {

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

    /// A local WebM file reaches this decoder and decodes to PCM in the
    /// pipeline's canonical format.
    func testDecodesWebM() throws {
        let url = try fixture("tone", "webm")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .webm)
        streamer.contentLength = fileSize(of: url)

        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "Opus decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "Opus emitted \(collector.errors.count) errors")
        XCTAssertEqual(decoder.info.dstFormat.mSampleRate, 44100, accuracy: 1,
                       "the wrapper delivers canonical PCM")
        XCTAssertEqual(decoder.info.dstFormat.mChannelsPerFrame, 2)
        XCTAssertEqual(decoder.info.srcFormat.mFormatID, kAudioFormatOpus)
        XCTAssertEqual(decoder.info.sampleRate, 48000, accuracy: 1,
                       "the source rate comes from the OpusHead")
        XCTAssertTrue(decoder.seekable(), "a buffered local file must report seekable")
    }

    /// The Matroska variant decodes the same way and surfaces its tags.
    func testDecodesMatroska() throws {
        let url = try fixture("tone", "mka")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mka)
        streamer.contentLength = fileSize(of: url)

        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "Opus decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty)
        XCTAssertEqual(collector.titles, ["APlay WebM/Opus tone"],
                       "the Matroska tags must surface as Now Playing metadata")
        XCTAssertEqual(collector.metadata.prefix(3).map { String(describing: $0) }, [
            "title(\"APlay WebM/Opus tone\")",
            "artist(\"APlay\")",
            "album(\"Fixtures\")",
        ], "got: \(collector.metadata)")
    }

    // MARK: - Lifecycle

    /// Decoding runs to the end of the file and reports it via `.empty`.
    func testReachesEndOfTheFile() throws {
        let url = try fixture("tone", "webm")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .webm)
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

        // Resuming after the end is a no-op, not a second run over the file.
        decoder.resume()
        XCTAssertEqual(collector.emptyCount, 1, "the end stands even if resumed after it")
        XCTAssertTrue(collector.errors.isEmpty)
    }

    /// Pausing suspends the render timer and resuming picks it back up.
    func testPauseAndResume() throws {
        let url = try fixture("tone", "webm")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .webm)
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

    /// Before a file is opened, the wrapper is transparent: pause and resume
    /// reach the fallback, and streamer bytes nobody asked for do not.
    func testPauseAndResumeBeforeTheFileIsOpened() {
        let fake = FakeDecoder()
        fake.recordInput()
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { _ in fake })(config)

        var byte: UInt8 = 0x42
        decoder.inputStream.call((withUnsafePointer(to: &byte) { $0 }, 1, true))
        XCTAssertEqual(fake.inputPackets.count, 0,
                       "bytes before a handoff must not reach the fallback")

        decoder.pause()
        decoder.resume()
        XCTAssertEqual(fake.pauseCount, 1, "an unopened decoder's pause reaches the fallback")
        XCTAssertEqual(fake.resumeCount, 1, "an unopened decoder's resume reaches the fallback")
    }

    /// Destroying the decoder stops decoding and closes the file, and the
    /// fallback is destroyed with it — the pipeline owns one decoder, not two.
    func testDestroyReachesTheFallback() throws {
        let fake = FakeDecoder()
        let url = try fixture("tone", "webm")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { _ in fake })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .webm)
        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)
        XCTAssertTrue(wait(for: collector, minBytes: 1000))

        decoder.pause()
        decoder.destroy()
        XCTAssertEqual(fake.destroyCount, 1, "the fallback must be destroyed with the wrapper")

        let after = collector.totalBytes
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(collector.totalBytes, after, "a destroyed decoder must stop decoding")
        XCTAssertFalse(decoder.seekable(), "the converter is disposed")
        XCTAssertTrue(collector.errors.isEmpty)
    }

    // MARK: - Routing

    /// Direct construction (no fallback) refuses a non-WebM URL with a parser
    /// error instead of mishandling it.
    func testDirectConstructionRefusesAnMp3() throws {
        let url = try fixture("tone-cbr", "mp3")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = OpusDecoder(config: config)

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0)) { error in
            guard case .parser = error as? APlay.Error else {
                XCTFail("expected a parser error, got \(error)"); return
            }
        }
        XCTAssertFalse(decoder.seekable(), "nothing was opened, so the decoder is not seekable")

        // The stand-in decoder's lifecycle is a no-op rather than a crash.
        decoder.pause()
        decoder.resume()
        decoder.destroy()
    }

    /// A file the demuxer cannot read reports a parser error rather than
    /// crashing.
    func testCorruptFileReportsAnError() throws {
        let corrupt = try fixture("tone", "webm")
            .deletingLastPathComponent()
            .appendingPathComponent("corrupt-\(UUID().uuidString).webm")
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00, 0x00]).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(corrupt, .webm)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0))
        XCTAssertEqual(collector.errors.count, 1)
    }

    // MARK: - Malformed files

    /// A URL that cannot be read reports a parser error rather than crashing.
    func testANonexistentFileReportsAnError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apl-missing-\(UUID().uuidString).webm")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .webm)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0))
        XCTAssertEqual(collector.errors.count, 1)
        XCTAssertFalse(decoder.seekable())
    }

    /// An Opus track with no packets has nothing to decode, which is a parser
    /// error — not an endless wait for PCM that never comes.
    func testATrackWithoutPacketsIsNotADecodableFile() throws {
        let url = try syntheticWebM(packets: 0)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .webm)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0))
        XCTAssertEqual(collector.errors.count, 1)
        XCTAssertFalse(decoder.seekable())
    }

    /// An OpusHead whose rate Core Audio will not build a converter for fails
    /// at open time, before a packet is ever handed to it.
    func testAnImpossibleSampleRateFailsAtOpen() throws {
        var head = testOpusHead
        head[12] = 0xFF; head[13] = 0xFF; head[14] = 0xFF; head[15] = 0xFF
        let url = try syntheticWebM(head: head, packets: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .webm)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0),
                             "a 4 GHz Opus track must not open")
        XCTAssertEqual(collector.errors.count, 1)
        XCTAssertFalse(decoder.seekable())
    }

    /// Packets that are not Opus are rejected mid-decode: the converter reports
    /// the error once and the decoder stops rather than spinning on garbage.
    func testGarbagePacketsReportADecodeError() throws {
        let url = try syntheticWebM(packets: 24)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .webm)
        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, collector.errors.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThanOrEqual(collector.errors.count, 1,
                                    "garbage packets must surface as a decode error")
        XCTAssertEqual(collector.emptyCount, 0, "an errored decode never reaches the end")

        let after = collector.totalBytes
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(collector.totalBytes, after, "the decoder must stop after the error")
    }

    /// A format this library does not own must still reach the fallback, so
    /// adding the product never regresses any other format. Routing only —
    /// whether the fallback actually decodes is its own test suite's job.
    func testMp3ReachesTheFallback() throws {
        let fake = FakeDecoder()
        let url = try fixture("tone-cbr", "mp3")
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)
        fake.setAttached(streamer)

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { _ in fake })(config)
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
        let decoder = APlayOpus.decoder(fallback: { _ in fake })(config)
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

    /// A URL this library owns after a fallback URL must switch back: the
    /// wrapper's own state, not the fallback's, describes the new track.
    func testReturnsFromTheFallback() throws {
        let fake = FakeDecoder()
        let mp3 = try fixture("tone-cbr", "mp3")
        let webm = try fixture("tone", "webm")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayOpus.decoder(fallback: { _ in fake })(config)

        var streamer = FakeStreamProvider()
        streamer.info = .local(mp3, .mp3)
        fake.setAttached(streamer)
        try decoder.prepare(for: streamer, at: 0)
        XCTAssertTrue(decoder.info === fake.info, "the mp3 must be handed off")

        streamer = FakeStreamProvider()
        streamer.info = .local(webm, .webm)
        try decoder.prepare(for: streamer, at: 0)
        XCTAssertFalse(decoder.info === fake.info, "the webm must be taken back")
        XCTAssertEqual(decoder.info.fileHint, .webm)
        XCTAssertEqual(decoder.info.srcFormat.mFormatID, kAudioFormatOpus)
        XCTAssertEqual(fake.pauseCount, 1, "the fallback must be paused when it is taken back")
    }

    // MARK: - Synthetic containers

    /// A WebM whose Opus track carries `head` and `count` noise packets — a
    /// container the decoder can open but Core Audio may refuse.
    private func syntheticWebM(head: [UInt8] = testOpusHead, packets count: Int) throws -> URL {
        var packets: [Data] = []
        var seed: UInt32 = 0x12345678
        for _ in 0..<count {
            var bytes = [UInt8](repeating: 0, count: 32)
            for index in bytes.indices {
                seed = seed &* 1_103515245 &+ 12345
                bytes[index] = UInt8(truncatingIfNeeded: seed >> 16)
            }
            packets.append(Data(bytes))
        }
        var body = ebmlTracks(codecID: "A_OPUS", head: head)
        if count > 0 { body.append(contentsOf: ebmlCluster(packets: packets)) }
        var file = ebmlHeader()
        file.append(contentsOf: ebmlSegment(body: body))
        return try temporaryFile(file, "webm")
    }
}
