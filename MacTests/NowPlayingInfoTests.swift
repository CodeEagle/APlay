//
//  NowPlayingInfoTests.swift
//
//  macOS routes headset and media-key events only to the Now Playing app, and
//  an app claims that slot by publishing info + playback state. Publishing used
//  to be iOS/visionOS-only, which left Mac apps without remote-control events
//  entirely. These lock the macOS branch in.
//

import XCTest
@testable import APlay
#if os(macOS) || os(iOS) || os(visionOS)
    import MediaPlayer

    final class NowPlayingInfoTests: XCTestCase {

        // NowPlayingInfo holds its config `unowned`: the owner must keep the
        // Configuration alive for as long as the info object is used.
        private func makeInfo() -> (config: APlay.Configuration, info: APlay.NowPlayingInfo) {
            let config = APlay.Configuration()
            return (config, APlay.NowPlayingInfo(config: config))
        }

        func testPublishesMetadataAndPlayingState() {
            let (config, info) = makeInfo()
            withExtendedLifetime(config) {
                info.name = "Aurora"
                info.artist = "Bloom"
                info.album = "Filament"
                info.duration = 210
                // rate → 1, then update()
                info.play(elapsedPlayback: 0)

                let center = MPNowPlayingInfoCenter.default()
                let exp = expectation(description: "now playing info published")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let published = center.nowPlayingInfo
                    XCTAssertEqual(published?[MPMediaItemPropertyTitle] as? String, "Aurora")
                    XCTAssertEqual(published?[MPMediaItemPropertyArtist] as? String, "Bloom")
                    XCTAssertEqual(published?[MPMediaItemPropertyAlbumTitle] as? String, "Filament")
                    XCTAssertEqual(published?[MPMediaItemPropertyPlaybackDuration] as? Double, 210)
                    #if os(macOS)
                        XCTAssertEqual(center.playbackState, .playing, "macOS must see .playing to become the Now Playing app")
                    #endif
                    exp.fulfill()
                }
                wait(for: [exp], timeout: 2)
            }
        }

        func testPausePublishesPausedState() {
            let (config, info) = makeInfo()
            withExtendedLifetime(config) {
                info.play(elapsedPlayback: 5)
                info.pause(elapsedPlayback: 5)

                let center = MPNowPlayingInfoCenter.default()
                let exp = expectation(description: "paused state published")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    #if os(macOS)
                        XCTAssertEqual(center.playbackState, .paused)
                    #endif
                    let rate = center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double
                    XCTAssertEqual(rate, 0)
                    exp.fulfill()
                }
                wait(for: [exp], timeout: 2)
            }
        }

        func testRemoveClearsTheSlot() {
            let (config, info) = makeInfo()
            withExtendedLifetime(config) {
                info.name = "Lattice"
                info.play(elapsedPlayback: 0)
                info.remove()

                let center = MPNowPlayingInfoCenter.default()
                let exp = expectation(description: "slot cleared")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    #if os(macOS)
                        XCTAssertEqual(center.playbackState, .stopped)
                    #endif
                    XCTAssertNil(center.nowPlayingInfo?[MPMediaItemPropertyTitle])
                    exp.fulfill()
                }
                wait(for: [exp], timeout: 2)
            }
        }
    }
#endif
