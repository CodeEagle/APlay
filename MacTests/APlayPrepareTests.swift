//
//  APlayPrepareTests.swift
//
//  Issue #14: `prepare(_:)` must buffer a track without starting the output
//  audio unit, and a subsequent `play` of the same URL must reuse the prepared
//  composer instead of reopening the stream.
//

import XCTest
@testable import APlay

final class APlayPrepareTests: XCTestCase {

    /// The player itself is real, but the streamer is swapped for a fake through
    /// the Configuration seam, so reuse can be observed by counting opens.
    func testPrepareThenPlayReusesPreloadedComposer() throws {
        let streamer = FakeStreamProvider()
        let config = APlay.Configuration(
            logPolicy: .disable,
            streamerBuilder: { _ in streamer }
        )
        let player = APlay(configuration: config)
        let url = URL(fileURLWithPath: "/tmp/APlayPrepareTest.m4a")

        player.prepare(url)
        XCTAssertEqual(streamer.openCalls.count, 1, "prepare must open the streamer once")

        // Playing the same URL must pick up the prepared composer rather than
        // destroying it and opening a second stream.
        player.play(url)
        XCTAssertEqual(streamer.openCalls.count, 1, "play must reuse the preloaded streamer")
        XCTAssertEqual(streamer.destroyCount, 0, "play must not tear down the preloaded streamer")
    }

    /// Playing a different URL after prepare must fall back to a fresh open.
    func testPlayOfDifferentUrlOpensFresh() throws {
        let streamer = FakeStreamProvider()
        let config = APlay.Configuration(
            logPolicy: .disable,
            streamerBuilder: { _ in streamer }
        )
        let player = APlay(configuration: config)
        let prepared = URL(fileURLWithPath: "/tmp/APlayPrepareA.m4a")
        let other = URL(fileURLWithPath: "/tmp/APlayPrepareB.m4a")

        player.prepare(prepared)
        XCTAssertEqual(streamer.openCalls.count, 1)

        player.play(other)
        XCTAssertEqual(streamer.openCalls.count, 2, "a different URL must open a new stream")
        XCTAssertEqual(streamer.destroyCount, 1, "the prepared stream must be torn down")
    }
}
