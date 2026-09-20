//
//  SpeexDecoderTests.swift
//
//  Pins the optional `APlaySpeex` product: a local Speex file decodes to
//  canonical PCM through the vendored library, and every other URL still
//  reaches the fallback decoder.
//

import XCTest
import APlaySpeex
import AudioToolbox
import CoreAudio
@testable import APlay

final class SpeexDecoderTests: XCTestCase {

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

    /// A local Speex file reaches the vendored decoder and decodes to PCM in
    /// the pipeline's canonical format.
    func testDecodesSpeex() throws {
        let url = try fixture("tone", "spx")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlaySpeex.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .speex)
        streamer.contentLength = fileSize(of: url)

        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "Speex decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "Speex emitted \(collector.errors.count) errors")
        XCTAssertEqual(decoder.info.dstFormat.mSampleRate, 44100, accuracy: 1,
                       "the wrapper delivers canonical PCM")
        XCTAssertEqual(decoder.info.dstFormat.mChannelsPerFrame, 2)
        XCTAssertTrue(decoder.seekable(), "a buffered local file must report seekable")
    }

    // MARK: - Routing

    /// Direct construction (no fallback) refuses a non-Speex URL with a parser
    /// error instead of mishandling it.
    func testDirectConstructionRefusesAnMp3() throws {
        let url = try fixture("tone-cbr", "mp3")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = SpeexDecoder(config: config)

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0)) { error in
            guard case .parser = error as? APlay.Error else {
                XCTFail("expected a parser error, got \(error)"); return
            }
        }
        XCTAssertFalse(decoder.seekable())
    }

    /// A file libspeex cannot open reports a parser error rather than crashing.
    func testCorruptFileReportsAnError() throws {
        let url = try fixture("tone", "spx")
        let corrupt = url.deletingLastPathComponent()
            .appendingPathComponent("corrupt-\(UUID().uuidString).spx")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlaySpeex.decoder(fallback: { DefaultAudioDecoder(config: $0) })(config)
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }

        let streamer = FakeStreamProvider()
        streamer.info = .local(corrupt, .speex)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0))
        XCTAssertEqual(collector.errors.count, 1)
    }

    /// A format the Speex library does not own must still reach the fallback,
    /// so adding the product never regresses any other format. Routing only —
    /// whether the fallback actually decodes is its own test suite's job.
    func testMp3ReachesTheFallback() throws {
        let fake = FakeDecoder()
        let url = try fixture("tone-cbr", "mp3")
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)
        fake.setAttached(streamer)

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlaySpeex.decoder(fallback: { _ in fake })(config)
        try decoder.prepare(for: streamer, at: 0)

        XCTAssertEqual(fake.prepareCalls.count, 1, "the fallback decoder must prepare for a local mp3")
        XCTAssertEqual(fake.prepareFileHints, [.mp3])
    }
}
