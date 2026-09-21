//
//  VorbisDecoderTests.swift
//
//  Pins the optional `APlayVorbis` product: a local Ogg/Vorbis file decodes to
//  canonical PCM through the vendored library, and every other URL still
//  reaches the fallback decoder.
//

import XCTest
import APlayVorbis
import AudioToolbox
import CoreAudio
@testable import APlay

final class VorbisDecoderTests: XCTestCase {

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

    /// A local Ogg/Vorbis file reaches the vendored decoder and decodes to PCM in
    /// the pipeline's canonical format.
    func testDecodesVorbis() throws {
        let url = try fixture("tone", "ogg")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayVorbis.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .ogg)
        streamer.contentLength = fileSize(of: url)

        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "Vorbis decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "Vorbis emitted \(collector.errors.count) errors")
        XCTAssertEqual(collector.titles, ["APlay Ogg/Vorbis tone"],
                       "the Vorbis comment must surface as Now Playing metadata")
        XCTAssertEqual(decoder.info.dstFormat.mSampleRate, 44100, accuracy: 1,
                       "the wrapper delivers canonical PCM")
        XCTAssertEqual(decoder.info.dstFormat.mChannelsPerFrame, 2)
        XCTAssertTrue(decoder.seekable(), "a buffered local file must report seekable")
    }

    // MARK: - Routing

    /// Direct construction (no fallback) refuses a non-Ogg URL with a parser
    /// error instead of mishandling it.
    func testDirectConstructionRefusesAnMp3() throws {
        let url = try fixture("tone-cbr", "mp3")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = VorbisDecoder(config: config)

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0)) { error in
            guard case .parser = error as? APlay.Error else {
                XCTFail("expected a parser error, got \(error)"); return
            }
        }
        XCTAssertFalse(decoder.seekable())
    }

    /// A file libvorbis cannot open reports a parser error rather than crashing.
    func testCorruptFileReportsAnError() throws {
        let url = try fixture("tone", "ogg")
        let corrupt = url.deletingLastPathComponent()
            .appendingPathComponent("corrupt-\(UUID().uuidString).ogg")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayVorbis.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(corrupt, .ogg)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0))
        XCTAssertEqual(collector.errors.count, 1)
    }

    /// A format the Vorbis library does not own must still reach the fallback,
    /// so adding the product never regresses any other format. Routing only —
    /// whether the fallback actually decodes is its own test suite's job.
    func testMp3ReachesTheFallback() throws {
        let fake = FakeDecoder()
        let url = try fixture("tone-cbr", "mp3")
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)
        fake.setAttached(streamer)

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayVorbis.decoder(fallback: { _ in fake })(config)
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
        let decoder = APlayVorbis.decoder(fallback: { _ in fake })(config)
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

    /// An Ogg stream that turns out to be Opus still carries the `.ogg` hint, so
    /// this library claims it — libvorbis cannot open it, and the URL must go
    /// back to the fallback (Core Audio plays Opus-in-Ogg) instead of failing.
    func testOpusInOggReachesTheFallback() throws {
        let fake = FakeDecoder()
        let url = try fixture("tone-opus", "ogg")
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .ogg)
        fake.setAttached(streamer)

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayVorbis.decoder(fallback: { _ in fake })(config)
        try decoder.prepare(for: streamer, at: 0)

        XCTAssertEqual(fake.prepareCalls.count, 1, "Opus-in-Ogg must reach the fallback, not a parser error")
        XCTAssertEqual(fake.prepareFileHints, [.ogg])
        XCTAssertTrue(decoder.info === fake.info)
    }

    /// The headline promise end to end: with the product installed, an mp3 still
    /// decodes to PCM through the framework's own decoder.
    func testMp3DecodesThroughTheFallback() throws {
        let url = try fixture("tone-cbr", "mp3")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayVorbis.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)
        streamer.contentLength = fileSize(of: url)
        try decoder.prepare(for: streamer, at: 0)
        decoder.info.fileHint = .mp3
        decoder.resume()

        let data = try Data(contentsOf: url)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            decoder.inputStream.call((base, UInt32(data.count), true))
        }
        XCTAssertTrue(wait(for: collector, minBytes: 1000), "the fallback decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "the fallback emitted \(collector.errors.count) errors")
    }
}
