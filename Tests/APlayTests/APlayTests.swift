@_exported import XCTest
@_exported @testable import APlay
@_exported import Foundation
@_exported import Combine
@_exported import AVFoundation
@_exported import Dispatch

let playList: PlayListTests = .init()

final class APlayTests: XCTestCase {
    static var allTests = [
        ("testAddPublisher", playList.testAddPublisher),
        ("testChangeList", playList.testChangeList),
        ("testAddSubscriber", playList.testAddSubscriber)
    ]
}

extension XCTestCase {
    func asyncTest(timeout: TimeInterval = 30, block: (XCTestExpectation) -> ()) {
        let expectation: XCTestExpectation = self.expectation(description: "❌:Timeout")
        block(expectation)
        self.waitForExpectations(timeout: timeout) { (error) in
            if let err = error {
                XCTFail("time out: \(err)")
            } else {
                XCTAssert(true, "success")
            }
        }
    }
}
