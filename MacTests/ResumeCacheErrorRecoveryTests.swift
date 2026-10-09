import XCTest
@testable import APlay

final class ResumeCacheErrorRecoveryTests: XCTestCase {
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

    func testMidTransferDropoutResumesFromWriteCursor() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        RangeServerProtocol.configure(body: h.fixture, failAfterBytesNext: 10_000)
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 0)

        // The mock parks the failure until the prefix is confirmed received,
        // because Foundation loses body that arrives alongside an error.
        XCTAssertTrue(h.waitUntil(timeout: 8) { h.audio(collector).count >= 8192 },
                      "The opening bytes must arrive before the dropout")
        RangeServerProtocol.releasePendingFailure()

        XCTAssertTrue(h.waitUntil(timeout: 8) { RangeServerProtocol.streamRequests.count >= 2 })
        let requests = RangeServerProtocol.streamRequests
        // The container already holds 10000 bytes, so the reconnect asks for the
        // remainder from the write cursor — not from a block boundary, and
        // certainly not from zero.
        XCTAssertEqual(requests.dropFirst().first?.value(forHTTPHeaderField: "Range"),
                       "bytes=10000-", "Recovery must resume from the write cursor")
        XCTAssertEqual(requests.dropFirst().first?.value(forHTTPHeaderField: "If-Range"),
                       "\"v1\"", "The reconnect must validate against the cached ETag")
        XCTAssertTrue(h.waitUntil(timeout: 8) {
            h.audio(collector) == h.fixture && h.exists(h.finalURL)
        }, "The dropout must recover and promote the complete fixture")
        XCTAssertEqual(h.audio(collector), h.fixture)
        XCTAssertTrue(h.exists(h.finalURL))
        XCTAssertEqual(try Data(contentsOf: h.finalURL), h.fixture)
    }

    func testServer500RetriesAndKeepsTheContainer() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        RangeServerProtocol.configure(body: h.fixture, statusOverrideNext: 500)
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 0)

        XCTAssertTrue(h.waitUntil(timeout: 8) { !RangeServerProtocol.streamRequests.isEmpty })
        // The 500 has no length, so only the successful retry creates a container.
        // Delay that retry's body to observe its container before promotion.
        RangeServerProtocol.configure(body: h.fixture, delayNext: 0.65)
        XCTAssertTrue(h.waitUntil(timeout: 8) { h.exists(h.partURL) },
                      "The successful retry must retain its container until completion")
        XCTAssertEqual(try Data(contentsOf: h.partURL).count, h.fixture.count)
        XCTAssertTrue(h.waitUntil(timeout: 8) {
            h.audio(collector) == h.fixture && h.exists(h.finalURL)
        }, "A transient 500 must recover and promote the container")
        XCTAssertEqual(h.audio(collector), h.fixture)
        XCTAssertTrue(h.exists(h.finalURL))
        XCTAssertEqual(try Data(contentsOf: h.finalURL), h.fixture)
        XCTAssertEqual(RangeServerProtocol.streamRequests.count, 2)
    }

    func testSeekBeyondTheEndReportsAnErrorRatherThanLooping() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 99_999)

        XCTAssertTrue(h.waitUntil(timeout: 6) {
            collector.events.contains { if case .error = $0 { return true }; return false }
        }, "An out-of-bounds seek must report an error within six seconds")
        XCTAssertEqual(RangeServerProtocol.streamRequests.first?.value(forHTTPHeaderField: "Range"),
                       "bytes=99999-")
        // Keep observing after the error across more than the two retry intervals.
        XCTAssertFalse(h.waitUntil(timeout: 2) { RangeServerProtocol.streamRequests.count > 3 },
                       "A 416 response must not cause an unbounded reconnect loop")
        XCTAssertLessThanOrEqual(RangeServerProtocol.streamRequests.count, 3)
    }

    func testDropoutMidRefillStillCompletes() throws {
        guard let h = harness else { XCTFail("harness unavailable"); return }
        try h.interruptedDownload()
        // The refill delivers a whole block past the cached one before dropping.
        RangeServerProtocol.configure(body: h.fixture, failAfterBytesNext: 8192)
        let (streamer, collector) = h.makeStreamer()
        streamer.open(url: h.testURL, at: 0)

        // One whole block past the cached opening must be playable before the
        // second dropout — a partial block is not enough for the reader.
        XCTAssertTrue(h.waitUntil(timeout: 8) { h.audio(collector).count >= 16_384 },
                      "The refill must deliver a whole block before dropping again")
        RangeServerProtocol.releasePendingFailure()

        XCTAssertTrue(h.waitUntil(timeout: 8) { RangeServerProtocol.streamRequests.count >= 3 },
                      "A dropout during refill must trigger another request")
        let refillRanges = RangeServerProtocol.streamRequests.dropFirst().prefix(2)
            .compactMap { $0.value(forHTTPHeaderField: "Range") }
        XCTAssertEqual(refillRanges, ["bytes=8192-", "bytes=16384-"],
                       "Each reconnect must resume from the write cursor it reached")
        XCTAssertTrue(h.waitUntil(timeout: 8) {
            h.audio(collector) == h.fixture && h.exists(h.finalURL)
        }, "Repeated interruptions must still converge to a complete cache")
        XCTAssertEqual(h.audio(collector), h.fixture)
        XCTAssertTrue(h.exists(h.finalURL))
        XCTAssertEqual(try Data(contentsOf: h.finalURL), h.fixture)
    }
}
