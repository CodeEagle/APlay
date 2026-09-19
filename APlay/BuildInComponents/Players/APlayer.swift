//
//  APlayer.swift
//  APlay
//
//  Created by lincoln on 2018/6/29.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import AVFoundation

/// Indirection between the realtime render callback and the buffer it reads
/// from, so the active source can be swapped without rebinding the callback and
/// without stopping the audio unit.
///
/// The swap happens when a preloaded track takes over (gapless playback); the
/// render thread only ever reads. Both sides take an `os_unfair_lock`, which is
/// a single uncontended atomic load on the read path. The closure is copied out
/// *before* the lock is released, so a swap performed re-entrantly from inside
/// the closure itself (linear PCM reports end of track from the render thread)
/// can never deadlock, and the source it is replacing stays alive for the read
/// in progress.
final class RenderReadSlot: @unchecked Sendable {
    private var _closure: ((UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool))?
    private var _lock = os_unfair_lock()

    func set(_ closure: @escaping (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool)) {
        os_unfair_lock_lock(&_lock)
        _closure = closure
        os_unfair_lock_unlock(&_lock)
    }

    func clear() {
        os_unfair_lock_lock(&_lock)
        _closure = nil
        os_unfair_lock_unlock(&_lock)
    }

    @inline(__always)
    func read(_ size: UInt32, into pointer: UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) {
        os_unfair_lock_lock(&_lock)
        let closure = _closure
        os_unfair_lock_unlock(&_lock)
        return closure?(size, pointer) ?? (0, false)
    }
}

final class APlayer: PlayerCompatible, @unchecked Sendable {
    /// The render callback reads through this slot rather than through
    /// `readClosure` directly, so a preloaded track can take over the output
    /// without the callback being rebound. `readClosure` remains the install
    /// point (see `Composer.installReadSource`).
    private let _readSlot = RenderReadSlot()

    var readClosure: (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) = { _, _ in (0, false) } {
        didSet {
            _readSlot.set(readClosure)
        }
    }

    var eventPipeline: Delegated<Player.Event, Void> = Delegated<Player.Event, Void>()

    var startTime: Float = 0 {
        didSet {
            _stateQueue.async(flags: .barrier) { self._progress = 0 }
        }
    }

    fileprivate lazy var _progress: Float = 0
    private lazy var _volume: Float = 1

    private(set) lazy var asbd = AudioStreamBasicDescription()

    private(set) var state: Player.State {
        get {
            // `APlay.deinit` can run on this queue: the last release of APlay
            // may land inside a state callback's temporary target retain, and
            // deinit tears the player down. A sync read from there would
            // deadlock, so read directly when already serialized on the queue.
            // That is race-free: `_state` is only mutated inside barrier blocks,
            // which run exclusively on a concurrent queue.
            if DispatchQueue.getSpecific(key: APlayer.stateQueueKey) != nil {
                return _state
            }
            return _stateQueue.sync { _state }
        }
        set {
            _stateQueue.async(flags: .barrier) {
                self._state = newValue
                self.eventPipeline.call(.state(newValue))
            }
        }
    }

    private lazy var _state: Player.State = .idle
    private lazy var _stateQueue: DispatchQueue = {
        let queue = DispatchQueue(concurrentName: "APlayer.state")
        queue.setSpecific(key: APlayer.stateQueueKey, value: ())
        return queue
    }()

    private static let stateQueueKey = DispatchSpecificKey<Void>()

    private lazy var _playbackTimer: GCDTimer = {
        GCDTimer(interval: .seconds(1), callback: { [weak self] _ in
            guard let sself = self else { return }
            sself.eventPipeline.call(.playback(sself.currentTime()))
        })
    }()

    private lazy var _buffers: UnsafeMutablePointer<UInt8> = {
        let size = Player.minimumBufferSize
        return UnsafeMutablePointer.uint8Pointer(of: size)
    }()

    private lazy var audioBufferList: AudioBufferList = {
        let buf = AudioBuffer()
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buf)
        return list
    }()

    private var _player: AudioUnit? = {
        #if os(OSX)
            let subType = kAudioUnitSubType_DefaultOutput
        #else
            let subType = kAudioUnitSubType_RemoteIO
        #endif
        var player: AudioUnit?
        var componentDesc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: subType, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let audioComponent = AudioComponentFindNext(nil, &componentDesc) else { fatalError("player create failure") }
        AudioComponentInstanceNew(audioComponent, &player).check()
        return player
    }()

    private let _engine = AVAudioEngine()
    /// <https://baike.baidu.com/item/EQ均衡器>
    private let _eq = AVAudioUnitEQ()
    fileprivate var _renderBlock: AVAudioEngineManualRenderingBlock?

    private unowned let _config: ConfigurationCompatible

    deinit {
        debug_log("\(self) \(#function)")
    }

    init(config: ConfigurationCompatible) {
        _config = config
        _engine.attach(_eq)
        // Avoid requesting microphone permission, set rendering mode first before connect
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        _engine.stop()
        try? _engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: Player.maxFramesPerSlice)
        _engine.connect(_engine.inputNode, to: _eq, format: nil)
        _engine.connect(_eq, to: _engine.mainMixerNode, format: nil)
    }
}

// MARK: - Create Player

private extension APlayer {
    private func updatePlayerConfig() throws {
        guard let unit = _player else { return }
        let s = MemoryLayout.size(ofValue: asbd)
        // set stream format for input bus
        try AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, Player.Bus.output, &asbd, UInt32(s)).throwCheck()

        var maxFramesPerSlice = Player.maxFramesPerSlice
        let fSize = MemoryLayout.size(ofValue: maxFramesPerSlice)
        try AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesPerSlice, UInt32(fSize)).throwCheck()
        // render callback
        let pointer = UnsafeMutableRawPointer.from(object: self)
        var callbackStruct = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: pointer)
        let callbackSize = MemoryLayout.size(ofValue: callbackStruct)
        try AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                 kAudioUnitScope_Output, Player.Bus.output, &callbackStruct,
                                 UInt32(callbackSize)).throwCheck()
        // setup() can be called more than once (canonical format, then the decoded
        // format); re-initializing requires uninitializing first or the AU keeps its
        // previous render configuration and refuses to start (-10867).
        AudioUnitUninitialize(unit)
        try AudioUnitInitialize(unit).throwCheck()
    }
}

// MARK: - PlayerCompatible

extension APlayer {
    func destroy() {
        _engine.stop()
        _playbackTimer.invalidate()
        pause()
        readClosure = { _, _ in (0, false) }
        eventPipeline.removeDelegate()
    }

    func pause() {
        guard state == .running, let unit = _player else { return }
        AudioOutputUnitStop(unit).check()
        state = .paused
        _playbackTimer.pause()
    }

    func resume() {
        guard state != .running, let unit = _player else { return }
        do {
            try AudioOutputUnitStart(unit).throwCheck()
            state = .running
            _config.startBackgroundTask(isToDownloadImage: false)
            _playbackTimer.resume()
        } catch {
            state = .idle
            debug_log(error.localizedDescription)
        }
    }

    func toggle() {
        state == .paused ? resume() : pause()
    }

    func currentTime() -> Float {
        return _stateQueue.sync { _progress / Float(asbd.mSampleRate) + startTime }
    }

    var volume: Float {
        get { return _volume }
        set {
            _volume = newValue
            #if os(iOS)
                if let unit = _player {
                    AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, _volume, 0)
                }
            #else
                if let unit = _player {
                    AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, _volume, 0)
                }
            #endif
        }
    }

    func setup(_ value: AudioStreamBasicDescription) {
        do {
            asbd = value
            try updatePlayerConfig()
            let format = AVAudioFormat(streamDescription: &asbd)!
            _engine.stop()
            try _engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: Player.maxFramesPerSlice)
            _renderBlock = _engine.manualRenderingBlock

            _engine.inputNode.setManualRenderingInputPCMFormat(format) { [weak self] (frameCount) -> UnsafePointer<AudioBufferList>? in
                guard let sself = self else { return nil }
                let bytesPerFrame = sself.asbd.mBytesPerFrame
                let size = bytesPerFrame * frameCount

                let (readSize, _) = sself._readSlot.read(size, into: sself._buffers)
                
                var totalReadFrame: UInt32 = frameCount
                if readSize != size {
                    totalReadFrame = readSize / bytesPerFrame
                    memset(sself._buffers.advanced(by: Int(readSize)), 0, Int(size - readSize))
                }
                sself.audioBufferList.mBuffers.mData = UnsafeMutableRawPointer(sself._buffers)
                sself.audioBufferList.mBuffers.mNumberChannels = sself.asbd.mChannelsPerFrame
                sself.audioBufferList.mBuffers.mDataByteSize = size

                let progress = sself._progress + Float(totalReadFrame)
                sself._stateQueue.async(flags: .barrier) { sself._progress = progress }
                return withUnsafePointer(to: &sself.audioBufferList, { $0 })
            }

            _engine.prepare()
            try _engine.start()
        } catch {
            eventPipeline.call(Player.Event.unknown(error))
        }
    }
}

/// renderCallback
///
/// - Parameters:
///   - userInfo: Your context (aka, user info) pointer.
///   - ioActionFlags: A bit field describing the purpose of the call. It’s often blank (0), and you can look up the possible values as the AudioUnitRenderActionFlag’s enum in the documentation or AUComponent.h.
///   - inTimeStamp: An AudioTimeStamp structure that indicates the timing of this call relative to other calls to your render callback.
///   - inBusNumber: Which bus (aka, element) of the Audio Unit is requesting audio data.
///   - inNumberFrames: The number of frames to be rendered. Notice that this variable is prefixed as “in” instead of “io.”That indicates that this isn’t a case when you can render fewer frames and indicate that situation by passing back the number of frames actually rendered.Your callback must provide exactly the requested number of frames.
///   - ioData: An AudioBufferList struct to be filled with data.You write your sam- ples into the mData members of the AudioBuffers contained in this struct.The list has a count of how many AudioBuffers are present, and each AudioBuffer has members for its channel count and byte size. Combined with inNumberFrames, you can figure out how much data can be safely written to these data buffers.
/// - Returns: OSStatus
private func renderCallback(userInfo: UnsafeMutableRawPointer, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp _: UnsafePointer<AudioTimeStamp>, inBusNumber _: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let sself = userInfo.to(object: APlayer.self)
    var status = noErr
    _ = sself._renderBlock?(inNumberFrames, ioData!, &status)
    return status
}
