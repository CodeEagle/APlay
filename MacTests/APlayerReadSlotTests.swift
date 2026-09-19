//
//  APlayerReadSlotTests.swift
//
//  The render callback reads the active source through `RenderReadSlot` so a
//  preloaded track can take the output over without the audio unit stopping
//  (gapless playback). These pin the slot's contract: routing, the atomic swap
//  and that a replaced source is actually released — a slot that kept the old
//  closure alive would leak a composer per track switch, and one that freed it
//  while the render thread was still reading it would crash.
//

import XCTest
@testable import APlay

final class APlayerReadSlotTests: XCTestCase {

    private func makeBuffer(_ size: Int) -> UnsafeMutablePointer<UInt8> {
        return UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    }

    func testEmptySlotReadsNothing() {
        let slot = RenderReadSlot()
        let buffer = makeBuffer(4)
        defer { buffer.deallocate() }

        let (read, isFirstPacket) = slot.read(4, into: buffer)
        XCTAssertEqual(read, 0)
        XCTAssertFalse(isFirstPacket)
    }

    func testReadRoutesToTheInstalledClosure() {
        let slot = RenderReadSlot()
        var calls = 0
        slot.set { size, pointer in
            calls += 1
            memset(pointer, 0xAB, Int(size))
            return (size, true)
        }
        let buffer = makeBuffer(4)
        defer { buffer.deallocate() }

        let (read, isFirstPacket) = slot.read(4, into: buffer)
        XCTAssertEqual(read, 4)
        XCTAssertTrue(isFirstPacket)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(buffer.pointee, 0xAB)
    }

    func testClearStopsReading() {
        let slot = RenderReadSlot()
        slot.set { size, _ in (size, true) }
        slot.clear()

        let buffer = makeBuffer(4)
        defer { buffer.deallocate() }

        let (read, isFirstPacket) = slot.read(4, into: buffer)
        XCTAssertEqual(read, 0)
        XCTAssertFalse(isFirstPacket)
    }

    func testSwapSwitchesTheActiveSource() throws {
        let slot = RenderReadSlot()
        var oldReads = 0
        var newReads = 0
        slot.set { _, _ in oldReads += 1; return (1, false) }
        slot.set { _, _ in newReads += 1; return (2, true) }

        let buffer = makeBuffer(4)
        defer { buffer.deallocate() }

        let (read, isFirstPacket) = slot.read(4, into: buffer)
        XCTAssertEqual(read, 2, "the read must come from the source installed last")
        XCTAssertTrue(isFirstPacket)
        XCTAssertEqual(oldReads, 0, "a replaced source must never be read")
        XCTAssertEqual(newReads, 1)
    }

    func testSwapReleasesTheReplacedSource() throws {
        let slot = RenderReadSlot()
        weak var weakToken: NSObject? = nil

        // The only strong reference to the token is the closure installed in
        // the slot, so replacing that closure must free it: the swap hands
        // ownership of the source instead of leaking it.
        func install() {
            let token = NSObject()
            weakToken = token
            slot.set { _, _ in _ = token; return (0, false) }
        }
        install()
        XCTAssertNotNil(weakToken)

        slot.set { _, _ in (0, false) }
        XCTAssertNil(weakToken, "the replaced source must be released")
    }
}
