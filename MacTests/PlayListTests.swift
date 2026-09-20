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

    // MARK: - randomList

    func testRandomListIsOnlyLiveInRandomPattern() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.order, pipeline: pipeline)
        XCTAssertEqual(list.randomList, [], "nothing is shuffled while not in random mode")

        list.loopPattern = .random
        XCTAssertEqual(list.randomList.count, urls.count)
        XCTAssertEqual(Set(list.randomList), Set(urls), "switching to random must shuffle the whole list")

        list.loopPattern = .order
        XCTAssertEqual(list.randomList, [], "leaving random mode must drop the shuffled copy")
    }

    // MARK: - peekNextURL

    func testPeekNextURLDoesNotMoveTheIndex() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.order, pipeline: pipeline)
        XCTAssertEqual(list.playingIndex, 0)
        XCTAssertEqual(list.peekNextURL(), urls[1])
        XCTAssertEqual(list.playingIndex, 0, "peeking must not advance the playing index")
        XCTAssertEqual(list.nextURL(), urls[1], "peek and next must agree")
    }

    func testStopWhenAllPlayedPeeksNilAtTheLastTrack() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.stopWhenAllPlayed(.order), pipeline: pipeline)
        XCTAssertEqual(list.nextURL(), urls[1])
        XCTAssertEqual(list.nextURL(), urls[2])
        XCTAssertEqual(list.playingIndex, 2)
        XCTAssertNil(list.peekNextURL(), "nothing follows the last track")
        XCTAssertEqual(list.playingIndex, 2, "peeking must not move the playing index")
        XCTAssertNil(list.nextURL())
    }

    func testNestedStopWhenAllPlayedStillStops() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.stopWhenAllPlayed(.stopWhenAllPlayed(.order)), pipeline: pipeline)
        XCTAssertEqual(list.nextURL(), urls[1])
        XCTAssertEqual(list.nextURL(), urls[2])
        XCTAssertNil(list.nextURL(), "the nested pattern must recurse and still stop")
    }

    // MARK: - previousURL

    func testPreviousInRandomWrapsToTheLastTrack() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.random, pipeline: pipeline)
        let random = list.randomList
        XCTAssertEqual(list.previousURL(), random.last, "previous at the front wraps to the end of the shuffled list")
        XCTAssertEqual(list.playingIndex, random.count - 1)
        XCTAssertEqual(list.previousURL(), random[random.count - 2], "previous keeps walking the shuffled order backwards")
    }

    func testPreviousInSingleRepeatsTheCurrentTrack() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.single, pipeline: pipeline)
        XCTAssertEqual(list.previousURL(), urls[0], "single-loop previous repeats the current track")
        XCTAssertEqual(list.previousURL(), urls[0])
    }

    func testPreviousInStopWhenAllPlayedDelegatesToTheInnerPattern() {
        let pipeline = Delegated<APlay.Event, Void>()
        let single = makeList(.stopWhenAllPlayed(.single), pipeline: pipeline)
        XCTAssertNil(single.previousURL(),
                     "a single loop under stopWhenAllPlayed stops right away, even away from the last track")

        let ordered = makeList(.stopWhenAllPlayed(.order), pipeline: pipeline)
        XCTAssertEqual(ordered.previousURL(), urls[2], "the inner order pattern still wraps backwards")
    }

    /// Documented quirk: `.stopWhenAllPlayed(.single)` never yields a next or
    /// previous URL, because `_peekNext(.single)` consults the outer stop flag
    /// without looking at the playing position. Pinned so a later fix is a
    /// deliberate behaviour change rather than an accident.
    func testStopWhenAllPlayedSingleNeverAdvances() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.stopWhenAllPlayed(.single), pipeline: pipeline)
        XCTAssertNil(list.nextURL())
        XCTAssertNil(list.previousURL())
        XCTAssertEqual(list.playingIndex, 0)
    }

    // MARK: - play(at:)

    func testPlayAtInRandomUsesTheShuffledPosition() {
        let pipeline = Delegated<APlay.Event, Void>()
        let list = makeList(.random, pipeline: pipeline)
        let random = list.randomList
        let url = urls[1]
        XCTAssertEqual(list.play(at: 1), url)
        guard let shuffledIndex = random.firstIndex(of: url) else {
            return XCTFail("the shuffled list must contain \(url)")
        }
        XCTAssertEqual(list.playingIndex, shuffledIndex,
                       "playing a url must land on its position in the shuffled list")
    }

    // MARK: - events

    func testChangeListPublishesPlaylistAndIndexEvents() {
        var events: [APlay.Event] = []
        let pipeline = Delegated<APlay.Event, Void>()
        pipeline.manuallyDelegate { events.append($0) }
        let list = PlayList(pipeline: pipeline)
        list.loopPattern = .order
        list.changeList(to: urls, at: 1)

        XCTAssertEqual(events.count, 2)
        guard case let .playlistChanged(published, index) = events[0] else {
            return XCTFail("expected .playlistChanged, got \(events)")
        }
        XCTAssertEqual(published, urls)
        XCTAssertEqual(index, 1)
        guard case let .playingIndexChanged(index) = events[1] else {
            return XCTFail("expected .playingIndexChanged, got \(events)")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(list.playingIndex, 1)
    }

    func testChangeListInRandomPublishesTheShuffledList() {
        var events: [APlay.Event] = []
        let pipeline = Delegated<APlay.Event, Void>()
        pipeline.manuallyDelegate { events.append($0) }
        let list = PlayList(pipeline: pipeline)
        list.loopPattern = .random
        list.changeList(to: urls, at: 0)

        XCTAssertEqual(list.randomList.count, urls.count)
        guard let first = events.first, case let .playlistChanged(published, _) = first else {
            return XCTFail("expected .playlistChanged, got \(events)")
        }
        XCTAssertEqual(published, list.randomList,
                       "listeners must receive the shuffled order, not the raw one")
        XCTAssertEqual(Set(published), Set(urls))
    }
}
