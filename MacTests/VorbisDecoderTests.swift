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
        XCTAssertEqual(decoder.info.dstFormat.mSampleRate, 44100, accuracy: 1,
                       "the wrapper delivers canonical PCM")
        XCTAssertEqual(decoder.info.dstFormat.mChannelsPerFrame, 2)
        XCTAssertTrue(decoder.seekable(), "a buffered local file must report seekable")
    }

    // MARK: - Routing

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
}
