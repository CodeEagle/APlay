//
//  StreamerCoverageTests.swift
//
//  Covers the Streamer's remote (HTTP) branches without touching the network:
//  a custom URLProtocol intercepts every request the Streamer makes and replays
//  a canned response, so response handling, retry and caching can be asserted
//  deterministically.
//
//  The Streamer builds its own URLSession from config.session.configuration,
//  so the protocol is registered through that configuration (via the
//  sessionBuilder seam) rather than by replacing the session itself.
//

import XCTest
@testable import APlay

final class StreamerCoverageTests: XCTestCase {

    // MARK: - Canned responses

    /// What the fake server should send back for the next request it sees.
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    /// A URLProtocol that answers the queued responses in order and logs every
    /// request the client makes. The ID3v1 probe is served separately so it
    /// cannot consume a response meant for the stream itself.
    final class FakeServerProtocol: URLProtocol {
        static let scheme = "https"
        static let id3v1ProbeRange = "bytes=-128"

        /// The protocol runs on its own thread while the tests read the counters
        /// from the main thread, so every access goes through `lock`.
        private static let lock = NSLock()
        private static var responses: [Response] = []
        private static var requestLog: [String] = []
        /// Requests issued by the stream itself (the ID3v1 probe excluded).
        private static var requestCount = 0

        static func reset(responses: [Response]) {
            lock.lock()
            self.responses = responses
            requestLog = []
            requestCount = 0
            lock.unlock()
        }

        static var servedRequests: [String] {
            lock.lock()
            defer { lock.unlock() }
            return requestLog
        }

        static var streamRequestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requestCount
        }

        /// Records the ID3v1 probe without consuming a queued response.
        static func recordProbe() {
            lock.lock()
            requestLog.append("probe id3v1")
            lock.unlock()
        }

        /// Dequeues the response for the stream's next request.
        static func nextResponse(range: String?) -> Response {
            lock.lock()
            requestCount += 1
            requestLog.append("#\(requestCount) range=\(range ?? "none")")
            let response = responses.isEmpty
                ? Response(statusCode: 404, headers: [:], body: Data())
                : responses.removeFirst()
            lock.unlock()
            return response
        }

        override class func canInit(with request: URLRequest) -> Bool {
            return request.url?.scheme == scheme
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }

        override func startLoading() {
            guard let url = request.url else { return }
            let range = request.value(forHTTPHeaderField: "Range")

            // `ID3Parser` reuses the same session to probe the last 128 bytes of
            // the file (Range: bytes=-128). Answer it without touching the
            // queued responses — otherwise the probe and the stream's own GET
            // would race for the same canned body. 128 zero bytes is a
            // well-formed response carrying no ID3v1 tag.
            if range == Self.id3v1ProbeRange {
                Self.recordProbe()
                let http = HTTPURLResponse(url: url, statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "128"])!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 128))
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            let response = Self.nextResponse(range: range)

            let http = HTTPURLResponse(url: url, statusCode: response.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            // URLSession never calls didReceive(data:) for an empty body, and the
            // streamer treats an empty data callback as a healthy-connection
            // signal that resets the reconnect watchdog.
            if response.body.isEmpty == false {
                client?.urlProtocol(self, didLoad: response.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: - Fixtures

    let collector = StreamerLocalTests.Collector()
    var streamer: StreamProviderCompatible?
    var config: APlay.Configuration?
    /// Per-test scratch cache dir. A shared default directory would let an
    /// earlier run's file satisfy `asCachedFileInfo()` and silently turn the
    /// remote stream into a local file.
    var cacheDir: URL?

    /// Builds a Streamer whose session is intercepted by the fake server.
    func makeRemoteStreamer(responses: [Response], cachePolicy: APlay.Configuration.CachePolicy = .enable([])) throws -> StreamProviderCompatible {
        FakeServerProtocol.reset(responses: responses)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServerProtocol.self]

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("APlayCacheTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDir = cacheDir

        // The Streamer re-creates its session from config.session.configuration,
        // so the protocol class survives the copy.
        let config = APlay.Configuration(
            logPolicy: .disable,
            cachePolicy: cachePolicy,
            cacheDirectory: cacheDir.path,
            maxRemoteStreamOpenRetry: 2,
            sessionBuilder: { _ in URLSession(configuration: configuration) }
        )
        let streamer = config.streamerBuilder(config)
        streamer.outputPipeline.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        self.config = config
        self.streamer = streamer
        return streamer
    }

    let testURL = URL(string: "https://aplay.example.com/a.mp3")!

    /// Spins the run loop until `condition` holds, so async streamer work can
    /// settle without assuming an ordering with the open() call.
    func waitUntil(timeout: TimeInterval = 5, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    override func tearDown() {
        streamer?.destroy()
        // `destroy()` queues the close onto the streamer's state queue with a
        // strong self capture, and the streamer reads its config through an
        // unowned reference — so the config must outlive that queued work.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        streamer = nil
        config = nil
        if let cacheDir { try? FileManager.default.removeItem(at: cacheDir) }
        self.cacheDir = nil
        super.tearDown()
    }

    // MARK: - Success

    func testRemote200StreamsBodyAndContentLength() throws {
        let body = Data(repeating: 0x4A, count: 32_768)
        let streamer = try makeRemoteStreamer(responses: [
            Response(statusCode: 200, headers: ["Content-Length": "\(body.count)"], body: body),
        ])

        streamer.open(url: testURL, at: 0)

        let delivered = waitUntil {
            let chunks = self.collector.events.compactMap { event -> [UInt8]? in
                if case let .bytes(bytes, _) = event { return bytes }
                return nil
            }
            return chunks.flatMap { $0 } == Array(body)
        }
        XCTAssertTrue(delivered, "the whole body must be delivered")
        XCTAssertEqual(streamer.contentLength, UInt(body.count))
        // A complete 200 must not arm the reconnect watchdog.
        XCTAssertEqual(FakeServerProtocol.streamRequestCount, 1,
                       "a fully-delivered response needs no reconnect")
    }

    func testRemoteContentTypeUpdatesTheFileHint() throws {
        // The URL says mp3, the server says flac: the response header wins.
        let streamer = try makeRemoteStreamer(responses: [
            Response(statusCode: 200, headers: ["Content-Type": "audio/x-m4a"], body: Data(repeating: 1, count: 1024)),
        ])

        streamer.open(url: testURL, at: 0)

        let updated = waitUntil { streamer.info.fileHint == .m4a }
        XCTAssertTrue(updated, "Content-Type must override the URL extension")
    }

    // MARK: - Error status codes

    func testRemote404ReportsNetworkStatusCode() throws {
        let streamer = try makeRemoteStreamer(responses: [
            Response(statusCode: 404, headers: [:], body: Data()),
        ])

        streamer.open(url: testURL, at: 0)

        let gotError = waitUntil(timeout: 3) {
            self.collector.events.contains(where: { event in
                if case let .error(error) = event, case let .networkStatusCode(code) = error { return code == 404 }
                return false
            })
        }
        XCTAssertTrue(gotError, "a 404 must surface as .networkStatusCode(404)")
    }

    // A server error on the *first* request cannot reconnect today: the
    // watchdog armed in `handle(response:)` is reset by the task-completion
    // handler before it can fire, so the stream reports a normal end. This pins
    // the current behaviour; the reconnect path itself is covered by
    // `testTruncatedStreamReconnectsAndResumes`.
    func testRemote500CurrentlyEndsTheStream() throws {
        let streamer = try makeRemoteStreamer(responses: [
            Response(statusCode: 500, headers: [:], body: Data()),
        ])

        streamer.open(url: testURL, at: 0)

        let ended = waitUntil(timeout: 3) {
            self.collector.events.contains(where: { if case .endEncountered = $0 { return true }; return false })
        }
        XCTAssertTrue(ended, "a bare 500 currently surfaces as end-of-stream")
        XCTAssertEqual(FakeServerProtocol.streamRequestCount, 1, "no reconnect is attempted")
    }

    // The reachable reconnect path: the server announces more content than it
    // sends, so the watchdog reopens at the read position and the resume request
    // delivers the rest.
    func testTruncatedStreamReconnectsAndResumes() throws {
        let firstHalf = Data(repeating: 0xAA, count: 1000)
        let secondHalf = Data(repeating: 0xBB, count: 1000)
        let streamer = try makeRemoteStreamer(responses: [
            Response(statusCode: 200, headers: ["Content-Length": "2000"], body: firstHalf),
            Response(statusCode: 206, headers: ["Content-Length": "1000"], body: secondHalf),
        ])

        streamer.open(url: testURL, at: 0)

        let delivered = waitUntil(timeout: 5) {
            let chunks = self.collector.events.compactMap { event -> [UInt8]? in
                if case let .bytes(bytes, _) = event { return bytes }
                return nil
            }
            return chunks.flatMap { $0 } == Array(firstHalf) + Array(secondHalf)
        }
        XCTAssertTrue(delivered, "the two halves must be delivered in order")
        XCTAssertEqual(streamer.contentLength, 2000)
        XCTAssertEqual(FakeServerProtocol.streamRequestCount, 2, "the stream must reconnect exactly once")
        XCTAssertEqual(FakeServerProtocol.servedRequests.last, "#2 range=bytes=1000-",
                       "the resume request must ask for the missing bytes")
    }

    // MARK: - Range / partial content

    func testRemote206ContentLengthIncludesThePosition() throws {
        let body = Data(repeating: 0x2B, count: 4096)
        let streamer = try makeRemoteStreamer(responses: [
            Response(statusCode: 206, headers: ["Content-Length": "\(body.count)"], body: body),
        ])

        let position: StreamProvider.Position = 1000
        streamer.open(url: testURL, at: position)

        let gotLength = waitUntil { streamer.contentLength == UInt(body.count) + position }
        XCTAssertTrue(gotLength, "a 206 Content-Length must add the start position")
        XCTAssertEqual(streamer.contentLength, UInt(body.count) + position,
                       "a 206 Content-Length is the remainder; the streamer adds the start position")
    }

    // MARK: - ICY

    func testIcyStreamIsDetectedByNameHeader() throws {
        let streamer = try makeRemoteStreamer(responses: [
            Response(statusCode: 200, headers: ["icy-name": "Radio APlay"], body: Data(repeating: 9, count: 2048)),
        ])

        streamer.open(url: testURL, at: 0)

        let gotTitle = waitUntil {
            self.collector.events.contains(where: { event in
                if case let .metadata(items) = event {
                    return items.contains { if case let .title(value) = $0 { return value == "Radio APlay" }; return false }
                }
                return false
            })
        }
        XCTAssertTrue(gotTitle, "icy-name must arrive as a .metadata title")
    }

    // MARK: - Caching

    func testCompleteResponseIsCachedToDisk() throws {
        // CacheInfo writes under config.cacheDirectory (the policy's extra
        // folders are only read back from, not written to), which
        // makeRemoteStreamer points at a scratch dir.
        let body = Data(repeating: 0x77, count: 8192)
        let streamer = try makeRemoteStreamer(responses: [
            Response(statusCode: 200, headers: ["Content-Length": "\(body.count)"], body: body),
        ])
        let cacheDir = try XCTUnwrap(self.cacheDir)

        streamer.open(url: testURL, at: 0)

        // The body is delivered first; the cache write then lands on a utility
        // queue. Wait for the final file — a failed length check would leave
        // only the .tmp behind.
        let gotCache = waitUntil(timeout: 5) { () -> Bool in
            let entries = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
            return entries.contains { $0.pathExtension.isEmpty && $0.lastPathComponent != ".tmp" }
        }
        XCTAssertTrue(gotCache, "a fully-read response must be cached")
        let entries = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        let cached = entries.first { $0.pathExtension.isEmpty && $0.lastPathComponent != ".tmp" }
        if let cached {
            XCTAssertEqual(try Data(contentsOf: cached), body, "the cached file must match the streamed body")
        }
    }
}
