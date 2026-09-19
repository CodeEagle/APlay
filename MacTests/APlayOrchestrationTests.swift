//
//  APlayOrchestrationTests.swift
//
//  Pins the APlay-level coordination between tracks: which components get
//  built and torn down when a track starts, ends, is preloaded, skipped or
//  seeked. The fakes from ComposerCoordinationTests stand in for the streamer,
//  decoder and player through the framework's own injection seams, so the
//  track-switching seams stay observable without any audio stack.
//
//  These are the paths gapless playback will change; they fix the current
//  end-of-track contract (pause -> playEnded -> rebuild) as a regression net.
//

import XCTest
@testable import APlay

final class APlayOrchestrationTests: XCTestCase {

    // MARK: - Harness

    final class Collector {
        private let lock = NSLock()
        private var _events: [APlay.Event] = []
        func append(_ event: APlay.Event) { lock.lock(); _events.append(event); lock.unlock() }
        var events: [APlay.Event] { lock.lock(); defer { lock.unlock() }; return _events }
    }

    /// Every Composer the APlay built, newest last. A fresh streamer/decoder
    /// pair is created per track, so the tests can assert on each one.
    final class Harness {
        let player = FakePlayer()
        let collector = Collector()
        let aplay: APlay
        let config: APlay.Configuration
        private let box = Recorder()

        var streamers: [FakeStreamProvider] { box.streamers }
        var decoders: [FakeDecoder] { box.decoders }

        init() {
            // APlay builds composers lazily on play(), so nothing is recorded
            // until a track starts.
            let config = APlay.Configuration(
                logPolicy: .disable,
                autoFillID3InfoToNowPlayingCenter: false,
                autoHandlingInterruptEvent: false,
                streamerBuilder: { [unowned box] _ in
                    let streamer = FakeStreamProvider()
                    box.streamers.append(streamer)
                    return streamer
                },
                audioDecoderBuilder: { [unowned box] _ in
                    let decoder = FakeDecoder()
                    decoder.setAttached(box.streamers.last!)
                    box.decoders.append(decoder)
                    return decoder
                }
            )
            self.config = config
            aplay = APlay(player: player, configuration: config)
            aplay.eventPipeline.delegate(to: collector) { collector, event in
                collector.append(event)
            }
        }
    }

    /// Mutable box the builder closures capture, since they run before the
    /// harness itself is initialised.
    private final class Recorder {
        var streamers: [FakeStreamProvider] = []
        var decoders: [FakeDecoder] = []
    }

    var harness: Harness?

    override func tearDown() {
        harness?.aplay.destroy()
        harness = nil
        super.tearDown()
    }

    /// Spins the run loop until `condition` holds — the track-switch work is
    /// dispatched to the main queue and to a barrier queue.
    func waitUntil(timeout: TimeInterval = 3, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    let url1 = URL(string: "https://example.com/one.mp3")!
    let url2 = URL(string: "https://example.com/two.mp3")!

    // MARK: - Starting a track

    func testPlayingAListOpensTheFirstTrack() {
        let h = Harness()
        harness = h
        h.aplay.play([url1, url2], at: 0)

        XCTAssertEqual(h.streamers.count, 1, "one composer per track")
        XCTAssertEqual(h.streamers.first?.openCalls.count, 1)
        XCTAssertEqual(h.streamers.first?.openCalls.first?.url, url1)
        XCTAssertEqual(h.streamers.first?.openCalls.first?.position, 0)
        XCTAssertEqual(h.player.setupCount, 1, "the output must be set up to the canonical format")
    }

    // MARK: - Preload seam (issue #14)

    func testPrepareThenPlayStartsFromThePreloadedComposer() {
        let h = Harness()
        harness = h
        h.aplay.prepare(url1)
        XCTAssertEqual(h.streamers.count, 1)
        XCTAssertEqual(h.player.resumeCount, 0, "prepare must not start the output")

        // Playing the preloaded URL picks the buffered composer back up.
        h.aplay.play(url1)

        XCTAssertEqual(h.streamers.count, 1, "the preloaded composer must be reused, not rebuilt")
        XCTAssertEqual(h.streamers.first?.openCalls.count, 1, "the stream must not be reopened")
        XCTAssertEqual(h.player.resumeCount, 1, "reuse starts the output from the ring buffer")
    }

    func testPlayRebuildsWhenThePreloadedUrlDiffers() {
        let h = Harness()
        harness = h
        h.aplay.prepare(url1)

        h.aplay.play(url2)

        XCTAssertEqual(h.streamers.count, 2, "a different URL cannot reuse the preload")
        XCTAssertEqual(h.streamers.last?.openCalls.first?.url, url2)
    }

    // MARK: - End of track (the seam gapless will replace)

    func testTrackEndPausesAdvancesAndRebuilds() {
        let h = Harness()
        harness = h
        h.aplay.play([url1, url2], at: 0)

        // The stream reports end, then the decoded ring buffer drains.
        h.streamers.first?.emit(.endEncountered)
        h.decoders.first?.outputStream.call(.empty)

        let advanced = waitUntil { h.streamers.count == 2 }
        XCTAssertTrue(advanced, "the next track must be built")

        XCTAssertTrue(h.collector.events.contains(where: { if case .playEnded = $0 { return true }; return false }),
                      "playEnded must be posted before advancing")
        XCTAssertEqual(h.streamers.last?.openCalls.first?.url, url2, "the playlist must advance in order")
        XCTAssertEqual(h.streamers.first?.destroyCount, 1, "the finished composer must be torn down")
        XCTAssertEqual(h.player.setupCount, 2, "the output is re-set up for the new track")
    }

    // MARK: - Skipping

    func testNextRebuildsTheComposer() {
        let h = Harness()
        harness = h
        h.aplay.play([url1, url2], at: 0)

        h.aplay.next()

        XCTAssertEqual(h.streamers.count, 2)
        XCTAssertEqual(h.streamers.last?.openCalls.first?.url, url2)
        XCTAssertEqual(h.streamers.first?.destroyCount, 1)
        XCTAssertTrue(h.collector.events.contains(where: { if case .playingIndexChanged = $0 { return true }; return false }))
    }

    // MARK: - Seek

    func testSeekRebuildsTheComposerForTheSameUrl() {
        let h = Harness()
        harness = h
        h.aplay.play([url1, url2], at: 0)
        let first = h.streamers.first

        h.aplay.seek(to: 5)

        XCTAssertEqual(h.streamers.count, 2, "seek must rebuild the composer")
        XCTAssertEqual(h.streamers.last?.openCalls.first?.url, url1, "seek stays on the current track")
        XCTAssertEqual(first?.destroyCount, 1)
    }
}
