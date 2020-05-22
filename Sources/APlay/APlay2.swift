import AVFoundation

@available(iOS 11.0, *)
final class APlayer {
    
    var readClosure: (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) = { _, _ in (0, false) }

    private var _eventSubject: CurrentValueSubject<Event, Never> = .init(.state(.idle))
    public var eventPipeline: AnyPublisher<Event, Never> { _eventSubject.eraseToAnyPublisher() }

    var startTime: Float = 0 {
        didSet {
            _stateQueue.async(flags: .barrier) { self._progress = 0 }
        }
    }

    fileprivate lazy var _progress: Float = 0
    private lazy var _volume: Float = 1

    private(set) lazy var asbd = Player.canonical

    private(set) var state: State {
        get { return _stateQueue.sync { _state } }
        set {
            _stateQueue.async(flags: .barrier) {
                self._state = newValue
                self._eventSubject.send(.state(newValue))
            }
        }
    }

    private lazy var _state: State = .idle
    private lazy var _stateQueue = DispatchQueue(concurrentName: "AUPlayer.state")

    private lazy var _playbackTimer: GCDTimer = {
        GCDTimer(interval: .seconds(1), callback: { [weak self] _ in
            guard let sself = self else { return }
            sself._eventSubject.send(.playback(sself.currentTime()))
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
    
    public var pluginNodes: [AVAudioNode] = [] {
        didSet {
            oldValue.forEach { _engine.detach($0) }
            updateNodes()
        }
    }
    
    fileprivate var _renderBlock: AVAudioEngineManualRenderingBlock?

    private unowned let _config: ConfigurationCompatible

    deinit {
        debug_log("\(self) \(#function)")
    }

    init(config: ConfigurationCompatible) {
        _config = config
        setup()
    }
}

// MARK: - Create Player

@available(iOS 11.0, *)
private extension APlayer {
    private func updatePlayerConfig() throws {
        guard let unit = _player else { return }
        let s = MemoryLayout.size(ofValue: asbd)
        // set stream format for input bus
        try AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, Player.Bus.output, &asbd, UInt32(s)).throwCheck()

        let fSize = MemoryLayout.size(ofValue: Player.maxFramesPerSlice)
        try AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &Player.maxFramesPerSlice, UInt32(fSize)).throwCheck()
        // render callback
        let pointer = UnsafeMutableRawPointer.from(object: self)
        var callbackStruct = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: pointer)
        let callbackSize = MemoryLayout.size(ofValue: callbackStruct)
        try AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                 kAudioUnitScope_Output, Player.Bus.output, &callbackStruct,
                                 UInt32(callbackSize)).throwCheck()
    }
    
    func updateNodes() {
        reAttachNodes()
        reConnectNodes()
    }
    
    func reAttachNodes() {
        for node in pluginNodes {
            _engine.attach(node)
        }
    }

    func reConnectNodes() {
        // Avoid requesting microphone permission, set rendering mode first before connect
//        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
//        _engine.stop()
//        try? _engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: Player.maxFramesPerSlice)
//        _engine.connect(_engine.inputNode, to: _eq, format: nil)
//        _engine.connect(_eq, to: _engine.mainMixerNode, format: nil)
        let readFormat = AVAudioFormat(streamDescription: &asbd)!
        let startNode: AVAudioNode? = pluginNodes.first
        let endNode: AVAudioNode? = pluginNodes.last

        if let start = startNode {
            _engine.connect(_engine.inputNode, to: start, format: readFormat)
            for i in stride(from: 0, to: pluginNodes.count, by: 2) {
                if let first = pluginNodes[safe: i],
                    let next = pluginNodes[safe: i + 1] {
                    _engine.connect(first, to: next, format: readFormat)
                }
            }
            if let end = endNode {
                _engine.connect(end, to: _engine.mainMixerNode, format: readFormat)
            }
        } else {
            _engine.connect(_engine.inputNode, to: _engine.mainMixerNode, format: readFormat)
        }
    }

}

// MARK: - PlayerCompatible

@available(iOS 11.0, *)
extension APlayer {
    func destroy() {
        _engine.stop()
        _playbackTimer.invalidate()
        pause()
        readClosure = { _, _ in (0, false) }
        _eventSubject.send(completion: .finished)
    }

    func pause() {
        guard state.isPlaying, let unit = _player else { return }
        AudioOutputUnitStop(unit).check()
        state = .paused
        _playbackTimer.pause()
    }

    func resume() {
        guard state.isPlaying == false, let unit = _player else { return }
        do {
            try AudioOutputUnitStart(unit).throwCheck()
            state = .playing
            _config.startBackgroundTask(isToDownloadImage: false)
            _playbackTimer.resume()
        } catch {
            state = .idle
            debug_log(error.localizedDescription)
        }
    }

    func toggle() {
        state.isPlaying ? pause() : resume()
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

    func setup() {
        do {
            updateNodes()
            try updatePlayerConfig()
            let format = AVAudioFormat(streamDescription: &asbd)!
            _engine.stop()
            try _engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: Player.maxFramesPerSlice)
            _renderBlock = _engine.manualRenderingBlock

            _engine.inputNode.setManualRenderingInputPCMFormat(format) { [weak self] (frameCount) -> UnsafePointer<AudioBufferList>? in
                guard let sself = self else { return nil }
                let bytesPerFrame = sself.asbd.mBytesPerFrame
                let size = bytesPerFrame * frameCount

                let (readSize, _) = sself.readClosure(size, sself._buffers)
                
                var totalReadFrame: UInt32 = frameCount
                if readSize < size {
                    totalReadFrame = readSize / bytesPerFrame
                    memset(sself._buffers.advanced(by: Int(readSize)), 0, Int(size - readSize))
                }
                sself.audioBufferList.mBuffers.mData = UnsafeMutableRawPointer(sself._buffers)
                sself.audioBufferList.mBuffers.mNumberChannels = sself.asbd.mChannelsPerFrame
                sself.audioBufferList.mBuffers.mDataByteSize = max(readSize, size)

                sself._stateQueue.async(flags: .barrier) { sself._progress += Float(totalReadFrame) }
                return withUnsafePointer(to: &sself.audioBufferList, { $0 })
            }

            _engine.prepare()
            try _engine.start()
        } catch {
            _eventSubject.send(.unknown(error))
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
@available(iOS 11.0, *) private func renderCallback(userInfo: UnsafeMutableRawPointer, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp _: UnsafePointer<AudioTimeStamp>, inBusNumber _: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let sself = userInfo.to(object: APlayer.self)
    var status = noErr
    _ = sself._renderBlock?(inNumberFrames, ioData!, &status)
    return status
}
