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
    /// Queue for properties I/O
    private let _propertiesQueue = DispatchQueue(label: "Uroboros.Properties")
    /// Semaphore for stop/continue write action
    private lazy var _semaphore = DispatchSemaphore(value: 0)
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
                guard amount > availableSpace else { return }
                requiredSpace = amount
                _semaphore.wait()
            }
            checkSpace()
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
}

// MARK: - Uroboros Types

extension Uroboros {
    /// Storage for `Uroboros`
    private final class UroborosBody {
        let capacity: UInt32

        private(set) var baseAddress: UnsafeMutablePointer<Byte>?

        init(capacity count: UInt32) {
            capacity = count
            baseAddress = malloc(Int(count))?.assumingMemoryBound(to: Byte.self)
            assert(baseAddress != nil, "UroborosBody cant not be nil")
        }

        deinit {
            free(baseAddress)
            baseAddress = nil
        }
    }
}
