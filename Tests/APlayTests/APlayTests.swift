@_exported @testable import APlay
@_exported import AVFoundation
@_exported import Combine
@_exported import Dispatch
@_exported import Foundation
@_exported import XCTest

let playList: PlayListTests = .init()

final class APlayTests: XCTestCase {
    let player = APlay(configuration: APlay.Configuration())
    
    func testPlay() {
        let url = URL(fileURLWithPath: "/Users/lincolnlaw/Library/Caches/APlay/Tmp/LzIwMjAwMTIwMTAzODA2L2M5ZTc3MzJkNTU1Zjg2ZjFmODRmNzM0OGM2ODAwZjFkL2pkeXlhYWMvNTQwOC8wMzVhLzBlNWYvY2JiOGQwMGUxODQwYzIyN2E1MDA5NWViMTY2NjY1ODkubTRh")
        player.play(url)
    }
    
    static var allTests = [
        ("testAddPublisher", playList.testAddPublisher),
        ("testChangeList", playList.testChangeList),
        ("testAddSubscriber", playList.testAddSubscriber),
    ]
}

extension XCTestCase {
    func asyncTest(timeout: TimeInterval = 30, block: (XCTestExpectation) -> Void) {
        let expectation: XCTestExpectation = self.expectation(description: "❌:Timeout")
        block(expectation)
        waitForExpectations(timeout: timeout) { error in
            if let err = error {
                XCTFail("time out: \(err)")
            } else {
                XCTAssert(true, "success")
            }
        }
    }
}
