@_exported @testable import APlay
@_exported import AVFoundation
@_exported import Combine
@_exported import Dispatch
@_exported import Foundation
@_exported import XCTest

let playList: PlayListTests = .init()

final class APlayTests: XCTestCase {
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
