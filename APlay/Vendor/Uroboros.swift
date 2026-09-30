//
//  Uroboros.swift
//  APlayer
//
//  Created by lincoln on 2018/4/25.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation

/// A Circle Buffer Implementation for APlay
public final class Uroboros {
    /// Basic type of buffer, UInt8
    public typealias Byte = UInt8

    private lazy var _start: UInt32 = 0
    private var start: UInt32 {
        get { return _propertiesQueue.sync { _start } }
        set { _propertiesQueue.sync { _start = newValue } }
    }

    private lazy var _end: UInt32 = 0
    private var end: UInt32 {
        get { return _propertiesQueue.sync { _end } }
        set { _propertiesQueue.sync { _end = newValue } }
    }

    private var _availableData: UInt32 = 0
    public var availableData: UInt32 {
        get { return _propertiesQueue.sync { _availableData } }
        set { _propertiesQueue.sync { _availableData = newValue } }
    }

    private var _availableSpace: UInt32 = 0
    public var availableSpace: UInt32 {
        get { return _propertiesQueue.sync { _availableSpace } }
        set { _propertiesQueue.sync { _availableSpace = newValue } }
    }

    private var _requiredSpace: UInt32 = 0
    /// required space for next write action
    private var requiredSpace: UInt32 {
        get { return _propertiesQueue.sync { _requiredSpace } }
        set { _propertiesQueue.sync { _requiredSpace = newValue } }
    }

    /// capacity of uroboros
    public var capacity: UInt32 { return UInt32(_body.capacity) }
    /// The base address of the buffer.
    private var baseAddress: UnsafeMutablePointer<Byte>? { return _body.baseAddress }
    /// The end address of the buffer
    private var endAddress: UnsafeMutablePointer<Byte>? { return baseAddress?.advanced(by: Int(end)) }
    /// The start address of the buffer
    public var startAddress: UnsafeMutablePointer<Byte>? { return baseAddress?.advanced(by: Int(start)) }
    /// Queue for write action
    private let _writeQueue = DispatchQueue(label: "Uroboros.Write")
    private let _readQueue = DispatchQueue(label: "Uroboros.Read")
    /// Queue for properties I/O
    private let _propertiesQueue = DispatchQueue(label: "Uroboros.Properties")
    /// Semaphore for stop/continue write action
    private lazy var _semaphore = DispatchSemaphore(value: 0)
    /// Set by `close()`: once closed, a writer parked in `checkSpace` must stop
    /// waiting instead of parking forever on a buffer nothing will drain.
    private let closed = RenderAtomic()
    /// Store content
    private var _body: UroborosBody

    private var _name: String

    private var _deliveryingFirstPacket = true

    #if DEBUG
        deinit {
            debug_log("\(self)[\(_name)] \(#function)")
        }
    #endif

    /// Init uroboros
    ///
    /// - Parameter count: size you want for buffer
    public init(capacity count: UInt32, name: String = #file) {
        _name = name.components(separatedBy: "/").last ?? name
        _body = UroborosBody(capacity: count)
        availableSpace = count
    }

    /// Store data into uroboros
    ///
    /// - Parameters:
    ///   - data: data being stored
    ///   - amount: size of bytes
    public func write(data: UnsafeRawPointer, amount: UInt32) {
        guard amount > 0 else { return }
        _writeQueue.sync {
            func checkSpace() {
                // A loop, not a single guard: the semaphore wake (real or the
                // 50 ms timeout below) must re-test the space, because a wake can
                // arrive when the reader had already released enough room — or
                // when it never will (a torn-down decoder stops draining).
                //
                // The wait is bounded: `commitRead`/`clear()` signal exactly once
                // per satisfied `requiredSpace`, and a writer that was inside
                // memcpy (or an AudioFileStream packet callback) at that moment
                // can reach the wait after the signal has been spent. With an
                // unbounded wait the network parse thread parks forever, and its
                // live stack frame keeps the whole Composer (streamer, decoder,
                // 4 MiB ring buffers and the pending network Data) reachable —
                // the exact leak seen on rapid track switching.
                while amount > availableSpace, closed.load() == 0 {
                    requiredSpace = amount
                    _semaphore.wait(timeout: .now() + .milliseconds(50))
                }
            }
            checkSpace()
            guard closed.load() == 0 else { return }
            let intCount = Int(amount)
            let targetLocation = end + amount
            if targetLocation > capacity {
                let secondPart = Int(targetLocation - capacity)
                let firstPart = intCount - secondPart
                memcpy(endAddress, data, firstPart)
                memcpy(baseAddress, data.advanced(by: firstPart), secondPart)
            } else {
                memcpy(endAddress, data, intCount)
            }
            commitWrite(count: amount)
        }
    }

    /// Get data form uroboros
    ///
    /// - Parameters:
    ///   - amount: The number of bytes to retreive
    ///   - data: The bytes to retreive buffer
    ///   - commitRead: Can read data without commit
    /// - Returns: size for this time read
    @discardableResult public func readInQueue(amount: UInt32, into data: UnsafeMutableRawPointer, commitRead: Bool = true) -> (UInt32, Bool) {
        return _readQueue.sync {
            return self.read(amount: amount, into: data, commitRead: commitRead)
        }
    }
    
    /// Get data form uroboros
    ///
    /// - Parameters:
    ///   - amount: The number of bytes to retreive
    ///   - data: The bytes to retreive buffer
    ///   - commitRead: Can read data without commit
    /// - Returns: size for this time read
    @discardableResult public func read(amount: UInt32, into data: UnsafeMutableRawPointer, commitRead: Bool = true) -> (UInt32, Bool) {
        if amount == 0 || availableData == 0 { return (0, false) }
        let read = _propertiesQueue.sync {
            return _availableData < amount ? _availableData : amount
        }
        let intCount = Int(read)
        let targetLocation = Int(_start) + intCount
        if targetLocation > capacity {
            let secondPartLength = targetLocation - Int(capacity)
            let firstPartLength = intCount - secondPartLength
            memcpy(data, startAddress, firstPartLength)
            memcpy(data.advanced(by: firstPartLength), baseAddress, secondPartLength)
        } else {
            memcpy(data, startAddress, intCount)
        }
        if commitRead { self.commitRead(count: read) }
        let value = _deliveryingFirstPacket
        _deliveryingFirstPacket = false
        return (read, value)
    }

    // MARK: - Private Functions

    /// Commit a read into the buffer, moving the `start` position
    public func commitRead(count: UInt32) {
        _propertiesQueue.sync {
            _start = (_start + count) % capacity
            if _availableData >= count {
                _availableData -= count
            } else {
                _availableData = 0
            }
            _availableSpace += count
            guard _availableSpace >= _requiredSpace, _requiredSpace > 0 else { return }
            _requiredSpace = 0
            _semaphore.signal()
        }
    }

    /// Commit a write into the buffer, moving the `end` position
    private func commitWrite(count: UInt32) {
        _propertiesQueue.sync {
            _end = (_end + count) % capacity
            _availableData += count
            _availableSpace -= count
        }
    }

    /// Reset to empty
    public func clear() {
        let data = availableData
        guard data > 0 else { return }
        commitRead(count: data)
    }

    /// Closes the buffer to further writes and releases any writer parked in
    /// `checkSpace`.
    ///
    /// `clear()` alone is not enough for teardown: when the buffer happens to
    /// be empty at that moment its `guard data > 0` early-returns without
    /// signalling, so a writer that already set `requiredSpace` waits forever.
    /// `close` signals unconditionally and marks the buffer closed so the
    /// writer's bounded re-check loop stops spinning.
    public func close() {
        _ = closed.exchange(1)
        requiredSpace = 0
        _semaphore.signal()
    }
}

// MARK: - Uroboros Types

extension Uroboros {
    /// Storage for `Uroboros`
    private final class UroborosBody {
        let capacity: UInt32

        /// Pointer to our allocated memory
        private(set) var storagePointer: UnsafeMutableRawPointer!
        
        /// Base address of the storage, as mapped to UInt8
        private(set) var baseAddress: UnsafeMutablePointer<Byte>?

        init(capacity count: UInt32) {
            capacity = count
            let intCount = Int(count)
            let alignment = MemoryLayout<Byte>.alignment
            storagePointer = UnsafeMutableRawPointer.allocate(byteCount: intCount, alignment: alignment)
            baseAddress = storagePointer.bindMemory(to: Byte.self, capacity: intCount)
            assert(baseAddress != nil, "UroborosBody cant not be nil")
        }

        deinit {
            if let base = baseAddress {
                base.deinitialize(count: Int(capacity))
            }
            storagePointer.deallocate()
            _fixLifetime(self)
        }
    }
}
