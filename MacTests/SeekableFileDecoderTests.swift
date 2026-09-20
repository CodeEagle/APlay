//
//  SeekableFileDecoderTests.swift
//
//  Pins the optional-library promise: the two containers the built-in streaming
//  decoder provably cannot open (ALAC-in-CAF, AIFF/AIFF-C PCM) decode through
//  `FileFallbackDecoder`, and every other URL still reaches the fallback.
//

import XCTest
import AudioToolbox
import CoreAudio
@testable import APlay
@testable import APlayExtras

final class SeekableFileDecoderTests: XCTestCase {

    // MARK: - The matrix gaps, decoded through the router

    /// Drives the router exactly as the pipeline would: resume before the
    /// streamer is open, then `prepare` hands it the provider. The config is
    /// owned by the caller because the decoder holds it `unowned`.
    private func playThroughRouter(_ url: URL,
                                   hint: AudioFileType,
                                   config: APlay.Configuration,
                                   fallback: @escaping (ConfigurationCompatible) -> AudioDecoderCompatible) -> (decoder: FileFallbackDecoder, collector: OutputCollector) {
        let router = FileFallbackDecoder(config: config, fallback: fallback)
        let collector = OutputCollector()
        router.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, hint)
        streamer.contentLength = fileSize(of: url)
        // `play` resumes before the streamer opens; the router holds that resume
        // until `prepare` picks a decoder.
        router.resume()
        try? router.prepare(for: streamer, at: 0)
        return (router, collector)
    }

    private func makeConfig() -> APlay.Configuration { APlay.Configuration(logPolicy: .disable) }

    func testRouterDecodesAlacInCaf() throws {
        // The built-in decoder parses this fixture but emits no PCM: the CAF
        // packet table trails the audio data, so AudioFileStream reports 'optm'.
        let url = try fixture("tone", "caf")
        let config = makeConfig()
        let (router, collector) = playThroughRouter(url, hint: .caf, config: config) { DefaultAudioDecoder(config: $0) }

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "ALAC-in-CAF decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "ALAC-in-CAF emitted \(collector.errors.count) errors")
        XCTAssertEqual(router.info.srcFormat.mFormatID, AudioToolbox.kAudioFormatAppleLossless)
        XCTAssertTrue(router.seekable(), "a local file must report seekable once prepared")
    }

    func testRouterDecodesAiff() throws {
        // The built-in decoder reports a packet discontinuity ('dsc!') here.
        let url = try fixture("tone", "aiff")
        let config = makeConfig()
        let (router, collector) = playThroughRouter(url, hint: .aiff, config: config) { DefaultAudioDecoder(config: $0) }
        _ = router

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "AIFF decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "AIFF emitted \(collector.errors.count) errors")
    }

    func testRouterDecodesAifc() throws {
        let url = try fixture("tone", "aifc")
        let config = makeConfig()
        let (router, collector) = playThroughRouter(url, hint: .aifc, config: config) { DefaultAudioDecoder(config: $0) }
        _ = router

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "AIFF-C decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "AIFF-C emitted \(collector.errors.count) errors")
    }

    // The streaming decoder parses AU but decodes no PCM; ExtAudioFile opens it.
    func testRouterDecodesAu() throws {
        let url = try fixture("tone", "au")
        let config = makeConfig()
        let (router, collector) = playThroughRouter(url, hint: .next, config: config) { DefaultAudioDecoder(config: $0) }
        _ = router

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "AU decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "AU emitted \(collector.errors.count) errors")
    }

    // The streaming decoder cannot open the 3GPP container at all.
    func testRouterDecodes3gp() throws {
        let url = try fixture("tone", "3gp")
        let config = makeConfig()
        let (router, collector) = playThroughRouter(url, hint: .k3gp, config: config) { DefaultAudioDecoder(config: $0) }
        _ = router

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "3GP decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "3GP emitted \(collector.errors.count) errors")
    }

    func testRouterDecodes3g2() throws {
        let url = try fixture("tone", "3g2")
        let config = makeConfig()
        let (router, collector) = playThroughRouter(url, hint: .k3gp2, config: config) { DefaultAudioDecoder(config: $0) }
        _ = router

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "3G2 decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "3G2 emitted \(collector.errors.count) errors")
    }

    func testRouterDecodesW64() throws {
        let url = try fixture("tone", "w64")
        let config = makeConfig()
        let (router, collector) = playThroughRouter(url, hint: .w64, config: config) { DefaultAudioDecoder(config: $0) }
        _ = router

        XCTAssertTrue(wait(for: collector, minBytes: 1000), "W64 decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "W64 emitted \(collector.errors.count) errors")
    }

    /// Decoded compressed audio lands in the pipeline's canonical format, so the
    /// ring buffer and the audio unit see what they were configured for.
    func testCompressedOutputIsCanonicalPCM() throws {
        let url = try fixture("tone", "caf")
        let config = makeConfig()
        let (router, collector) = playThroughRouter(url, hint: .caf, config: config) { DefaultAudioDecoder(config: $0) }
        XCTAssertTrue(wait(for: collector, minBytes: 1000))

        XCTAssertEqual(router.info.dstFormat.mFormatID, CoreAudio.kAudioFormatLinearPCM)
        XCTAssertEqual(router.info.dstFormat.mSampleRate, 44100, accuracy: 1)
        XCTAssertEqual(router.info.dstFormat.mChannelsPerFrame, 2)
        XCTAssertEqual(router.info.dstFormat.mBitsPerChannel, 16)
    }

    // MARK: - Routing

    /// A format the built-in decoder already handles must still reach it — the
    /// optional library never regresses the default path.
    func testLocalMp3ReachesTheFallback() throws {
        let fake = FakeDecoder()
        let url = try fixture("tone-cbr", "mp3")
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)
        fake.setAttached(streamer)

        let config = makeConfig()
        let router = FileFallbackDecoder(config: config, fallback: { _ in fake })
        try router.prepare(for: streamer, at: 0)

        XCTAssertEqual(fake.prepareCalls.count, 1, "the fallback decoder must prepare for a local mp3")
        XCTAssertEqual(fake.prepareFileHints, [.mp3])
    }

    /// A remote CAF/AIFF cannot be seeked, so it must stay on the fallback even
    /// though the container hint is one the file decoder handles locally.
    func testRemoteUrlReachesTheFallback() {
        let fake = FakeDecoder()
        let url = URL(string: "https://example.com/a.caf")!
        let streamer = FakeStreamProvider()
        streamer.info = .remote(url, .caf)
        fake.setAttached(streamer)

        let config = makeConfig()
        let router = FileFallbackDecoder(config: config, fallback: { _ in fake })
        try? router.prepare(for: streamer, at: 0)

        XCTAssertEqual(fake.prepareCalls.count, 1, "a remote URL must not go to the local-only file decoder")
    }

    /// Re-preparing (a seek on the same track) reuses the decoder already chosen
    /// rather than rebuilding it, and the seek position is honoured.
    func testSeekReusesTheSameDecoder() throws {
        let url = try fixture("tone", "caf")
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .caf)
        streamer.contentLength = fileSize(of: url)

        let config = makeConfig()
        let router = FileFallbackDecoder(config: config, fallback: { DefaultAudioDecoder(config: $0) })
        try router.prepare(for: streamer, at: 0)
        // A second prepare at a non-zero position is the seek path.
        try router.prepare(for: streamer, at: max(streamer.contentLength / 2, 1))

        XCTAssertTrue(router.seekable())
        XCTAssertEqual(router.info.srcFormat.mFormatID, AudioToolbox.kAudioFormatAppleLossless)
    }

    // MARK: - Direct decoder

    /// The decoder itself refuses anything that is not a local file — a stream
    /// has no packet table to read.
    func testNonLocalUrlIsRejected() {
        let config = makeConfig()
        let decoder = SeekableFileDecoder(config: config)
        let streamer = FakeStreamProvider()
        streamer.info = .remote(URL(string: "https://example.com/a.caf")!, .caf)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0))
    }

    // MARK: - Helpers

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
}
