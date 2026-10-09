import XCTest
@testable import APlay

final class ResumeCacheSeekTests: XCTestCase {
    private var harness: ResumeCacheTestHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ResumeCacheTestHarness()
    }

    override func tearDown() {
        harness?.destroy()
        harness = nil
        super.tearDown()
    }

    func testMultipleSeeksLeaveMultipleHolesThatAllGetRefilled() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        try h.interruptedDownload()
        let (streamer, _) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 20_000)

        XCTAssertTrue(h.waitUntil(timeout: 8) { h.exists(h.finalURL) },
                      "Reaching the tail must trigger a refill of every missing whole block")
        let ranges = RangeServerProtocol.streamRequests.suffix(2)
            .map { $0.value(forHTTPHeaderField: "Range") }
        XCTAssertEqual(ranges, ["bytes=20000-", "bytes=8192-"])
        XCTAssertEqual(try Data(contentsOf: h.finalURL), h.fixture)
    }

    func testSeekBackToZeroReplaysCachedOpeningWithoutRefetchingIt() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        try h.interruptedDownload()
        RangeServerProtocol.configure(body: h.fixture, delayNext: 0.65)
        let (streamer, collector) = h.makeStreamer()
        let openedAt = ProcessInfo.processInfo.systemUptime
        streamer.open(url: h.testURL, at: 0)

        // Observe the cached opening before the delayed response can supply bytes.
        XCTAssertTrue(h.waitUntil(timeout: 0.5) { h.audio(collector).count >= 8192 })
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - openedAt, 0.65)
        XCTAssertEqual(h.audio(collector).prefix(8192), h.fixture.prefix(8192))
        XCTAssertTrue(h.waitUntil(timeout: 8) { h.audio(collector) == h.fixture })
        XCTAssertEqual(RangeServerProtocol.streamRequests.count, 2)
        XCTAssertEqual(RangeServerProtocol.streamRequests.last?.value(forHTTPHeaderField: "Range"),
                       "bytes=8192-", "The cached opening must not be fetched again")
    }

    func testCorruptSidecarFallsBackToAFullDownload() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        try h.interruptedDownload()
        try Data(repeating: 0x7f, count: 64).write(to: h.partURL.appendingPathExtension("meta"))
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 0)

        XCTAssertTrue(h.waitUntil(timeout: 8) { h.audio(collector) == h.fixture })
        XCTAssertTrue(h.waitUntil(timeout: 8) { h.exists(h.finalURL) })
        XCTAssertEqual(try Data(contentsOf: h.finalURL), h.fixture)
        XCTAssertEqual(RangeServerProtocol.streamRequests.count, 2)
        XCTAssertNil(RangeServerProtocol.streamRequests.last?.value(forHTTPHeaderField: "Range"),
                     "An invalid sidecar must cause a full download")
    }

    func testSeekIntoTheFinalBlockPlaysToTheEnd() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        try h.interruptedDownload()
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 36_500)

        let tail = h.fixture.subdata(in: 36_500..<h.fixture.count)
        XCTAssertTrue(h.waitUntil(timeout: 8) { h.audio(collector) == tail },
                      "The reader must resume when the partially fetched final block becomes complete")
        XCTAssertTrue(h.waitUntil(timeout: 8) { h.exists(h.finalURL) })
    }
}
