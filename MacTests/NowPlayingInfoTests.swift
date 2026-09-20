//
//  NowPlayingInfoTests.swift
//
//  Covers the NowPlayingInfo art-work download path: the cover is fetched
//  through the configuration's session, cached, and surfaced on the info
//  dictionary. A URLProtocol intercepts the request so no network is touched.
//

import XCTest
import APlay
import AppKit
import MediaPlayer
@testable import APlay

final class NowPlayingInfoTests: XCTestCase {

    /// Serves a fixed PNG body for every request the info center makes.
    final class CoverProtocol: URLProtocol {
        static let body: Data = CoverProtocol.makePNG()

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.scheme == "https"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(Self.body.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// A 1x1 PNG — small enough to build in-code, real enough for `NSImage`.
        static func makePNG() -> Data {
            let image = NSImage(size: NSSize(width: 1, height: 1))
            image.lockFocus()
            NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return Data() }
            return rep.representation(using: .png, properties: [:]) ?? Data()
        }
    }

    private var config: APlay.Configuration?

    private func makeInfo() -> APlay.NowPlayingInfo {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverProtocol.self]

        // A private cache so a run's cover cannot be served by the default
        // shared cache and skip the request path.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("APlayCoverCache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 1024 * 1024,
                                          directory: cacheDir)

        let config = APlay.Configuration(logPolicy: .disable,
                                          sessionBuilder: { _ in
                                              URLSession(configuration: configuration)
                                          })
        self.config = config
        return APlay.NowPlayingInfo(config: config)
    }

    /// A cover URL is downloaded through the configured session and lands in the
    /// info dictionary.
    func testDownloadsAndReportsCoverArt() throws {
        let info = makeInfo()
        info.name = "Title"
        info.artist = "Artist"
        info.duration = 10

        info.image(with: "https://example.com/cover.png")

        let expectation = expectation(description: "cover lands in the info dictionary")
        for _ in 0..<100 {
            if info.artwork != nil {
                expectation.fulfill()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        wait(for: [expectation], timeout: 10)

        XCTAssertNotNil(info.artwork)
        let map = info.info
        XCTAssertEqual(map[MPMediaItemPropertyTitle] as? String, "Title")
        XCTAssertEqual(map[MPMediaItemPropertyArtist] as? String, "Artist")
        XCTAssertEqual(map[MPMediaItemPropertyPlaybackDuration] as? Int, 10)
    }

    /// A nil or unparseable URL is ignored rather than starting a request.
    func testIgnoresAnUnusableCoverURL() {
        let info = makeInfo()
        info.image(with: nil)
        info.image(with: "not a url")
        XCTAssertNil(info.artwork, "no request may have produced art work")
    }

    /// `remove()` clears the metadata and restores the default cover.
    func testRemoveClearsMetadata() {
        let info = makeInfo()
        info.name = "Title"
        info.playbackRate = 1
        info.playbackTime = 3

        info.remove()
        // `remove()` writes through a barrier on the info queue.
        info.info

        XCTAssertEqual(info.name, "")
        XCTAssertEqual(info.playbackRate, 0)
        XCTAssertEqual(info.playbackTime, 0)
    }

    /// `play`/`pause` record the transport state in the info dictionary.
    func testPlayAndPauseRecordTransportState() {
        let info = makeInfo()

        info.play(elapsedPlayback: 2)
        XCTAssertEqual(info.playbackRate, 1)
        XCTAssertEqual(info.playbackTime, 2)
        XCTAssertEqual(info.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)

        info.pause(elapsedPlayback: 5)
        XCTAssertEqual(info.playbackRate, 0)
        XCTAssertEqual(info.playbackTime, 5)
        XCTAssertEqual(info.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    }
}
