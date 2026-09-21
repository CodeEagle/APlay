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
