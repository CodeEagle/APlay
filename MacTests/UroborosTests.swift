//
//  UroborosTests.swift
//
//  Ring-buffer logic tests. Uroboros is the hand-rolled circular buffer behind
//  both the decoded-PCM ring (Composer) and the packet queue (decoder), so its
//  wraparound arithmetic is worth pinning down directly.
//

import XCTest
@testable import APlay

final class UroborosTests: XCTestCase {

    private func write(_ buffer: Uroboros, _ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { ptr in
            buffer.write(data: ptr.baseAddress!, amount: UInt32(bytes.count))
        }
    }

    private func read(_ buffer: Uroboros, amount: UInt32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(amount))
        let read = out.withUnsafeMutableBufferPointer { ptr in
            buffer.read(amount: amount, into: ptr.baseAddress!)
        }
        return Array(out.prefix(Int(read.0)))
    }

    func testEmptyReadReturnsNothing() {
        let buffer = Uroboros(capacity: 16)
        XCTAssertEqual(buffer.availableData, 0)
        XCTAssertEqual(buffer.availableSpace, 16)
        let result = read(buffer, amount: 4)
        XCTAssertTrue(result.isEmpty)
    }

    func testWriteThenReadRoundtrip() {
        let buffer = Uroboros(capacity: 16)
        let payload: [UInt8] = Array(0 ... 7)
        write(buffer, payload)

        XCTAssertEqual(buffer.availableData, 8)
        XCTAssertEqual(buffer.availableSpace, 8)

        XCTAssertEqual(read(buffer, amount: 8), payload)
        XCTAssertEqual(buffer.availableData, 0)
        XCTAssertEqual(buffer.availableSpace, 16)
    }

    func testPartialReadKeepsRemainingData() {
        let buffer = Uroboros(capacity: 16)
        write(buffer, [1, 2, 3, 4, 5])

        XCTAssertEqual(read(buffer, amount: 3), [1, 2, 3])
        XCTAssertEqual(buffer.availableData, 2)
        XCTAssertEqual(read(buffer, amount: 3), [4, 5])
    }

    /// Writing past the tail must wrap around the beginning without losing or
    /// duplicating bytes — this is the case that plain `memcpy` gets wrong.
    func testWraparoundPreservesByteOrder() {
        let buffer = Uroboros(capacity: 8)
        write(buffer, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(read(buffer, amount: 6), [0, 1, 2, 3, 4, 5])

        // start == end == 6 now; writing 8 bytes spans the seam at index 8.
        let payload: [UInt8] = Array(10 ... 17)
        write(buffer, payload)
        XCTAssertEqual(read(buffer, amount: 8), payload)
    }

    /// The first read after a fresh fill reports `isFirstPacket == true`
    /// exactly once. Composer uses that flag to decide when to start the
    /// output unit, so a sticky flag would stall playback.
    func testFirstReadIsFlaggedAsFirstPacket() {
        let buffer = Uroboros(capacity: 16)
        write(buffer, [1, 2, 3])

        var out = [UInt8](repeating: 0, count: 2)
        let first = out.withUnsafeMutableBufferPointer { buffer.read(amount: 2, into: $0.baseAddress!) }
        XCTAssertEqual(first.0, 2)
        XCTAssertTrue(first.1, "first read should report the first-packet flag")

        write(buffer, [9, 9])
        let second = out.withUnsafeMutableBufferPointer { buffer.read(amount: 2, into: $0.baseAddress!) }
        XCTAssertEqual(second.0, 2)
        XCTAssertFalse(second.1, "subsequent reads must clear the first-packet flag")
    }

    func testClearEmptiesBuffer() {
        let buffer = Uroboros(capacity: 16)
        write(buffer, [1, 2, 3])
        XCTAssertEqual(buffer.availableData, 3)

        buffer.clear()
        XCTAssertEqual(buffer.availableData, 0)
        XCTAssertEqual(buffer.availableSpace, 16)
    }

    /// `read` with `commitRead: false` peeks without advancing — the decoder
    /// uses it to probe for a full packet before consuming it.
    func testReadWithoutCommitDoesNotAdvance() {
        let buffer = Uroboros(capacity: 16)
        write(buffer, [1, 2, 3])

        var out = [UInt8](repeating: 0, count: 3)
        let peek = out.withUnsafeMutableBufferPointer {
            buffer.read(amount: 3, into: $0.baseAddress!, commitRead: false)
        }
        XCTAssertEqual(peek.0, 3)
        XCTAssertEqual(Array(out), [1, 2, 3])
        XCTAssertEqual(buffer.availableData, 3, "peek must not consume")
    }
}
