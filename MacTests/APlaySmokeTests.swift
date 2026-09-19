//
//  APlaySmokeTests.swift
//
//  Non-audio smoke checks so `swift test` stays green on macOS. Real end-to-end
//  playback is validated by the `APlayMacPlayback` executable (see
//  MacPlayback/main.swift), because the xctest process cannot start an output
//  audio unit on macOS (-10867).
//

import XCTest
import APlay

final class APlaySmokeTests: XCTestCase {

    /// The public event pipeline must be consumable from outside the module:
    /// `eventPipeline`/`state` previously referenced internal `Event`/`State`,
    /// which made the primary delegate API unusable for binary-framework users.
    func testPublicEventTypesAreReachable() throws {
        XCTAssertEqual(APlay.version, "2.0.0")

        let player = APlay()
        if case .idle = player.state {
            // expected initial state
        } else {
            XCTFail("expected .idle state, got \(player.state)")
        }
        XCTAssertEqual(player.duration, 0)

        var received = false
        player.eventPipeline.delegate(to: self) { _, event in
            if case .waitForStreaming = event { received = true }
        }
        player.eventPipeline.call(.waitForStreaming)
        XCTAssertTrue(received, "event pipeline did not deliver the posted event")
    }
}
