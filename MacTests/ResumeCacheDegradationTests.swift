import XCTest
@testable import APlay

final class ResumeCacheDegradationTests: XCTestCase {
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

    func testNoContentLengthFallsBackToSequentialAndStillPlays() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        RangeServerProtocol.configure(body: h.fixture, omitContentLengthNext: true)
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 0)

        XCTAssertTrue(h.waitUntil(timeout: 8) { h.audio(collector) == h.fixture },
                      "Sequential playback must deliver the complete fixture without Content-Length")
        XCTAssertFalse(h.exists(h.partURL))
        XCTAssertTrue(streamer.info.isRemote)
    }

    func testServerIgnoringRangeRebuildsTheContainerFromZero() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        try h.interruptedDownload()
        RangeServerProtocol.configure(body: h.fixture, ignoreRangeNext: true)
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 8192)

        let expectedAudio = h.fixture.subdata(in: 8192..<h.fixture.count)
        XCTAssertTrue(h.waitUntil(timeout: 8) { h.audio(collector) == expectedAudio },
                      "Restarting the container must preserve the reader's offset and deliver no stale bytes")
        let requests = RangeServerProtocol.streamRequests
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        if requests.count >= 2 {
            XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=8192-")
        }
        XCTAssertTrue(h.waitUntil(timeout: 8) { h.exists(h.finalURL) })
        XCTAssertEqual(try Data(contentsOf: h.finalURL), h.fixture,
                       "The rebuilt cache must contain the complete file without a stale tail")
    }

    func testLastModifiedOnlyValidatesTheRangeRequest() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        // The first download saw no ETag, so the table can only vouch for the
        // date; the reopen must send that date as `If-Range`, not an ETag.
        try h.interruptedDownload(validators: .lastModifiedOnly)
        RangeServerProtocol.configure(body: h.fixture, validators: .lastModifiedOnly)
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 0)

        XCTAssertTrue(h.waitUntil(timeout: 8) { h.audio(collector) == h.fixture })
        let requests = RangeServerProtocol.streamRequests
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        if requests.count >= 2 {
            XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=8192-")
            XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Range"),
                           RangeServerProtocol.lastModified)
        }
    }

    func testNoValidatorsAcceptsTheRangeUnvalidated() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        // Neither validator was ever sent, so the table holds none and the
        // reopen asks for its range without any `If-Range`.
        try h.interruptedDownload(validators: .none)
        RangeServerProtocol.configure(body: h.fixture, validators: .none)
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 0)

        XCTAssertTrue(h.waitUntil(timeout: 8) { h.audio(collector) == h.fixture })
        let requests = RangeServerProtocol.streamRequests
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        if requests.count >= 2 {
            XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=8192-")
            XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-Range"))
        }
    }
}
