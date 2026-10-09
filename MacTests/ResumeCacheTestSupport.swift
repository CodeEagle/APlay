//
//  ResumeCacheTestSupport.swift
//
//  Shared harness for the resume-cache test files: a deterministic HTTP
//  server that slices a fixture by Range, plus a per-test scratch cache
//  directory and streamer lifetime. Every resume test file builds on this.
//

import XCTest
@testable import APlay

/// A URLProtocol that serves a fixture as a deterministic, controllable HTTP
/// server: it answers Range requests with slices of the body and can be
/// configured per request to truncate, delay, fail, ignore ranges, or omit
/// headers — the conditions real networks and real servers present.
final class RangeServerProtocol: URLProtocol {
    static let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"

    /// Which validators the server sends, so a test can exercise the
    /// `If-Range` path with an ETag, a Last-Modified date, or neither.
    enum Validators {
        case both
        case etagOnly
        case lastModifiedOnly
        case none
    }

    /// What the server should send back for the next request it sees.
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let bodyDelay: TimeInterval
        let error: Error?
        let failAfterBytes: Int?
    }

    private static let lock = NSLock()
    private static var body = Data()
    private static var etag = "\"v1\""
    private static var validators: Validators = .both
    private static var truncateNext: Int?
    private static var delayNext: TimeInterval = 0
    private static var ignoreRangeNext = false
    private static var omitContentLengthNext = false
    private static var failNextWithError: Error?
    private static var failAfterBytesNext: Int?
    /// Gates the mid-transfer dropout: the prefix is delivered and the protocol
    /// parks until the test confirms the streamer received it, because
    /// Foundation only hands the body to the delegate after the response is
    /// allowed — failing immediately after `didLoad` loses the data entirely.
    private static var failGate: DispatchSemaphore?
    private static var statusOverrideNext: Int?
    private static var requests: [URLRequest] = []

    /// Configures how the next stream request is served. The per-request
    /// switches consume themselves, so a test describes one exchange at a time.
    static func configure(body: Data,
                          etag: String = "\"v1\"",
                          validators: Validators = .both,
                          truncateNext: Int? = nil,
                          delayNext: TimeInterval = 0,
                          ignoreRangeNext: Bool = false,
                          omitContentLengthNext: Bool = false,
                          failNextWithError: Error? = nil,
                          failAfterBytesNext: Int? = nil,
                          statusOverrideNext: Int? = nil,
                          clearRequests: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        self.body = body
        self.etag = etag
        self.validators = validators
        self.truncateNext = truncateNext
        self.delayNext = delayNext
        self.ignoreRangeNext = ignoreRangeNext
        self.omitContentLengthNext = omitContentLengthNext
        self.failNextWithError = failNextWithError
        self.failAfterBytesNext = failAfterBytesNext
        self.failGate = failAfterBytesNext == nil ? nil : DispatchSemaphore(value: 0)
        self.statusOverrideNext = statusOverrideNext
        if clearRequests { requests = [] }
    }

    static var streamRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Releases a parked mid-transfer dropout. Call it only after the test has
    /// confirmed the prefix reached the streamer (for example the collector
    /// saw its bytes), so the failure arrives after — not instead of — the data.
    static func releasePendingFailure() {
        lock.lock()
        let gate = failGate
        lock.unlock()
        gate?.signal()
    }

    private static func response(for request: URLRequest) -> Response {
        lock.lock()
        defer { lock.unlock() }
        let range = request.value(forHTTPHeaderField: "Range")
        if range == "bytes=-128" {
            // Serve the ID3v1 probe without consuming the stream's state.
            return Response(statusCode: 206,
                            headers: ["Content-Range": "bytes \(body.count - 128)-\(body.count - 1)/\(body.count)",
                                      "Content-Length": "128"],
                            body: Data(body.suffix(128)), bodyDelay: 0, error: nil, failAfterBytes: nil)
        }
        requests.append(request)
        let limit = truncateNext
        let delay = delayNext
        let ignoreRange = ignoreRangeNext
        let omitLength = omitContentLengthNext
        let failAfter = failAfterBytesNext
        truncateNext = nil
        delayNext = 0
        ignoreRangeNext = false
        omitContentLengthNext = false
        failAfterBytesNext = nil

        if let failure = failNextWithError {
            failNextWithError = nil
            return Response(statusCode: 0, headers: [:], body: Data(),
                            bodyDelay: delay, error: failure, failAfterBytes: nil)
        }
        if let status = statusOverrideNext {
            statusOverrideNext = nil
            return Response(statusCode: status, headers: [:], body: Data(),
                            bodyDelay: delay, error: nil, failAfterBytes: nil)
        }

        var headers = ["Content-Type": "audio/mpeg", "Accept-Ranges": "bytes"]
        switch validators {
        case .both, .etagOnly: headers["ETag"] = etag
        default: break
        }
        switch validators {
        case .both, .lastModifiedOnly: headers["Last-Modified"] = lastModified
        default: break
        }

        var start = 0
        var end = body.count - 1
        var status = 200
        let validator = request.value(forHTTPHeaderField: "If-Range")
        if let range, ignoreRange == false,
           validator == nil || validator == etag || validator == lastModified {
            let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            guard range.hasPrefix("bytes="), bounds.count == 2,
                  let lower = Int(bounds[0]), lower >= 0, lower < body.count else {
                return Response(statusCode: 416,
                                headers: ["Content-Range": "bytes */\(body.count)", "Content-Length": "0"],
                                body: Data(), bodyDelay: 0, error: nil, failAfterBytes: nil)
            }
            start = lower
            if let upper = Int(bounds[1]) { end = min(upper, end) }
            guard end >= start else {
                return Response(statusCode: 416, headers: ["Content-Length": "0"], body: Data(), bodyDelay: 0, error: nil, failAfterBytes: nil)
            }
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(end)/\(body.count)"
        }
        let slice = body.subdata(in: start..<(end + 1))
        if omitLength == false { headers["Content-Length"] = "\(slice.count)" }
        return Response(statusCode: status, headers: headers,
                        body: Data(slice.prefix(limit ?? slice.count)),
                        bodyDelay: delay, error: nil, failAfterBytes: failAfter)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = Self.response(for: request)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.statusCode,
                                   httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        // A bounded delay lets a test observe the container before the bytes
        // land, and crosses the sidecar writer's 0.5-second flush throttle.
        if response.bodyDelay > 0 { Thread.sleep(forTimeInterval: response.bodyDelay) }
        if !response.body.isEmpty {
            if let cutoff = response.failAfterBytes, cutoff < response.body.count {
                // A real dropout mid-transfer: the client keeps the bytes that
                // arrived, then the connection fails. Park behind the gate so
                // the failure is only injected after the test has confirmed the
                // prefix was delivered — Foundation will not deliver the body
                // once the protocol fails, so an immediate error loses it.
                client?.urlProtocol(self, didLoad: response.body.prefix(cutoff))
                Self.lock.lock()
                let gate = Self.failGate
                Self.lock.unlock()
                _ = gate?.wait(timeout: .now() + 10)
                client?.urlProtocol(self, didFailWithError: NSError(
                    domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                    userInfo: [NSLocalizedDescriptionKey: "simulated mid-transfer dropout"]))
                return
            }
            client?.urlProtocol(self, didLoad: response.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Per-test scratch cache directory plus the streamers a test opened, so a
/// partial container one test leaves behind cannot satisfy another's open.
final class ResumeCacheTestHarness {
    let testURL = URL(string: "https://resume.aplay.invalid/github-silence.mp3")!
    private(set) var fixture = Data()
    private(set) var cacheDirectory: URL!
    /// Configurations must outlive `destroy()`'s queued work (Streamer holds an
    /// unowned reference).
    private var configurations: [APlay.Configuration] = []
    private var streamers: [StreamProviderCompatible] = []

    init() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "github-silence", withExtension: "mp3",
                                                  subdirectory: "Fixtures"))
        fixture = try Data(contentsOf: url)
        XCTAssertEqual(fixture.count, 37_206)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("APlayResumeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        RangeServerProtocol.configure(body: fixture, clearRequests: true)
    }

    /// Tears down every streamer and deletes the scratch directory.
    func destroy() {
        streamers.forEach { $0.destroy() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        streamers.removeAll()
        configurations.removeAll()
        if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory) }
        self.cacheDirectory = nil
    }

    /// Builds a Streamer whose session the fake server intercepts.
    @discardableResult
    func makeStreamer() -> (StreamProviderCompatible, StreamerLocalTests.Collector) {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [RangeServerProtocol.self]
        let config = APlay.Configuration(logPolicy: .disable, cachePolicy: .enable([]),
                                         cacheDirectory: cacheDirectory.path,
                                         maxRemoteStreamOpenRetry: 2,
                                         sessionBuilder: { _ in URLSession(configuration: session) })
        let streamer = config.streamerBuilder(config)
        let collector = StreamerLocalTests.Collector()
        streamer.outputPipeline.delegate(to: collector) { collector, event in collector.append(event) }
        configurations.append(config)
        streamers.append(streamer)
        return (streamer, collector)
    }

    /// The plain cache path a finished container is promoted to.
    var finalURL: URL {
        let naming = configurations.first?.cacheNaming
            ?? APlay.Configuration.CacheFileNamingPolicy.defaultPolicy
        return cacheDirectory.appendingPathComponent(naming.name(for: testURL))
    }

    var partURL: URL { finalURL.appendingPathExtension("part") }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Every byte the streamer handed the decoder, in order.
    func audio(_ collector: StreamerLocalTests.Collector) -> Data {
        Data(collector.events.flatMap { event -> [UInt8] in
            if case let .bytes(bytes, _) = event { return bytes }
            return []
        })
    }

    /// Spins the run loop until `condition` holds.
    func waitUntil(timeout: TimeInterval = 5, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// A real interrupted HTTP transfer: the opening bytes land and are
    /// persisted, then the connection ends. Never fabricates the bitmap.
    /// `validators` controls which identity headers the first download saw, so
    /// a test can seed the table with a Last-Modified-only or validator-less
    /// server — the cached validators, not a later configure(), decide the
    /// `If-Range` the reopen sends.
    func interruptedDownload(validators: RangeServerProtocol.Validators = .both) throws {
        RangeServerProtocol.configure(body: fixture, validators: validators,
                                      truncateNext: 12_288, delayNext: 0.65)
        let (streamer, collector) = makeStreamer()
        streamer.open(url: testURL, at: 0)
        XCTAssertTrue(waitUntil { self.audio(collector).count >= 8192 })
        streamer.destroy()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(audio(collector), Data(fixture.prefix(8192)))
        let meta = try XCTUnwrap(ResumeCacheMeta.load(nextTo: partURL))
        XCTAssertEqual(meta.downloadedBytes, 8192)
        switch validators {
        case .both, .etagOnly:
            XCTAssertEqual(meta.etag, "\"v1\"")
        case .lastModifiedOnly, .none:
            XCTAssertNil(meta.etag)
        }
        XCTAssertTrue(meta.bitmap.contains(offset: 8191))
        XCTAssertFalse(meta.bitmap.contains(offset: 8192))
        let cache = try XCTUnwrap(ResumeCache.open(name: finalURL.lastPathComponent,
                                                   cacheDirectory: cacheDirectory.path,
                                                   expectedOriginURL: testURL))
        XCTAssertEqual(cache.firstMissingOffset(), 8192)
        cache.close()
        XCTAssertEqual(RangeServerProtocol.streamRequests.count, 1)
    }
}
