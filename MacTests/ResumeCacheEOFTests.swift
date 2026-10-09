import XCTest
@testable import APlay

/// A remote stream reads a preallocated sparse container, not a normal file.
/// EOF must bypass the bitmap; missing blocks before EOF must still wait.
final class ResumeCacheEOFTests: XCTestCase {
    private var harness: ResumeCacheTestHarness!
    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try ResumeCacheTestHarness()
    }
    override func tearDown() {
        RangeServerProtocol.releasePendingFailure()
        harness?.destroy()
        harness = nil
        super.tearDown()
    }
    private func endCount(_ collector: StreamerLocalTests.Collector) -> Int {
        collector.events.filter { if case .endEncountered = $0 { return true }; return false }.count
    }
    private func checkCompleteEOF(size: Int, position: UInt = 0) {
        let body = Data((0..<size).map { UInt8($0 % 251) })
        RangeServerProtocol.configure(body: body, clearRequests: true)
        let (streamer, collector) = harness.makeStreamer()
        streamer.open(url: harness.testURL, at: position)
        XCTAssertTrue(harness.waitUntil(timeout: 2) { self.endCount(collector) > 0 },
                      "EOF must arrive for \(size) bytes, starting at \(position)")
        XCTAssertEqual(harness.audio(collector), Data(body.dropFirst(Int(position))), "all real bytes delivered once")
        XCTAssertEqual(endCount(collector), 1)
        XCTAssertEqual(streamer.bufferingProgress, 1)
        XCTAssertFalse(harness.waitUntil(timeout: 0.1) { self.endCount(collector) > 1 }, "no duplicate EOF")
    }
    func testOneExactBlockEnds() { checkCompleteEOF(size: 8192) }
    func testMultipleExactBlocksEnd() { checkCompleteEOF(size: 131_072) }
    func testPartialFinalBlockEnds() { checkCompleteEOF(size: 16_385) }
    func testSeekIntoAlignedFileEndsAfterItsRemainingBytes() { checkCompleteEOF(size: 16_384, position: 8192) }

    private func startAtMissingBlock() -> (StreamProviderCompatible, StreamerLocalTests.Collector) {
        let body = Data(repeating: 0x7f, count: 24_576)
        RangeServerProtocol.configure(body: body, failAfterBytesNext: 8192, clearRequests: true)
        let result = harness.makeStreamer()
        result.0.open(url: harness.testURL, at: 0)
        XCTAssertTrue(harness.waitUntil(timeout: 2) { self.harness.audio(result.1).count == 8192 })
        return result
    }
    func testMissingBlockBeforeEOFStillWaitsThenCompletesAfterRefill() {
        let (_, collector) = startAtMissingBlock()
        XCTAssertFalse(harness.waitUntil(timeout: 0.2) { self.endCount(collector) > 0 }, "a sparse hole is not EOF")
        RangeServerProtocol.releasePendingFailure()
        XCTAssertTrue(harness.waitUntil(timeout: 8) { self.endCount(collector) == 1 }, "refill eventually ends normally")
        XCTAssertEqual(harness.audio(collector), Data(repeating: 0x7f, count: 24_576))
    }
    func testPauseWhileWaitingDoesNotReportEOF() {
        let (streamer, collector) = startAtMissingBlock()
        streamer.pause()
        XCTAssertFalse(harness.waitUntil(timeout: 0.25) { self.endCount(collector) > 0 }, "pause is not EOF")
        XCTAssertEqual(harness.audio(collector).count, 8192)
    }
    func testDestroyWhileWaitingDoesNotReportEOFAndReleasesOwner() {
        RangeServerProtocol.configure(body: Data(repeating: 0x7f, count: 24_576),
                                      failAfterBytesNext: 8192, clearRequests: true)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [RangeServerProtocol.self]
        let config = APlay.Configuration(logPolicy: .disable, cacheDirectory: harness.cacheDirectory.path,
            sessionBuilder: { _ in URLSession(configuration: session) })
        let collector = StreamerLocalTests.Collector()
        var streamer: StreamProviderCompatible? = config.streamerBuilder(config)
        weak var weakStreamer = streamer
        streamer?.outputPipeline.delegate(to: collector) { collector, event in collector.append(event) }
        streamer?.open(url: harness.testURL, at: 0)
        XCTAssertTrue(harness.waitUntil(timeout: 2) { self.harness.audio(collector).count == 8192 })
        streamer?.destroy()
        streamer = nil
        RangeServerProtocol.releasePendingFailure()
        XCTAssertTrue(harness.waitUntil(timeout: 2) { weakStreamer == nil }, "destroy must let the read-loop owner deallocate")
        XCTAssertEqual(endCount(collector), 0)
        config.session.invalidateAndCancel()
        withExtendedLifetime(config) {}
    }
}
