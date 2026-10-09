//
//  ResumeCacheTests.swift
//
//  End-to-end coverage of resumable remote playback: a remote track is laid
//  out in a preallocated container the moment its length is known, cached
//  blocks are replayed locally, and only the missing blocks are fetched.
//

import XCTest
@testable import APlay

final class ResumeCacheTests: XCTestCase {
    private var harness: ResumeCacheTestHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ResumeCacheTestHarness()
    }

    override func tearDown() {
        harness.destroy()
        harness = nil
        super.tearDown()
    }

    func testFirstDownloadCreatesContainerAndStreamsWholeFixture() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        RangeServerProtocol.configure(body: h.fixture, delayNext: 0.65)
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 0)
        XCTAssertTrue(h.waitUntil { h.exists(h.partURL) })
        XCTAssertTrue(h.waitUntil { streamer.contentLength == UInt(h.fixture.count) })
        XCTAssertEqual(try Data(contentsOf: h.partURL).count, h.fixture.count)
        XCTAssertTrue(h.waitUntil { h.audio(collector) == h.fixture })
        XCTAssertEqual(RangeServerProtocol.streamRequests.count, 1)
    }

    func testReopenResumesAtFirstMissingWholeBlock() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        try h.interruptedDownload()
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 0)
        XCTAssertTrue(h.waitUntil { h.audio(collector) == h.fixture })
        let requests = RangeServerProtocol.streamRequests
        XCTAssertEqual(requests.count, 2, "Only one request should fill the missing blocks")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Range"), "bytes=8192-")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
        XCTAssertEqual(streamer.contentLength, UInt(h.fixture.count))
    }

    func testSeekInsideDownloadedBlockReadsLocallyAndRefillsTheHole() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        try h.interruptedDownload()
        let requestCount = RangeServerProtocol.streamRequests.count
        // Delay the missing bytes so the first delivered bytes can only come from disk.
        RangeServerProtocol.configure(body: h.fixture, delayNext: 0.65)
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 1024)
        XCTAssertTrue(h.waitUntil { h.audio(collector).count >= 7168 })
        XCTAssertEqual(Data(h.audio(collector).prefix(7168)), h.fixture.subdata(in: 1024..<8192))
        XCTAssertFalse(streamer.info.isRemote)
        XCTAssertEqual(streamer.info.url, h.partURL)
        // The container is still missing its tail, so the download must top it
        // up over the network — otherwise playback would stall at the hole
        // forever. What must not happen is re-fetching the cached bytes: the
        // refill starts at the first missing block, not at the play position.
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
        XCTAssertEqual(RangeServerProtocol.streamRequests.count, requestCount + 1,
                       "A partial container must be topped up over the network")
        XCTAssertEqual(RangeServerProtocol.streamRequests.last?.value(forHTTPHeaderField: "Range"),
                       "bytes=8192-",
                       "The refill must skip the downloaded blocks")
    }

    func testSeekIntoHoleRequestsRangeAndDeliversRemainingBytes() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        try h.interruptedDownload()
        let (streamer, collector) = h.makeStreamer()
        // The first missing block includes the incomplete half-block from the first transfer.
        streamer.open(url: h.testURL, at: 8192)
        XCTAssertTrue(h.waitUntil { h.audio(collector) == h.fixture.subdata(in: 8192..<h.fixture.count) })
        XCTAssertEqual(RangeServerProtocol.streamRequests.count, 2)
        XCTAssertEqual(RangeServerProtocol.streamRequests.last?.value(forHTTPHeaderField: "Range"), "bytes=8192-")
        XCTAssertEqual(streamer.contentLength, UInt(h.fixture.count))
        XCTAssertTrue(h.waitUntil { h.exists(h.finalURL) })
        XCTAssertEqual(try Data(contentsOf: h.finalURL), h.fixture)
    }

    func testChangedETagRebuildsShorterContainerWithoutOldTail() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        try h.interruptedDownload()
        var replacement = Data(h.fixture.prefix(24_576))
        replacement[9000] ^= 0x7f
        RangeServerProtocol.configure(body: replacement, etag: "\"v2\"")
        let (streamer, collector) = h.makeStreamer()
        // Start in a hole so no old cached prefix is read before HTTP validation.
        streamer.open(url: h.testURL, at: 8192)
        XCTAssertTrue(h.waitUntil { h.audio(collector) == replacement.subdata(in: 8192..<replacement.count) })
        XCTAssertEqual(RangeServerProtocol.streamRequests.last?.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
        XCTAssertEqual(RangeServerProtocol.streamRequests.last?.value(forHTTPHeaderField: "Range"), "bytes=8192-")
        XCTAssertEqual(RangeServerProtocol.streamRequests.count, 2)
        XCTAssertEqual(streamer.contentLength, UInt(replacement.count))
        XCTAssertTrue(h.waitUntil { h.exists(h.finalURL) })
        XCTAssertEqual(try Data(contentsOf: h.finalURL), replacement, "The rebuilt file must contain no stale tail")
    }

    func testCompleteDownloadPromotesAndReopensWithoutNetwork() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        let (first, firstCollector) = h.makeStreamer()
        first.open(url: h.testURL, at: 0)
        XCTAssertTrue(h.waitUntil { h.audio(firstCollector) == h.fixture && h.exists(h.finalURL) })
        XCTAssertEqual(try Data(contentsOf: h.finalURL), h.fixture)
        XCTAssertFalse(h.exists(h.partURL))
        XCTAssertFalse(h.exists(h.partURL.appendingPathExtension("meta")))
        first.destroy()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let requestCount = RangeServerProtocol.streamRequests.count
        let (second, secondCollector) = h.makeStreamer()
        second.open(url: h.testURL, at: 0)
        XCTAssertTrue(h.waitUntil { h.audio(secondCollector) == h.fixture })
        XCTAssertFalse(second.info.isRemote)
        XCTAssertEqual(second.info.url, h.finalURL)
        XCTAssertEqual(second.contentLength, UInt(h.fixture.count))
        XCTAssertEqual(RangeServerProtocol.streamRequests.count, requestCount)
    }

    func testSeekPastTheGapRefillsTheHoleAndPromotes() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        // The opening is on disk; a seek past the gap it leaves pulls the tail
        // first, leaving the middle sparse. The download must notice the hole
        // once it reaches the end and refill it from the first missing block,
        // otherwise the container could never be promoted.
        try h.interruptedDownload()
        let (first, firstCollector) = h.makeStreamer()
        first.open(url: h.testURL, at: 30_000)

        XCTAssertTrue(h.waitUntil { h.exists(h.finalURL) },
                      "The hole must be refilled so the container can be promoted")
        XCTAssertEqual(try Data(contentsOf: h.finalURL), h.fixture,
                       "The promoted file must contain every block")
        XCTAssertTrue(h.waitUntil { h.audio(firstCollector) == h.fixture.subdata(in: 30_000..<h.fixture.count) },
                      "Playback at the seek point must deliver the tail")

        let ranges = RangeServerProtocol.streamRequests
            .suffix(2).compactMap { $0.value(forHTTPHeaderField: "Range") }
        XCTAssertEqual(ranges, ["bytes=30000-", "bytes=8192-"],
                       "The tail is fetched first, then the hole from its first missing block")

        first.destroy()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        // A complete container is a plain cache hit: the reopen uses no network.
        let requestCount = RangeServerProtocol.streamRequests.count
        let (second, secondCollector) = h.makeStreamer()
        second.open(url: h.testURL, at: 0)
        XCTAssertTrue(h.waitUntil { h.audio(secondCollector) == h.fixture })
        XCTAssertEqual(RangeServerProtocol.streamRequests.count, requestCount,
                       "A complete cache must reopen without any network request")
    }
}
