//
//  ComposerLeakReproTests.swift
//
//  Reproduces the orphaned-Composer leak the leak report describes. The slots
//  `_currentComposer` / `_nextComposer` are guarded with a synchronous read but
//  written with an asynchronous barrier, so two concurrent callers can both
//  pass the guard, each create a composer and each enqueue a write; the last
//  write wins and the composers it overwrote are never `destroy()`ed — their
//  streamer, decoder and ring-buffer writer thread keep running.
//

import XCTest
@testable import APlay

final class ComposerLeakReproTests: XCTestCase {

    // MARK: - Fakes

    final class CountingStreamer: StreamProviderCompatible {
        var outputPipeline = Delegated<StreamProvider.Event, Void>()
        var position: StreamProvider.Position = 0
        var contentLength: UInt = 100
        var info: StreamProvider.URLInfo
        var bufferingProgress: Float = 0.5
        init(config: ConfigurationCompatible) {
            info = .remote(URL(string: "https://example.com/a.mp3")!, .mp3)
        }
        func open(url: URL, at position: StreamProvider.Position) {
            info = .remote(url, .mp3)
            self.position = position
        }
        func destroy() {}
        func pause() {}
        func resume() {}
    }

    final class CountingDecoder: AudioDecoderCompatible {
        let info = AudioDecoder.Info()
        let outputStream = Delegated<AudioDecoder.Event, Void>()
        let inputStream = Delegated<AudioDecoder.AudioInput, Void>()
        init(config: ConfigurationCompatible) {}
        func prepare(for provider: StreamProviderCompatible, at position: StreamProvider.Position) throws {}
        func destroy() {}
        func pause() {}
        func resume() {}
        func seekable() -> Bool { true }
    }

    final class Harness {
        let player = FakePlayer()
        let aplay: APlay
        let streamers = NSLockableBox<[CountingStreamer]>([])
        private let box = NSLockableBox<[CountingStreamer]>([])

        init(gapless: Bool = true) {
            let config = APlay.Configuration(
                logPolicy: .disable,
                autoFillID3InfoToNowPlayingCenter: false,
                autoHandlingInterruptEvent: false,
                gaplessPlaybackEnabled: gapless,
                // `box` is captured weakly: it is a stored property of the
                // harness, but the closure lives on the configuration the
                // harness also keeps, so `unowned` here is a dangling ref once
                // the harness deallocates while a composer is still tearing
                // down asynchronously.
                streamerBuilder: { [weak box] _ in
                    guard let box else { fatalError("harness released before a streamer was built") }
                    let s = CountingStreamer(config: APlay.Configuration())
                    box.update { $0.append(s) }
                    return s
                },
                audioDecoderBuilder: { _ in CountingDecoder(config: APlay.Configuration()) }
            )
            aplay = APlay(player: player, configuration: config)
            streamers.swap(box.read())
        }
    }

    // MARK: - The race

    /// Two queues call `play(_:)` at the same time. Both read the same old
    /// composer, both destroy it, both create a fresh one and both enqueue a
    /// barrier write. The second write overwrites the first composer, which is
    /// left running with no owner and no `destroy()`.
    func testConcurrentPlayOrphansTheLoser() {
        let urls = (0 ..< 40).map { URL(string: "https://example.com/t\($0).mp3")! }

        let h = Harness(gapless: true)
        defer { h.aplay.destroy() }

        h.aplay.play(urls, at: 0)

        // Two independent queues hammering the same player concurrently is
        // exactly the reported "several loading" state: the user skips while
        // the previous track is still buffering.
        let group = DispatchGroup()
        for _ in 0 ..< 2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for url in urls { h.aplay.play(url) }
                group.leave()
            }
        }
        let done = self.expectation(description: "both loops finished")
        group.notify(queue: .main) { done.fulfill() }
        wait(for: [done], timeout: 15)

        // The live-composer counter is a process-wide DEBUG diagnostic, so
               // other suites that build composers without tearing them down inflate
               // it; the leak this test is after is the delta over its own race.
        let baseline = Composer.liveCount
        let settled = waitUntil(timeout: 5) { Composer.liveCount - baseline <= 2 }
        XCTAssertTrue(settled, "composers never drained to the budget")
        XCTAssertLessThanOrEqual(Composer.liveCount - baseline, 2,
                                 "one current + one preloaded is the whole budget; got \(Composer.liveCount - baseline)")
    }

    /// The preload path has the same split: `guard _nextComposer == nil` reads
    /// synchronously while `_nextComposer = com` writes asynchronously, so two
    /// concurrent preloads both pass the guard and one composer is orphaned.
    func testConcurrentPreloadOrphansTheLoser() throws {
        let urls = (0 ..< 40).map { URL(string: "https://example.com/t\($0).mp3")! }

        let h = Harness(gapless: true)
        defer { h.aplay.destroy() }

        h.aplay.play(urls, at: 0)

        // Drive the end-of-track event that arms a preload from two queues at
        // once: the user's skip and the streamer's own callback queue.
        let group = DispatchGroup()
        for _ in 0 ..< 2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in urls {
                    let snapshot = h.streamers.read()
                    for streamer in snapshot {
                        streamer.outputPipeline.call(.endEncountered)
                    }
                }
                group.leave()
            }
        }
        let done = self.expectation(description: "both loops finished")
        group.notify(queue: .main) { done.fulfill() }
        wait(for: [done], timeout: 15)

        let baseline = Composer.liveCount
        let settled = waitUntil(timeout: 5) { Composer.liveCount - baseline <= 2 }
        XCTAssertTrue(settled, "composers never drained to the budget")
        XCTAssertLessThanOrEqual(Composer.liveCount - baseline, 2,
                                 "one current + one preloaded is the whole budget; got \(Composer.liveCount - baseline)")
    }

    // MARK: - Utils

    private func waitUntil(timeout: TimeInterval = 5, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

/// A tiny lock-protected box so the fakes can be appended from a builder
/// closure that runs before the harness is fully initialised, and read from
/// any queue during the race.
final class NSLockableBox<Value> {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
    func swap(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}
