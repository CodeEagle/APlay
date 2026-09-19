//
//  ComposerCoordinationTests.swift
//
//  Tests the Composer's wiring: a fake streamer/decoder/player stand in for the
//  real components through the framework's own injection seams, so the event
//  flow (open -> readyForRead -> hasBytesAvailable -> endEncountered) can be
//  asserted without touching the audio stack.
//

import XCTest
@testable import APlay

// MARK: - Fakes

/// Records what the Composer asks of a stream provider and can push events back.
final class FakeStreamProvider: StreamProviderCompatible {
    var outputPipeline = Delegated<StreamProvider.Event, Void>()

    var position: StreamProvider.Position = 0
    var contentLength: UInt = 100
    var info: StreamProvider.URLInfo = .remote(URL(string: "https://example.com/a.mp3")!, .mp3)
    var bufferingProgress: Float = 0.5

    private(set) var openCalls: [(url: URL, position: StreamProvider.Position)] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var destroyCount = 0

    func open(url: URL, at position: StreamProvider.Position) {
        openCalls.append((url, position))
        // Reflect the requested url so callers that key on `composer.url`
        // (preload reuse) see a match, while keeping whatever file hint the
        // test configured (issue #17 asserts an injected decoder sees .opus).
        info = .remote(url, info.fileHint)
    }

    func destroy() { destroyCount += 1 }
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }

    init(config: ConfigurationCompatible) {}
    init() {}

    /// Drives an event into the Composer exactly as a real streamer would.
    func emit(_ event: StreamProvider.Event) {
        outputPipeline.call(event)
    }
}

/// Records the packets the decoder is handed and can push decoder events back.
final class FakeDecoder: AudioDecoderCompatible {
    let info = AudioDecoder.Info()
    let outputStream = Delegated<AudioDecoder.Event, Void>()
    let inputStream = Delegated<AudioDecoder.AudioInput, Void>()

    private(set) var prepareCalls: [StreamProvider.Position] = []
    /// The file hint each `prepare` observed on the streamer it was handed.
    private(set) var prepareFileHints: [AudioFileType] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var destroyCount = 0
    private(set) var inputPackets: [(bytes: [UInt8], isFirst: Bool)] = []

    func prepare(for provider: StreamProviderCompatible, at position: StreamProvider.Position) throws {
        prepareCalls.append(position)
        prepareFileHints.append(provider.info.fileHint)
        // The decoder must be handed the streamer it is parsing for, so that
        // duration/seek math can read contentLength and position.
        XCTAssertTrue((provider as AnyObject) === attachedProvider, "decoder must be handed the exact streamer it parses for")
    }

    private weak var attachedProvider: AnyObject?

    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func destroy() { destroyCount += 1 }
    func seekable() -> Bool { true }

    init(config: ConfigurationCompatible) {
        attachedProvider = nil
    }

    init() {}

    /// Wires the packet recorder; called by the test before driving events.
    func recordInput() {
        inputStream.manuallyDelegate { [weak self] input in
            guard let self = self else { return }
            let bytes = Array(UnsafeBufferPointer(start: input.0, count: Int(input.1)))
            self.inputPackets.append((bytes, input.2))
        }
    }
}

/// No-op player so the test never touches an audio unit.
final class FakePlayer: PlayerCompatible {
    var readClosure: (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) = { _, _ in (0, false) }
    let eventPipeline = Delegated<Player.Event, Void>()
    var startTime: Float = 0
    var asbd = AudioStreamBasicDescription()
    var state: Player.State = .idle
    var volume: Float = 1
    private(set) var setupCount = 0
    private(set) var resumeCount = 0
    private(set) var pauseCount = 0

    func destroy() {}
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func toggle() {}
    func setup(_: AudioStreamBasicDescription) { setupCount += 1 }
    func currentTime() -> Float { 0 }
    init(config: ConfigurationCompatible) {}
    init() {}
}

// MARK: - Tests

final class ComposerCoordinationTests: XCTestCase {

    final class Collector {
        private let lock = NSLock()
        private var _events: [Composer.Event] = []
        func append(_ event: Composer.Event) { lock.lock(); _events.append(event); lock.unlock() }
        var events: [Composer.Event] { lock.lock(); defer { lock.unlock() }; return _events }
    }

    /// Builds a Composer wired entirely to fakes through the Configuration
    /// builder seams, and keeps strong references to the fakes for driving.
    struct Harness {
        let composer: Composer
        let streamer: FakeStreamProvider
        let decoder: FakeDecoder
        let player: FakePlayer
        let collector: Collector
        // Composer holds its config unowned, so the config must outlive it.
        let config: APlay.Configuration
    }

    func makeHarness(url: URL = URL(string: "https://example.com/a.mp3")!,
                     fileHint: AudioFileType = .mp3) -> Harness {
        let streamer = FakeStreamProvider()
        let decoder = FakeDecoder()
        let player = FakePlayer()
        let collector = Collector()

        streamer.info = .remote(url, fileHint)

        // Point the decoder's prepare assertion at the streamer the Composer
        // actually builds with.
        decoder.setAttached(streamer)

        let config = APlay.Configuration(
            logPolicy: .disable,
            streamerBuilder: { _ in streamer },
            audioDecoderBuilder: { _ in decoder }
        )
        let composer = Composer(player: player, config: config)
        composer.eventPipeline.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        return Harness(composer: composer, streamer: streamer, decoder: decoder, player: player, collector: collector, config: config)
    }

    func testPlayOpensStreamerAndPreparesDecoder() {
        let harness = makeHarness()
        let url = URL(string: "https://example.com/a.mp3")!
        harness.decoder.recordInput()

        harness.composer.play(url)

        XCTAssertEqual(harness.streamer.openCalls.count, 1)
        XCTAssertEqual(harness.streamer.openCalls.first?.url, url)
        XCTAssertEqual(harness.streamer.openCalls.first?.position, 0)
        XCTAssertEqual(harness.player.setupCount, 1, "player must be set up to the canonical format on play")

        // readyForRead must prepare the decoder at the streamer's position.
        harness.streamer.emit(.readyForRead)
        XCTAssertEqual(harness.decoder.prepareCalls.count, 1)
        XCTAssertEqual(harness.decoder.prepareCalls.first, 0)
    }

    func testHasBytesAvailableFeedsDecoderAndReportsBuffering() {
        let harness = makeHarness()
        harness.decoder.recordInput()
        harness.composer.play(URL(string: "https://example.com/a.mp3")!)

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        payload.withUnsafeBufferPointer { ptr in
            harness.streamer.emit(.hasBytesAvailable(ptr.baseAddress!, UInt32(payload.count), true))
        }

        XCTAssertEqual(harness.decoder.inputPackets.count, 1)
        XCTAssertEqual(harness.decoder.inputPackets.first?.bytes, payload)
        XCTAssertEqual(harness.decoder.inputPackets.first?.isFirst, true)

        let buffering = harness.collector.events.filter { if case .buffering = $0 { return true }; return false }
        XCTAssertEqual(buffering.count, 1, "first data must report buffering progress")
    }

    func testEndEncounteredIsForwarded() {
        let harness = makeHarness()
        harness.composer.play(URL(string: "https://example.com/a.mp3")!)

        harness.streamer.emit(.endEncountered)

        XCTAssertTrue(harness.collector.events.contains(where: { if case .streamerEndEncountered = $0 { return true }; return false }),
                      "streamer end must surface on the composer pipeline")
    }

    func testErrorIsForwarded() {
        let harness = makeHarness()
        harness.composer.play(URL(string: "https://example.com/a.mp3")!)

        harness.streamer.emit(.errorOccurred(.network("boom")))

        let errors = harness.collector.events.filter { if case let .error(err) = $0 { return true }; return false }
        XCTAssertEqual(errors.count, 1)
        guard case let .error(err)? = errors.first else { return }
        guard case .network = err else {
            XCTFail("expected a network error, got \(err)")
            return
        }
    }

    func testDestroyTearsDownBothComponents() {
        let harness = makeHarness()
        harness.composer.play(URL(string: "https://example.com/a.mp3")!)

        harness.composer.destroy()

        XCTAssertEqual(harness.streamer.destroyCount, 1)
        XCTAssertEqual(harness.decoder.destroyCount, 1)
    }

    // MARK: - Preloading (issue #14)

    func testPrepareBuffersWithoutStartingOutput() {
        let harness = makeHarness()
        let url = URL(string: "https://example.com/a.mp3")!

        harness.composer.play(url, autoplay: false)

        XCTAssertEqual(harness.composer.isPreloading, true)
        XCTAssertEqual(harness.player.resumeCount, 0, "prepare must not start the output unit")
        XCTAssertEqual(harness.streamer.openCalls.count, 1)

        // Data still flows: readyForRead prepares the decoder as usual.
        harness.streamer.emit(.readyForRead)
        XCTAssertEqual(harness.decoder.prepareCalls.count, 1)
    }

    func testStartPlaybackResumesThePreloadedTrack() {
        let harness = makeHarness()
        let url = URL(string: "https://example.com/a.mp3")!
        harness.composer.play(url, autoplay: false)

        harness.composer.startPlayback()

        XCTAssertEqual(harness.composer.isPreloading, false)
        XCTAssertEqual(harness.player.resumeCount, 1, "startPlayback must resume the output unit exactly once")
    }

    func testStartPlaybackIsNoOpWhenNotPreloading() {
        let harness = makeHarness()
        harness.composer.play(URL(string: "https://example.com/a.mp3")!, autoplay: true)

        harness.composer.startPlayback()

        XCTAssertEqual(harness.composer.isPreloading, false)
        // The 0.5s auto-resume has not fired yet, and startPlayback must not add one.
        XCTAssertEqual(harness.player.resumeCount, 0)
    }

    // MARK: - Injected decoder (issue #17)

    func testOpusHintReachesTheInjectedDecoder() {
        // An app ships its own opus decoder through the `audioDecoderBuilder`
        // seam instead of `DefaultAudioDecoder`. The framework hands that
        // decoder the streamer it parses for, so the only thing the decoder
        // needs to recognise opus is the URL's file hint reaching it intact.
        let url = URL(string: "https://example.com/a.opus")!
        let harness = makeHarness(url: url, fileHint: .opus)

        harness.composer.play(url)
        harness.streamer.emit(.readyForRead)

        XCTAssertEqual(harness.decoder.prepareCalls.count, 1)
        XCTAssertEqual(harness.decoder.prepareFileHints, [.opus],
                       "the injected decoder must observe the opus hint at prepare time")
    }

    func testPauseAndResumePropagate() {
        let harness = makeHarness()
        harness.composer.play(URL(string: "https://example.com/a.mp3")!)
        // play() already wakes the decoder once.
        XCTAssertEqual(harness.decoder.resumeCount, 1)

        harness.composer.pause()
        XCTAssertEqual(harness.streamer.pauseCount, 1)
        XCTAssertEqual(harness.decoder.pauseCount, 1)

        harness.composer.resume()
        XCTAssertEqual(harness.streamer.resumeCount, 1)
        XCTAssertEqual(harness.decoder.resumeCount, 2)
    }
}

extension FakeDecoder {
    /// Links the fake decoder to the streamer the Composer will build with, so
    /// `prepare(for:at:)` can assert identity.
    func setAttached(_ provider: StreamProviderCompatible) {
        attachedProvider = provider as AnyObject
    }
}
