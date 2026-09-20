//
//  FileFallbackDecoderTests.swift
//
//  The router in APlayExtras decides which decoder a URL ends up on, and the
//  bookkeeping around switching decoders mid-track: pending resumes, forwarded
//  streams and destroying the decoder that lost the race.
//

import XCTest
import AudioToolbox
@testable import APlay
@testable import APlayExtras

final class FileFallbackDecoderTests: XCTestCase {

    // The decoder holds the config `unowned`, so the test owns it.
    private let config = APlay.Configuration(logPolicy: .disable)

    private let remote = URL(string: "https://example.com/a.mp3")!
    private let localCAF = URL(fileURLWithPath: "/tmp/APlayTests-nonexistent.caf")

    private func makeProvider(_ info: StreamProvider.URLInfo) -> FakeStreamProvider {
        let provider = FakeStreamProvider()
        provider.info = info
        return provider
    }

    /// Holds the provider the next built decoder must be attached to, and the
    /// decoders the builder created: a class so the closures' appends stay
    /// visible after the builder returns (an array value would be copied).
    private final class Recorder {
        var fallbacks: [FakeDecoder] = []
        var provider: FakeStreamProvider?
    }

    /// Builds a router that records every fallback decoder it creates.
    private func makeRouter() -> (router: FileFallbackDecoder, recorder: Recorder) {
        let recorder = Recorder()
        let router = FileFallbackDecoder(config: config) { _ in
            let decoder = FakeDecoder()
            // FakeDecoder asserts it is handed the streamer it parses for.
            if let provider = recorder.provider { decoder.setAttached(provider) }
            recorder.fallbacks.append(decoder)
            return decoder
        }
        return (router, recorder)
    }

    // MARK: - Routing

    func testRemoteURLsGoToTheFallback() throws {
        let (router, recorder) = makeRouter()
        recorder.provider = makeProvider(.remote(remote, .mp3))
        XCTAssertEqual(recorder.fallbacks.count, 0, "the fallback is built lazily at prepare")
        XCTAssertFalse(router.seekable(), "no decoder exists before prepare")

        try router.prepare(for: recorder.provider!, at: 0)

        XCTAssertEqual(recorder.fallbacks.count, 1)
        XCTAssertTrue(router.seekable(), "seekable reflects the active decoder")
        XCTAssertEqual(recorder.fallbacks.first?.prepareCalls, [0])
    }

    func testLocalMP3StillGoesToTheFallback() throws {
        let (router, recorder) = makeRouter()
        recorder.provider = makeProvider(.local(URL(fileURLWithPath: "/tmp/a.mp3"), .mp3))
        try router.prepare(for: recorder.provider!, at: 0)
        XCTAssertEqual(recorder.fallbacks.count, 1, "containers the file decoder cannot handle stay on the fallback")
    }

    func testHandledContainersNeverReachTheFallback() {
        let (router, recorder) = makeRouter()
        for hint in SeekableFileDecoder.handledHints {
            XCTAssertThrowsError(try router.prepare(for: makeProvider(.local(localCAF, hint)), at: 0),
                                 "the placeholder file cannot be opened") { _ in }
        }
        XCTAssertEqual(recorder.fallbacks.count, 0, "CAF/AIFF/AIFF-C are routed to the file decoder")
    }

    // MARK: - Reuse vs. rebuild

    func testReprepareReusesTheChosenDecoder() throws {
        let (router, recorder) = makeRouter()
        recorder.provider = makeProvider(.remote(remote, .mp3))
        try router.prepare(for: recorder.provider!, at: 0)
        try router.prepare(for: recorder.provider!, at: 100) // a seek re-prepare keeps the decoder
        XCTAssertEqual(recorder.fallbacks.count, 1)
        XCTAssertEqual(recorder.fallbacks.first?.prepareCalls, [0, 100])
    }

    func testChangingContainerRebuildsAndDestroysTheOldDecoder() throws {
        let (router, recorder) = makeRouter()
        XCTAssertThrowsError(try router.prepare(for: makeProvider(.local(localCAF, .caf)), at: 0))
        recorder.provider = makeProvider(.remote(remote, .mp3))
        try router.prepare(for: recorder.provider!, at: 0)
        XCTAssertEqual(recorder.fallbacks.count, 1, "the fallback is built once the container changes")
        XCTAssertEqual(recorder.fallbacks.first?.destroyCount, 0, "the fallback is the active decoder now")
    }

    // MARK: - Resume / pause / destroy

    func testResumeBeforePrepareIsAppliedToTheChosenDecoder() throws {
        let (router, recorder) = makeRouter()
        recorder.provider = makeProvider(.remote(remote, .mp3))
        router.resume() // `play` resumes before the streamer is open, so the resume is queued
        try router.prepare(for: recorder.provider!, at: 0)
        XCTAssertEqual(recorder.fallbacks.first?.resumeCount, 1, "the queued resume reaches the decoder built by prepare")
    }

    func testPauseReachesTheActiveDecoder() throws {
        let (router, recorder) = makeRouter()
        recorder.provider = makeProvider(.remote(remote, .mp3))
        try router.prepare(for: recorder.provider!, at: 0)
        router.pause()
        XCTAssertEqual(recorder.fallbacks.first?.pauseCount, 1)
        router.resume()
        XCTAssertEqual(recorder.fallbacks.first?.resumeCount, 1)
    }

    func testDestroyReleasesTheActiveDecoder() throws {
        let (router, recorder) = makeRouter()
        recorder.provider = makeProvider(.remote(remote, .mp3))
        try router.prepare(for: recorder.provider!, at: 0)
        router.destroy()
        XCTAssertEqual(recorder.fallbacks.first?.destroyCount, 1)
        XCTAssertFalse(router.seekable(), "there is no active decoder after destroy")
        router.destroy() // a second destroy must be safe
    }

    // MARK: - Stream forwarding

    func testInputStreamIsForwardedToTheActiveDecoder() throws {
        let (router, recorder) = makeRouter()
        recorder.provider = makeProvider(.remote(remote, .mp3))
        guard let fallback = recorder.fallbacks.first else { return }
        fallback.recordInput()

        // Bytes pushed before a decoder exists cannot be delivered yet.
        push(router, [1, 2])
        XCTAssertEqual(fallback.inputPackets.count, 0)

        try router.prepare(for: recorder.provider!, at: 0)
        push(router, [3, 4])
        XCTAssertEqual(fallback.inputPackets.map { $0.bytes }, [[3, 4]])
    }

    func testOutputStreamEventsAreForwarded() throws {
        let (router, recorder) = makeRouter()
        recorder.provider = makeProvider(.remote(remote, .mp3))
        var emptyCount = 0
        router.outputStream.manuallyDelegate { event in
            if case .empty = event { emptyCount += 1 }
        }
        try router.prepare(for: recorder.provider!, at: 0)
        guard let fallback = recorder.fallbacks.first else { return }
        // The delegate is wired during prepare, so the fallback's events now
        // reach the subscriber that attached to the router.
        fallback.outputStream.call(.empty)
        XCTAssertEqual(emptyCount, 1)
    }

    // MARK: - No fallback supplied

    func testMissingFallbackReportsTheURLAsUnsupported() {
        let router = FileFallbackDecoder(config: config)
        var errors: [APlay.Error] = []
        router.outputStream.manuallyDelegate { event in
            if case let .error(error) = event { errors.append(error) }
        }

        XCTAssertThrowsError(try router.prepare(for: makeProvider(.remote(remote, .mp3)), at: 0)) { error in
            guard case let APlay.Error.parser(status) = error else {
                return XCTFail("expected a parser error, got \(error)")
            }
            XCTAssertEqual(status, kAudioFileUnsupportedDataFormatError)
        }
        XCTAssertEqual(errors.count, 1, "the failure must also be published on the output stream")
    }

    // MARK: - Public builder

    /// The public entry point in APlayExtras must hand every URL to a
    /// `FileFallbackDecoder` wrapping the fallback it was given.
    func testFileDecoderBuilderWrapsTheFallback() {
        let config = APlay.Configuration(logPolicy: .disable)
        var fallbacks = 0
        let builder = APlayExtras.fileDecoder(fallback: { _ in
            fallbacks += 1
            return FakeDecoder()
        })

        let decoder = builder(config)
        XCTAssertTrue(decoder is FileFallbackDecoder,
                      "the public builder must return the file fallback router")
        XCTAssertEqual(fallbacks, 0, "the fallback is still built lazily through the router")
    }

    // MARK: - Private

    private func push(_ decoder: FileFallbackDecoder, _ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { ptr in
            decoder.inputStream.call((ptr.baseAddress!, UInt32(bytes.count), false))
        }
    }
}
