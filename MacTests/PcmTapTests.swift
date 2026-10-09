//
//  PcmTapTests.swift
//  APlay
//
//  Regression for the realtime PCM observer (`APlay.pcmTap`): a visualizer that
//  needs band levels must actually receive the interleaved samples entering the
//  render graph, with a correct format and frame count.
//
//  The xctest process cannot start an output audio unit on macOS (-10867), so
//  this drives the render graph directly through `pullRenderQuantum`, which
//  pulls the same manual-rendering block the output unit's render callback
//  uses. End-to-end playback through a real audio unit is covered by the
//  `APlayMacPlayback` executable.
//

import AVFoundation
import XCTest
@testable import APlay

#if DEBUG // pullRenderQuantum is intentionally a DEBUG-only render seam.
final class PcmTapTests: XCTestCase {
    func testPcmTapDeliversSamples() throws {
        let player = APlayer(config: APlay.Configuration())
        final class Counter: @unchecked Sendable {
            var frameCount: UInt32 = 0
            var sampleRate: Double = 0
            var nonZero = false
        }
        let counter = Counter()

        player.pcmTap = { (bufferList: UnsafePointer<AudioBufferList>, frameCount: UInt32, format: AVAudioFormat) in
            counter.frameCount = max(counter.frameCount, frameCount)
            counter.sampleRate = format.sampleRate
            if !counter.nonZero,
               let data = bufferList.pointee.mBuffers.mData {
                let count = Int(bufferList.pointee.mBuffers.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<min(count, 512) where samples[i] != 0 {
                    counter.nonZero = true
                    break
                }
            }
        }
        XCTAssertNotNil(player.pcmTap)

        // Render source: a few frames of 44.1kHz stereo sine at a modest level,
        // delivered as interleaved Int16 — the canonical format the player is
        // set up with below.
        let frameCapacity = Int(Player.maxFramesPerSlice)
        var samples = [Int16](repeating: 0, count: frameCapacity * 2)
        let freq: Float = 440
        let sampleRate: Float = 44100
        for i in 0..<frameCapacity {
            let v = sinf(2 * .pi * freq * Float(i) / sampleRate) * 0.3
            samples[i * 2] = Int16(v * Float(Int16.max))
            samples[i * 2 + 1] = samples[i * 2]
        }
        samples.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<Int16>) in
            player.readClosure = { (size: UInt32, pointer: UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) in
                let byteCount = min(Int(size), buffer.count * MemoryLayout<Int16>.size)
                memcpy(pointer, buffer.baseAddress, byteCount)
                return (UInt32(byteCount), false)
            }
        }

        player.setup(Player.canonical)

        // Pull one quantum through the render graph the way the output unit
        // would. The tap fires on the input side of that pull.
        let frameCount: UInt32 = 1024
        let byteSize = frameCount * Player.canonical.mBytesPerFrame
        var bufferList = AudioBufferList(mNumberBuffers: 1,
                                         mBuffers: AudioBuffer(mNumberChannels: Player.canonical.mChannelsPerFrame,
                                                               mDataByteSize: byteSize,
                                                               mData: malloc(Int(byteSize))))
        defer { free(bufferList.mBuffers.mData) }

        let status = player.pullRenderQuantum(frameCount, into: &bufferList)
        XCTAssertEqual(status, noErr, "the manual rendering block reported an error")

        XCTAssertGreaterThan(counter.frameCount, 0, "pcmTap was never called with samples")
        XCTAssertEqual(counter.sampleRate, 44100, accuracy: 1)
        XCTAssertTrue(counter.nonZero, "pcmTap delivered silence; the render path is not wired to the tap")
    }
}

extension PcmTapTests {

    /// Long-running tap regression: pulling many render quanta used to pile
    /// memory up in apps driving a visualizer (the macOS client reported a
    /// ~1 GB RSS after a few minutes of playback). The tap callback itself
    /// must stay allocation-free on the render thread, and every object it
    /// touches has to be preallocated.
    func testPcmTapOverManyQuantaDoesNotGrowMemory() throws {
        let player = APlayer(config: APlay.Configuration())
        defer { player.destroy() }

        var quanta = 0
        player.pcmTap = { _, frameCount, _ in
            quanta = max(quanta, Int(frameCount))
        }

        let frameCapacity = Int(Player.maxFramesPerSlice)
        var samples = [Int16](repeating: 0, count: frameCapacity * 2)
        let freq: Float = 440
        let sampleRate: Float = 44100
        for i in 0..<frameCapacity {
            let v = sinf(2 * .pi * freq * Float(i) / sampleRate) * 0.3
            samples[i * 2] = Int16(v * Float(Int16.max))
            samples[i * 2 + 1] = samples[i * 2]
        }
        samples.withUnsafeBufferPointer { buffer in
            player.readClosure = { (size: UInt32, pointer: UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) in
                let byteCount = min(Int(size), buffer.count * MemoryLayout<Int16>.size)
                memcpy(pointer, buffer.baseAddress, byteCount)
                return (UInt32(byteCount), false)
            }
        }

        player.setup(Player.canonical)

        let frameCount: UInt32 = 1024
        let byteSize = frameCount * Player.canonical.mBytesPerFrame
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: Player.canonical.mChannelsPerFrame,
                mDataByteSize: byteSize,
                mData: malloc(Int(byteSize))))
        defer { free(bufferList.mBuffers.mData) }

        func resident() -> Int64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard kerr == KERN_SUCCESS else { return 0 }
            return Int64(info.phys_footprint)
        }

        // Warm the path (allocator steady state, first-touch pages) before the
        // window the assertion measures.
        for _ in 0..<200 { _ = player.pullRenderQuantum(frameCount, into: &bufferList) }
        XCTAssertGreaterThan(quanta, 0, "tap never fired")

        let before = resident()
        // ~10k quanta ≈ two minutes of 44.1kHz audio at this quantum size.
        for _ in 0..<10_000 { _ = player.pullRenderQuantum(frameCount, into: &bufferList) }
        let after = resident()

        let growth = after - before
        // Generous but finite: the leak this guards reported itself in GBs.
        XCTAssertLessThan(growth, 32 * 1024 * 1024,
                         "resident footprint grew \(growth / 1024 / 1024) MiB over 10k render quanta")
    }
}
#endif
