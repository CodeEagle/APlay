//
//  APlayer.swift
//  APlay
//
//  Created by lincoln on 2018/6/29.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import AVFoundation

// OSAtomic is available on the deployment targets (Swift Synchronization is not).
// Heap storage avoids Swift's overlapping-access checks on atomic accesses.
final class RenderAtomic: @unchecked Sendable {
    private let storage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    init(_ value: Int64 = 0) { storage.initialize(to: value) }
    deinit { storage.deinitialize(count: 1); storage.deallocate() }
    func load() -> Int64 { OSAtomicAdd64Barrier(0, storage) }
    func add(_ value: Int64) -> Int64 { OSAtomicAdd64Barrier(value, storage) }
    func exchange(_ value: Int64) -> Int64 {
        while true { let old = load(); if compare(old, value) { return old } }
    }
    func compare(_ old: Int64, _ new: Int64) -> Bool {
        OSAtomicCompareAndSwap64Barrier(old, new, storage)
    }
}

/// Writers retain immutable contexts before publishing. The reader enters an
/// epoch before loading a pointer; retired contexts are reclaimed only after
/// a subsequent quiescent epoch. This protects source lifetime, NOT the AU:
/// AudioOutputUnitStop remains the graph teardown boundary.
final class RenderReadSlot: @unchecked Sendable {
    final class Source {
        let read: (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool)
        let next = RenderAtomic()
        let activated = RenderAtomic()
        let enabled: RenderAtomic?
        let exhausted: RenderAtomic?
        let onActivate: () -> Void
        init(_ read: @escaping (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool),
             enabled: RenderAtomic? = nil, exhausted: RenderAtomic? = nil, onActivate: @escaping () -> Void = {}) {
            self.enabled = enabled; self.exhausted = exhausted
            self.read = read; self.onActivate = onActivate
        }
        var address: Int64 { Int64(Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())) }
    }
    private let current = RenderAtomic()
    private let readers = RenderAtomic()
    private let lock = NSLock() // writers only; never acquired by read()
    private var retained: [Source] = []
    func set(_ closure: @escaping (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool), exhausted: RenderAtomic? = nil, preserveNext: Bool = false) {
        let source = Source(closure, exhausted: exhausted)
        lock.lock()
        if preserveNext, let previous = retained.first(where: { $0.address == current.load() }) {
            _ = source.next.exchange(previous.next.load())
        }
        retained.append(source)
        _ = current.exchange(source.address)
        reclaim()
        lock.unlock()
    }
    func arm(_ closure: @escaping (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool),
             enabled: RenderAtomic, exhausted: RenderAtomic, onActivate: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let active = retained.first(where: { $0.address == current.load() }) else { return }
        let next = Source(closure, enabled: enabled, exhausted: exhausted, onActivate: onActivate)
        retained.append(next)
        _ = active.next.exchange(next.address)
        reclaim()
    }
    func clear() {
        lock.lock(); _ = current.exchange(0); reclaim(); lock.unlock()
    }
    func collect() {
        lock.lock()
        let callbacks = retained.filter { $0.activated.exchange(0) != 0 }.map { $0.onActivate }
        reclaim()
        lock.unlock()
        callbacks.forEach { $0() }
    }
    private func reclaim() {
        // Snapshot the reachable set BEFORE the quiescence check. A reader
        // entering after the check can only reach these retained contexts.
        let address = current.load()
        let next = retained.first(where: { $0.address == address })?.next.load() ?? 0
        guard readers.load() == 0 else { return }
        retained.removeAll { $0.address != address && $0.address != next && $0.activated.load() == 0 }
    }
    @inline(__always)
    func read(_ size: UInt32, into pointer: UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) {
        _ = readers.add(1)
        defer { _ = readers.add(-1) }
        let address = current.load()
        guard address != 0 else { return (0, false) }
        let source = Unmanaged<Source>.fromOpaque(UnsafeRawPointer(bitPattern: Int(address))!).takeUnretainedValue()
        let result = source.read(size, pointer)
        if result.0 == 0, source.exhausted?.load() != 0 {
            let next = source.next.load()
            if next != 0 {
                let successor = Unmanaged<Source>.fromOpaque(UnsafeRawPointer(bitPattern: Int(next))!).takeUnretainedValue()
                guard successor.enabled?.load() != 0, current.compare(address, next) else { return result }
                _ = successor.activated.compare(0, 1)
                return successor.read(size, pointer)
            }
        }
        return result
    }
}

final class APlayer: PlayerCompatible, @unchecked Sendable {
    /// The render callback reads through this slot rather than through
    /// `readClosure` directly, so a preloaded track can take over the output
    /// without the callback being rebound. `readClosure` remains the install
    /// point (see `Composer.installReadSource`).
    private let _readSlot = RenderReadSlot()
    private let control = DispatchQueue(label: "APlayer.control")
    private var initialized = false
    private var running = false
    private var wantsPlayback = false
    private var destroyed = false
    private var owner: UUID?
    private var installedOwner: UUID?
    private var collector: DispatchSourceTimer?
    private var lifetime: APlayer?
    private var mailboxes: [UUID: () -> Void] = [:]
    func observe(_ token: UUID, poll: @escaping () -> Void) {
        submit { self.mailboxes[token] = poll }
    }
    func unobserve(_ token: UUID) { submit { self.mailboxes.removeValue(forKey: token) } }
    func submit(_ work: @escaping @Sendable () -> Void) { control.async(execute: work) }
    func select(_ token: UUID, autoplay: Bool?) {
        submit {
            self.owner = token
            if let autoplay { self.wantsPlayback = autoplay }
        }
    }
    func configure(_ format: AudioStreamBasicDescription, token: UUID, exhausted: RenderAtomic,
                   valid: @escaping () -> Bool,
                   source: @escaping (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool), ready: @escaping () -> Bool) {
        submit {
            guard !self.destroyed, self.owner == token, valid() else { return }
            let preserveNext = self.initialized && self.asbd == format
            let replaceSource = self.installedOwner != token || !preserveNext
            guard self.performSetup(format) else { return }
            guard self.owner == token, valid() else { return }
            if replaceSource { self._readSlot.set(source, exhausted: exhausted, preserveNext: preserveNext); self.installedOwner = token }
            if ready() && self.wantsPlayback { self.performResume() }
        }
    }
    func armNext(_ format: AudioStreamBasicDescription, token: UUID, enabled: RenderAtomic, exhausted: RenderAtomic,
                 valid: @escaping () -> Bool,
                 source: @escaping (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool),
                 completion: @escaping () -> Void) {
        submit { [self] in
            guard self.initialized, self.asbd == format, valid() else { return }
            self._readSlot.arm(source, enabled: enabled, exhausted: exhausted) { [weak self] in
                guard let self, valid() else { return }
                self.owner = token
                self.installedOwner = token
                completion()
            }
        }
    }

    var readClosure: (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) = { _, _ in (0, false) } {
        didSet {
            _readSlot.set(readClosure)
        }
    }

    var eventPipeline: Delegated<Player.Event, Void> = Delegated<Player.Event, Void>()

    var startTime: Float = 0 {
        didSet {
            _ = renderedFrames.exchange(0)
        }
    }

    private let renderedFrames = RenderAtomic()
    private lazy var _volume: Float = 1

    private let formatLock = NSLock()
    private var configuredFormat = AudioStreamBasicDescription()
    private(set) var asbd: AudioStreamBasicDescription {
        get { formatLock.lock(); defer { formatLock.unlock() }; return configuredFormat }
        set { formatLock.lock(); configuredFormat = newValue; formatLock.unlock() }
    }

    private(set) var state: Player.State {
        get {
            // `APlay.deinit` can run on this queue: the last release of APlay
            // may land inside a state callback's temporary target retain, and
            // deinit tears the player down. A sync read from there would
            // deadlock, so read directly when already serialized on the queue.
            // That is race-free: `_state` is only mutated inside barrier blocks,
            // which run exclusively on a concurrent queue.
            if DispatchQueue.getSpecific(key: APlayer.stateQueueKey) == ObjectIdentifier(self) {
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

    private var _state: Player.State = .idle
    private let _stateQueue = DispatchQueue(concurrentName: "APlayer.state")
    private static let stateQueueKey = DispatchSpecificKey<ObjectIdentifier>()

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

    /// The AudioBufferList handed to `AVAudioEngine`'s manual rendering input
    /// block.
    ///
    /// `withUnsafePointer(to: &someProperty)` only promises the pointer for the
    /// duration of the call, but the engine reads the returned list *after* the
    /// input block returns. Under optimization the compiler is free to hand back
    /// the address of a temporary, so the render would pull freed/reused memory
    /// and emit silence — an output-only, Release-only failure. The list is kept
    /// on stable, object-owned storage instead.
    fileprivate let _inputBufferList: UnsafeMutablePointer<AudioBufferList> = .allocate(capacity: 1)

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
    /// Built from `Configuration.equalizerBandFrequencies`; every band is
    /// unbypassed and given its centre frequency on init, since `AVAudioUnitEQ`
    /// ships every band bypassed (a no-op) and laid out on a generic log scale.
    private let _eq: AVAudioUnitEQ
    fileprivate var _renderBlock: AVAudioEngineManualRenderingBlock?

    /// Realtime PCM observer. Invoked on the audio thread from the render
    /// input block, so it must be lock-free and allocation-free on the reader
    /// side. See `PlayerCompatible.pcmTap`.
    var pcmTap: ((UnsafePointer<AudioBufferList>, UInt32, AVAudioFormat) -> Void)?

    private let _config: ConfigurationCompatible

    deinit {
        if let unit = _player { AudioComponentInstanceDispose(unit).check() }
        _inputBufferList.deallocate()
        _buffers.deallocate()
        debug_log("\(self) \(#function)")
    }

    init(config: ConfigurationCompatible) {
        _config = config
        let frequencies = config.equalizerBandFrequencies
        _eq = AVAudioUnitEQ(numberOfBands: frequencies.count)
        _stateQueue.setSpecific(key: APlayer.stateQueueKey, value: ObjectIdentifier(self))
        configureEqualizerBands(frequencies)
        _engine.attach(_eq)
        // Avoid requesting microphone permission, set rendering mode first before connect
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        _engine.stop()
        try? _engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: Player.maxFramesPerSlice)
        _engine.connect(_engine.inputNode, to: _eq, format: nil)
        _engine.connect(_eq, to: _engine.mainMixerNode, format: nil)
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self._readSlot.collect()
            Array(self.mailboxes.values).forEach { $0() }
        }
        collector = timer
        timer.resume()
    }
}

// MARK: - Create Player

private extension APlayer {

    /// Lays the equalizer bands over the configured centre frequencies and
    /// unbypasses them. Shelf filters bookend the band: the first band shapes
    /// the low end, the last the top, and the bands between are parametric.
    func configureEqualizerBands(_ frequencies: [Float]) {
        let bands = _eq.bands
        guard bands.count == frequencies.count, bands.count > 0 else { return }
        for (index, band) in bands.enumerated() {
            band.bypass = false
            band.frequency = frequencies[index]
            band.filterType = APlayer.filterType(forBandAt: index, total: bands.count)
            // One octave is the natural width for a graphic-style EQ spanned
            // logarithmically over the audible range.
            band.bandwidth = 1.0
            band.gain = 0
        }
    }

    private static func filterType(forBandAt index: Int, total: Int) -> AVAudioUnitEQFilterType {
        switch index {
        case 0 where total > 1:
            return .lowShelf
        case total - 1 where total > 1:
            return .highShelf
        default:
            return .parametric
        }
    }

    private func updatePlayerConfig() throws {
        guard let unit = _player else { return }
        var format = asbd
        let s = MemoryLayout.size(ofValue: format)
        // set stream format for input bus
        try AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, Player.Bus.output, &format, UInt32(s)).throwCheck()

        var maxFramesPerSlice = Player.maxFramesPerSlice
        let fSize = MemoryLayout.size(ofValue: maxFramesPerSlice)
        try AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesPerSlice, UInt32(fSize)).throwCheck()
        // render callback
        lifetime = self // established before Core Audio can use the unretained refCon
        let pointer = UnsafeMutableRawPointer.from(object: self)
        var callbackStruct = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: pointer)
        let callbackSize = MemoryLayout.size(ofValue: callbackStruct)
        try AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                 kAudioUnitScope_Output, Player.Bus.output, &callbackStruct,
                                 UInt32(callbackSize)).throwCheck()

    }
}

// MARK: - PlayerCompatible

extension APlayer {
    func destroy() {
        submit {
            self.lifetime = self
            self.wantsPlayback = false
            guard self.stopOutput() else { return }
            self.destroyed = true
            self._engine.stop()
            self._renderBlock = nil
            if let unit = self._player {
                do {
                    var callback = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
                    try AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Output, Player.Bus.output, &callback, UInt32(MemoryLayout.size(ofValue: callback))).throwCheck()
                    try AudioUnitUninitialize(unit).throwCheck()
                    try AudioComponentInstanceDispose(unit).throwCheck()
                    self._player = nil
                } catch {
                    self.eventPipeline.call(.unknown(error))
                    return // retain callback context and buffers if closing failed
                }
            }
            self.initialized = false
            self._readSlot.clear()
            self.collector?.cancel()
            self._playbackTimer.invalidate()
            self.eventPipeline.removeDelegate()
            self.mailboxes.removeAll()
            self.lifetime = nil
        }
    }

    private func stopOutput() -> Bool {
        guard let unit = _player else { return true }
        do {
            // No source, progress, event or state lock is held across Stop.
            try AudioOutputUnitStop(unit).throwCheck()
            running = false
            return true
        } catch {
            eventPipeline.call(.unknown(error))
            return false // preserve the complete old graph on failed Stop
        }
    }

    func pause() {
        submit {
            self.wantsPlayback = false
            guard self.stopOutput() else { return }
            self.state = .paused
            self._playbackTimer.pause()
        }
    }

    func resume() {
        submit { self.wantsPlayback = true; self.performResume() }
    }

    private func performResume() {
        guard !destroyed, initialized, !running, wantsPlayback, let unit = _player else { return }
        do {
            try AudioOutputUnitStart(unit).throwCheck()
            running = true
            state = .running
            _config.startBackgroundTask(isToDownloadImage: false)
            _playbackTimer.resume()
        } catch {
            _ = stopOutput()
            state = .idle
            eventPipeline.call(.unknown(error))
        }
    }

    func toggle() {
        submit {
            self.wantsPlayback.toggle()
            if self.wantsPlayback { self.performResume() }
            else if self.stopOutput() { self.state = .paused; self._playbackTimer.pause() }
        }
    }

    func currentTime() -> Float {
        let rate = asbd.mSampleRate
        return (rate > 0 ? Float(renderedFrames.load()) / Float(rate) : 0) + startTime
    }

    var volume: Float {
        get { return _volume }
        set {
            _volume = newValue
            let value = newValue
            submit {
                if let unit = self._player {
                    AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, value, 0)
                }
            }
        }
    }

    func setEqualizerBandGain(index: Int, gain: Float) {
        guard _eq.bands.indices.contains(index) else { return }
        // The audio unit clamps to -96...24 dB; clamp here too so the value
        // read back through `equalizerBandGains` matches what was requested.
        _eq.bands[index].gain = min(max(gain, -96), 24)
    }

    var equalizerBandGains: [Float] {
        return _eq.bands.map { $0.gain }
    }

    /// The equalizer bands as configured from `Configuration.equalizerBandFrequencies`.
    /// Internal because the public API exposes them through `APlay.equalizerGains`;
    /// tests read this to assert frequency, filter type and bypass state.
    var equalizerBands: [AVAudioUnitEQFilterParameters] {
        return Array(_eq.bands)
    }

    func setup(_ value: AudioStreamBasicDescription) {
        submit {
            if self.performSetup(value), self.wantsPlayback { self.performResume() }
        }
    }

    private func performSetup(_ value: AudioStreamBasicDescription) -> Bool {
        dispatchPrecondition(condition: .onQueue(control))
        guard !destroyed else { return false }
        if initialized && asbd == value { return true }
        guard stopOutput() else { return false }
        initialized = false
        do {
            _engine.stop()
            _renderBlock = nil
            guard let unit = _player else { return false }
            try AudioUnitUninitialize(unit).throwCheck()
            asbd = value
            try updatePlayerConfig()
            var description = value
            guard let format = AVAudioFormat(streamDescription: &description), value.mBytesPerFrame > 0,
                  value.mBytesPerFrame <= UInt32(Player.minimumBufferSize) / Player.maxFramesPerSlice else {
                throw APlay.Error.player("Unsupported output buffer size or format")
            }
            let bytesPerFrame = value.mBytesPerFrame
            let channels = value.mChannelsPerFrame
            _engine.disableManualRenderingMode()
            try _engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: Player.maxFramesPerSlice)
            let inputInstalled = _engine.inputNode.setManualRenderingInputPCMFormat(format) { [weak self] frameCount in
                guard let sself = self, frameCount <= Player.maxFramesPerSlice else { return nil }
                let size = bytesPerFrame * frameCount
                let (readSize, _) = sself._readSlot.read(size, into: sself._buffers)
                let totalReadFrame = min(readSize, size) / bytesPerFrame
                if readSize < size {
                    memset(sself._buffers.advanced(by: Int(readSize)), 0, Int(size - readSize))
                }
                sself._inputBufferList.pointee.mNumberBuffers = 1
                sself._inputBufferList.pointee.mBuffers.mNumberChannels = channels
                sself._inputBufferList.pointee.mBuffers.mDataByteSize = size
                sself._inputBufferList.pointee.mBuffers.mData = UnsafeMutableRawPointer(sself._buffers)
                _ = sself.renderedFrames.add(Int64(totalReadFrame))
                sself.pcmTap?(UnsafePointer(sself._inputBufferList), totalReadFrame, format)
                return UnsafePointer(sself._inputBufferList)
            }
            guard inputInstalled else { throw APlay.Error.player("Manual rendering input rejected the format") }
            try AudioUnitInitialize(unit).throwCheck()
            _engine.prepare()
            try _engine.start()
            _renderBlock = _engine.manualRenderingBlock
            initialized = true
            return true
        } catch {
            _engine.stop()
            _renderBlock = nil
            eventPipeline.call(.unknown(error))
            return false
        }
    }

}

#if DEBUG
extension APlayer {
    /// Test-only render seam.
    ///
    /// The xctest process cannot start an output audio unit on macOS (-10867;
    /// see `APlaySmokeTests`), so real end-to-end playback is exercised by the
    /// `APlayMacPlayback` executable. This pulls one render quantum through the
    /// same `AVAudioEngineManualRenderingBlock` the output unit's render callback
    /// drives — which is enough to assert `pcmTap` is wired into the render path
    /// with a correct format and frame count, without touching any audio unit.
    ///
    /// `setup(_:)` must have been called first so the block is armed.
    /// - Returns: the status the rendering block reported.
    @discardableResult
    func pullRenderQuantum(_ frameCount: UInt32, into ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        control.sync {
            var status: OSStatus = noErr
            _ = _renderBlock?(frameCount, ioData, &status)
            return status
        }
    }
}
#endif

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
