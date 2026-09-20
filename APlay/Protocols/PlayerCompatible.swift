//
//  PlayerCompatible.swift
//  APlay
//
//  Created by lincoln on 2018/7/2.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation
protocol PlayerCompatible: AnyObject {
    var readClosure: (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) { get set }
    var eventPipeline: Delegated<Player.Event, Void> { get }
    var startTime: Float { get set }
    var asbd: AudioStreamBasicDescription { get }
    var state: Player.State { get }
    var volume: Float { get set }

    func destroy()
    func pause()
    func resume()
    func toggle()

    func setup(_: AudioStreamBasicDescription)

    /// The current gain (in dB) of an equalizer band at runtime.
    ///
    /// Players without a built-in equalizer implement this as a no-op.
    /// - Parameters:
    ///   - index: Band index, matching the order of `Configuration.equalizerBandFrequencies`.
    ///   - gain: Band gain in dB.
    func setEqualizerBandGain(index: Int, gain: Float)

    /// The current gain of every equalizer band, in dB, ordered like
    /// `Configuration.equalizerBandFrequencies`. Players without a built-in
    /// equalizer return an empty array.
    var equalizerBandGains: [Float] { get }

    func currentTime() -> Float

    init(config: ConfigurationCompatible)
}

extension PlayerCompatible {
    /// Default no-op for players without a built-in equalizer.
    func setEqualizerBandGain(index: Int, gain: Float) {}

    /// Default empty read-back for players without a built-in equalizer.
    var equalizerBandGains: [Float] { [] }
}

struct Player {
    static let maxFramesPerSlice: UInt32 = 4096

    static let ringBufferSize: UInt32 = 1024 * 1024 * 2

    static let maxReadPerSlice: Int = Int(maxFramesPerSlice * canonical.mBytesPerPacket)
    static let minimumBufferCount: Int = 1
    static let minimumBufferSize: Int = maxReadPerSlice * minimumBufferCount

    static let canonical: AudioStreamBasicDescription = {
        let bytesPerSample = UInt32(MemoryLayout<Int16>.size)
        let flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        let component = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: bytesPerSample * 2, mFramesPerPacket: 1, mBytesPerFrame: bytesPerSample * 2, mChannelsPerFrame: 2, mBitsPerChannel: 8 * bytesPerSample, mReserved: 0)
        return component
    }()

    enum State { case idle, running, paused }

    enum Event {
        case playback(Float)
        case state(State)
        case error(APlay.Error)
        case unknown(Error)
    }

    struct Bus {
        static let output: UInt32 = 0
        static let input: UInt32 = 1
    }
}
