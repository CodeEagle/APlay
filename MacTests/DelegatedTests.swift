//
//  DelegatedTests.swift
//  APlayTests
//
//  `Delegated` is the event-dispatch spine of the framework (pipelines, decoder
//  and streamer callbacks, the now-playing target). Its public API beyond the
//  weak `delegate(to:with:)` path was untested; this pins every entry point,
//  including the strong-capture and Void-specialised overloads.
//

import XCTest
@testable import APlay

final class DelegatedTests: XCTestCase {

    // MARK: - Weak delegation

    func testWeakDelegateDeliversTheTargetOutput() {
        let delegated = Delegated<Int, Int>()
        let doubler = Doubler()
        delegated.delegate(to: doubler) { doubler, input in doubler.apply(input) }
        XCTAssertEqual(delegated.call(4), 8)
    }

    func testWeakDelegateDeliversNilOnceTheTargetIsReleased() {
        var doubler: Doubler? = Doubler()
        let delegated = Delegated<Int, Int>()
        delegated.delegate(to: doubler!) { doubler, input in doubler.apply(input) }
        doubler = nil
        // The weak capture must not resurrect the target — nil, not a crash.
        XCTAssertNil(delegated.call(4))
    }

    // MARK: - Strong delegation

    func testStronglyDelegateKeepsTheTargetAlive() {
        let delegated = Delegated<Int, Int>()
        do {
            let doubler = Doubler()
            delegated.stronglyDelegate(to: doubler) { doubler, input in doubler.apply(input) }
        }
        // The local is out of scope; the strong capture is the only remaining
        // reference, and delivery must still work.
        XCTAssertEqual(delegated.call(4), 8)
    }

    func testStronglyDelegateIsRetainedUntilReplaced() {
        let delegated = Delegated<Int, Int>()
        delegated.stronglyDelegate(to: Doubler()) { doubler, input in doubler.apply(input) }
        XCTAssertEqual(delegated.call(4), 8)
        // Replacing the callback releases the previously captured target.
        delegated.manuallyDelegate { input in input * 3 }
        XCTAssertEqual(delegated.call(4), 12)
    }

    // MARK: - Manual and removed delegation

    func testManuallyDelegateTakesARawClosure() {
        let delegated = Delegated<Int, Int>()
        delegated.manuallyDelegate { input in input * 3 }
        XCTAssertEqual(delegated.call(3), 9)
    }

    func testCallWithoutADelegateReturnsNil() {
        let delegated = Delegated<Int, Int>()
        XCTAssertNil(delegated.call(1))
    }

    func testRemoveDelegateClearsTheCallback() {
        let delegated = Delegated<Int, Int>()
        delegated.manuallyDelegate { input in input }
        XCTAssertEqual(delegated.call(1), 1)
        delegated.removeDelegate()
        XCTAssertNil(delegated.call(1))
    }

    func testIsDelegateSetTracksTheCallback() {
        let delegated = Delegated<Int, Int>()
        XCTAssertFalse(delegated.isDelegateSet)
        delegated.manuallyDelegate { input in input }
        XCTAssertTrue(delegated.isDelegateSet)
        delegated.removeDelegate()
        XCTAssertFalse(delegated.isDelegateSet)
    }

    // MARK: - Enabling and disabling

    func testToggleDisableStopsDelivery() {
        let delegated = Delegated<Int, Int>()
        delegated.manuallyDelegate { input in input }
        XCTAssertEqual(delegated.call(1), 1)
        delegated.toggle(enable: false)
        XCTAssertNil(delegated.call(1))
        delegated.toggle(enable: true)
        XCTAssertEqual(delegated.call(1), 1)
    }

    // MARK: - Void-input specialisations

    func testVoidInputWeakDelegateDelivers() {
        let delegated = Delegated<Void, Int>()
        let doubler = Doubler()
        delegated.delegate(to: doubler) { doubler in doubler.apply(21) }
        XCTAssertEqual(delegated.call(), 42)
    }

    func testVoidInputStronglyDelegateDelivers() {
        let delegated = Delegated<Void, Int>()
        delegated.stronglyDelegate(to: Doubler()) { doubler in doubler.apply(21) }
        XCTAssertEqual(delegated.call(), 42)
    }

    // MARK: - Void-output specialisations

    func testVoidOutputCallIsSafeWithoutADelegate() {
        let delegated = Delegated<Int, Void>()
        // No delegate set: the Void specialisation must swallow the call.
        delegated.call(1)
    }

    func testVoidOutputDeliversToTheTarget() {
        let target = Counter()
        let delegated = Delegated<Int, Void>()
        delegated.delegate(to: target) { target, input in target.count = input }
        delegated.call(7)
        XCTAssertEqual(target.count, 7)
    }

    func testFullyVoidCallDelivers() {
        let target = Counter()
        let delegated = Delegated<Void, Void>()
        delegated.delegate(to: target) { target in target.count = 9 }
        delegated.call()
        XCTAssertEqual(target.count, 9)
    }

    func testFullyVoidCallDeliversNothingWhenDisabled() {
        let target = Counter()
        let delegated = Delegated<Void, Void>()
        delegated.delegate(to: target) { target in target.count = 9 }
        delegated.toggle(enable: false)
        delegated.call()
        XCTAssertEqual(target.count, 0)
    }
}

// MARK: - Fixtures

private final class Doubler {
    func apply(_ value: Int) -> Int { value * 2 }
}

private final class Counter {
    var count = 0
}
