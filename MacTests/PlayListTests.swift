//
//  PlayListTests.swift
//
//  Loop-pattern state machine tests. PlayList decides what plays next for
//  every public playback API, so the four loop patterns are pinned down here.
//

import XCTest
@testable import APlay

final class PlayListTests: XCTestCase {

    private let urls = (0 ..< 3).map { URL(string: "https://example.com/song\($0).mp3")! }

    /// `PlayList` holds an *unowned* reference to the pipeline, so the pipeline
    /// must outlive the list — APlay keeps it as a stored property in production.
    private func makeList(_ pattern: PlayList.LoopPattern, pipeline: Delegated<APlay.Event, Void>) -> PlayList {
        let list = PlayList(pipeline: pipeline)
        list.loopPattern = pattern
        list.changeList(to: urls, at: 0)
        return list
    }

    func testChangeListSetsIndexAndCurrentList() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.order, pipeline: pipeline)
        XCTAssertEqual(list.playingIndex, 0)
        XCTAssertEqual(list.list, urls)
        XCTAssertEqual(list.currentList, urls)
    }

    func testOrderPatternCyclesForward() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.order, pipeline: pipeline)
        XCTAssertEqual(list.nextURL(), urls[1])
        XCTAssertEqual(list.nextURL(), urls[2])
        XCTAssertEqual(list.nextURL(), urls[0], "order pattern should wrap to the start")
    }

    func testSinglePatternRepeatsTheSameTrack() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.single, pipeline: pipeline)
        // Single-loop repeats the *current* track, whatever it happens to be.
        XCTAssertEqual(list.nextURL(), urls[0])
        XCTAssertEqual(list.nextURL(), urls[0])
        XCTAssertEqual(list.nextURL(), urls[0])
    }

    func testStopWhenAllPlayedStopsAtTheEnd() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.stopWhenAllPlayed(.order), pipeline: pipeline)
        XCTAssertEqual(list.nextURL(), urls[1])
        XCTAssertEqual(list.nextURL(), urls[2])
        XCTAssertNil(list.nextURL(), "stopWhenAllPlayed must return nil at the last track")
    }

    func testPreviousPatternWrapsToTheLastTrack() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.order, pipeline: pipeline)
        XCTAssertEqual(list.previousURL(), urls[2], "previous at index 0 wraps to the end")
        XCTAssertEqual(list.previousURL(), urls[1])
    }

    func testRandomPatternKeepsTheSameSongSet() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.random, pipeline: pipeline)
        let random = list.currentList
        XCTAssertEqual(Set(random), Set(urls), "random list must contain every track exactly once")
        XCTAssertEqual(random.count, urls.count)

        // Walking the whole random list must not repeat or drop tracks.
        var seen = Set<URL>()
        for _ in urls.indices {
            if let url = list.nextURL() { seen.insert(url) }
        }
        XCTAssertEqual(seen.count, urls.count)
    }

    func testPlayAtOutOfRangeIndexReturnsNil() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.order, pipeline: pipeline)
        XCTAssertNil(list.play(at: 42))
        XCTAssertEqual(list.play(at: 2), urls[2])
    }
}
