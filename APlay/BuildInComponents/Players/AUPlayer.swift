//
//  AUPlayer.swift
//  VinylPlayer
//
//  Created by lincolnlaw on 2017/9/1.
//  Copyright © 2017年 lincolnlaw. All rights reserved.
//

import AudioUnit
import Foundation

final class AUPlayer: PlayerCompatible {
    

    var readClosure: (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) = { _, _ in (0, false) }

    var eventPipeline: Delegated<Player.Event, Void> = Delegated<Player.Event, Void>()

    var startTime: Float = 0 {
        didSet {
            _stateQueue.async(flags: .barrier) { self._progress = 0 }
        }
    }
    private(set) lazy var asbd = AudioStreamBasicDescription()
    
    private(set) var state: Player.State {
        get { return _stateQueue.sync { _state } }
        set {
            _stateQueue.async(flags: .barrier) {
                self._state = newValue
                self.eventPipeline.call(.state(newValue))
            }
        }
    }

    private lazy var _converterNodes: [AUNode] = []
    private lazy var _volume: Float = 1

    private lazy var _audioGraph: AUGraph? = nil

    private lazy var _equalizerEnabled = false
    private lazy var _equalizerOn = false

    private lazy var maxSizeForNextRead = 0
    private lazy var _cachedSize = 0

    private lazy var _eqNode: AUNode = 0
    private lazy var _mixerNode: AUNode = 0
    private lazy var _outputNode: AUNode = 0

    private lazy var _eqInputNode: AUNode = 0
    private lazy var _eqOutputNode: AUNode = 0
    private lazy var _mixerInputNode: AUNode = 0
    private lazy var _mixerOutputNode: AUNode = 0

    private lazy var _eqUnit: AudioUnit? = nil
    private lazy var _mixerUnit: AudioUnit? = nil
    private lazy var _outputUnit: AudioUnit? = nil

    private lazy var _audioConverterRef: AudioConverterRef? = nil
    

    private lazy var _eqBandCount: UInt32 = 0

    private lazy var _playbackTimer: GCDTimer = {
        GCDTimer(interval: .seconds(1), callback: { [weak self] _ in
            guard let sself = self else { return }
            sself.eventPipeline.call(.playback(sself.currentTime()))
        })
    }()

    

    private lazy var _state: Player.State = .idle
    private unowned let _config: ConfigurationCompatible

    fileprivate lazy var _stateQueue = DispatchQueue(concurrentName: "AUPlayer.state")

    fileprivate let _pcmBufferFrameSizeInBytes: UInt32 = AUPlayer.canonical.mBytesPerFrame

    fileprivate lazy var _progress: Float = 0

    fileprivate lazy var _currentIndex = 0
    fileprivate lazy var _pageSize = AUPlayer.maxReadPerSlice
    fileprivate func increaseBufferIndex() {
        _stateQueue.sync {
            _currentIndex = (_currentIndex + 1) % Int(AUPlayer.minimumBufferCount)
        }
    }

    fileprivate lazy var _buffers: UnsafeMutablePointer<UInt8> = {
        let size = AUPlayer.minimumBufferSize
        let b = malloc(size).assumingMemoryBound(to: UInt8.self)
        return b
    }()

    #if DEBUG
        private lazy var _fakeConsumer: GCDTimer = {
            GCDTimer(interval: .seconds(1), callback: { [weak self] _ in
                guard let sself = self else { return }
                let size = sself._pcmBufferFrameSizeInBytes * 4096
                let raw = sself._buffers.advanced(by: sself._currentIndex * sself._pageSize)
                sself.increaseBufferIndex()
                _ = sself.readClosure(size, raw)
            })
        }()
    #endif

    deinit {
        free(_buffers)
        debug_log("\(self) \(#function)")
    }

    init(config: ConfigurationCompatible) { _config = config }

    func setup(_ asbd: AudioStreamBasicDescription) {
        updateAudioGraph(asbd: asbd)
    }
    
    func destroy() {
        #if DEBUG
        if runProfile {
            _fakeConsumer.invalidate()
        }
        #endif
        _playbackTimer.invalidate()
        pause()
        readClosure = { _, _ in (0, false) }
        eventPipeline.removeDelegate()
    }
}

// MARK: - Open API

extension AUPlayer {
    func pause() {
        #if DEBUG
            if runProfile {
                _fakeConsumer.pause()
                return
            }
        #endif
        guard let audioGraph = _audioGraph else { return }
        let result = AUGraphStop(audioGraph)
        guard result == noErr else {
            let msg = result.check() ?? "\(result)"
            eventPipeline.call(.error(.player(msg)))
            return
        }
        state = .paused
        _playbackTimer.pause()
    }

    func resume() {
        #if DEBUG
            if runProfile {
                _fakeConsumer.resume()
                return
            }
        #endif
        guard let graph = _audioGraph else { return }
        if state == .paused {
            state = .running
            let result = AUGraphStart(graph)
            guard result == noErr else {
                let msg = result.check() ?? "\(result)"
                eventPipeline.call(.error(.player(msg)))
                return
            }
            _config.startBackgroundTask(isToDownloadImage: false)
            _playbackTimer.resume()
        } else if state == .idle {
            _progress = 0
            if audioGraphIsRunning() { return }
            do {
                try AUGraphStart(graph).throwCheck()
                _config.startBackgroundTask(isToDownloadImage: false)
                state = .running
                _playbackTimer.resume()
            } catch {
                if let err = error as? APlay.Error {
                    eventPipeline.call(.error(err))
                } else {
                    eventPipeline.call(.unknown(error))
                }
            }
        }
    }

    func currentTime() -> Float {
        guard state == .running else { return 0 }
        return _stateQueue.sync { _progress / Float(asbd.mSampleRate) + startTime }
    }

    func toggle() {
        state == .paused ? resume() : pause()
    }

    var volume: Float {
        get { return _volume }
        set {
            _volume = newValue
            #if os(iOS)
            if let unit = _mixerUnit {
                AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, _volume, 0)
            }
            #else
            if let unit = _mixerUnit {
                AudioUnitSetParameter(unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, _volume, 0)
            } else if let unit = _outputUnit {
                AudioUnitSetParameter(unit, kHALOutputParam_Volume, kAudioUnitScope_Output, AUPlayer.Bus.output, _volume, 0)
            }
            #endif
        }
    }
}

// MARK: - Create

private extension AUPlayer {
    func updateAudioGraph(asbd: AudioStreamBasicDescription) {
        self.asbd = asbd
        let volumeBefore = volume
        if _audioGraph != nil {
            volume = 0
            pause()
            connectGraph()
            resume()
            volume = volumeBefore
            return
        }
        do {
            try NewAUGraph(&_audioGraph).throwCheck()
            guard let graph = _audioGraph else { return }
            try AUGraphOpen(graph).throwCheck()
            createEqUnit()
            createMixerUnit()
            createOutputUnit()
            connectGraph()
            try AUGraphInitialize(graph).throwCheck()
            volume = volumeBefore
        } catch {
            if let e = error as? APlay.Error {
                eventPipeline.call(.error(e))
            } else {
                eventPipeline.call(.unknown(error))
            }
        }
    }

    private func createEqUnit() {
        #if os(OSX)
            guard #available(OSX 10.9, *) else { return }
        #endif
        let _options = _config
        guard let value = _options.equalizerBandFrequencies[ap_safe: 0], value != 0, let audioGraph = _audioGraph else { return }
        do {
            try AUGraphAddNode(audioGraph, &AUPlayer.nbandUnit, &_eqNode).throwCheck()
            try AUGraphNodeInfo(audioGraph, _eqNode, nil, &_eqUnit).throwCheck()
            guard let eqUnit = _eqUnit else { return }
            let size = MemoryLayout.size(ofValue: Player.maxFramesPerSlice)
            try AudioUnitSetProperty(eqUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &Player.maxFramesPerSlice, UInt32(size)).throwCheck()
            _eqBandCount = UInt32(_options.equalizerBandFrequencies.count)
            let eqBandSize = UInt32(MemoryLayout.size(ofValue: _eqBandCount))
            try AudioUnitSetProperty(eqUnit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &_eqBandCount, eqBandSize).throwCheck()
            let count = Int(_eqBandCount)
            for i in 0 ..< count {
                let value = _options.equalizerBandFrequencies[i]
                let index = UInt32(i)
                try AudioUnitSetParameter(eqUnit, kAUNBandEQParam_Frequency + index, kAudioUnitScope_Global, 0, value, 0).throwCheck()
                try AudioUnitSetParameter(eqUnit, kAUNBandEQParam_BypassBand + index, kAudioUnitScope_Global, 0, 0, 0).throwCheck()
//                try AudioUnitSetParameter(eqUnit, kAUNBandEQParam_Gain + index, kAudioUnitScope_Global, 0, gain, 0).throwCheck()
            }

        } catch let APlay.Error.player(err) {
            eventPipeline.call(.error(.player(err)))
        } catch {
            eventPipeline.call(.unknown(error))
        }
    }

    private func createMixerUnit() {
        let _options = _config
        guard _options.isEnabledVolumeMixer, let graph = _audioGraph else { return }
        do {
            try AUGraphAddNode(graph, &AUPlayer.mixer, &_mixerNode).throwCheck()
            try AUGraphNodeInfo(graph, _mixerNode, &AUPlayer.mixer, &_mixerUnit).throwCheck()
            guard let mixerUnit = _mixerUnit else { return }
            let size = UInt32(MemoryLayout.size(ofValue: Player.maxFramesPerSlice))
            try AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &Player.maxFramesPerSlice, size).throwCheck()
            var busCount: UInt32 = 1
            let busCountSize = UInt32(MemoryLayout.size(ofValue: busCount))
            try AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &busCount, busCountSize).throwCheck()
            var graphSampleRate: Float64 = 44100
            let graphSampleRateSize = UInt32(MemoryLayout.size(ofValue: graphSampleRate))
            try AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &graphSampleRate, graphSampleRateSize).throwCheck()
            try AudioUnitSetParameter(mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, 0, 1, 0).throwCheck()
        } catch let APlay.Error.player(err) {
            eventPipeline.call(.error(.player(err)))
        } catch {
            eventPipeline.call(.unknown(error))
        }
    }

    private func createOutputUnit() {
        guard let audioGraph = _audioGraph else { return }
        do {
            try AUGraphAddNode(audioGraph, &AUPlayer.outputUnit, &_outputNode).throwCheck()
            try AUGraphNodeInfo(audioGraph, _outputNode, &AUPlayer.outputUnit, &_outputUnit).throwCheck()
            guard let unit = _outputUnit else { return }
//            #if os(iOS)
//                var flag: UInt32 = 1
//                let size = UInt32(MemoryLayout.size(ofValue: flag))
//                try AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, Player.Bus.output, &flag, size).throwCheck()
//                flag = 0
//                try AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, Player.Bus.input, &flag, size).throwCheck()
//            #endif
            let s = MemoryLayout.size(ofValue: AUPlayer.canonical)
            try AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, Player.Bus.output, &AUPlayer.canonical, UInt32(s)).throwCheck()
        } catch let APlay.Error.player(err) {
            eventPipeline.call(.error(.player(err)))
        } catch {
            eventPipeline.call(.unknown(error))
        }
    }

    private func connectGraph() {
        guard let audioGraph = _audioGraph else { return }
        AUGraphClearConnections(audioGraph)
        for node in _converterNodes {
            AUGraphRemoveNode(audioGraph, node).check()
        }
        _converterNodes.removeAll()
        var nodes: [AUNode] = []
        var units: [AudioUnit] = []
        if let unit = _eqUnit {
            if _equalizerEnabled {
                nodes.append(_eqNode)
                units.append(unit)
                _equalizerOn = true
            } else {
                _equalizerOn = false
            }
        } else {
            _equalizerOn = false
        }

        if let unit = _mixerUnit {
            nodes.append(_mixerNode)
            units.append(unit)
        }

        if let unit = _outputUnit {
            nodes.append(_outputNode)
            units.append(unit)
        }
        if let node = nodes.first, let unit = units.first {
            setOutputCallback(for: node, unit: unit)
        } else {
            #if DEBUG
                fatalError("Output Callback Not Set!!!!!!!")
            #endif
        }
        for i in 0 ..< nodes.count - 1 {
            let node = nodes[i]
            let nextNode = nodes[i + 1]
            let unit = units[i]
            let nextUnit = units[i + 1]
            connect(node: node, destNode: nextNode, unit: unit, destUnit: nextUnit)
        }
    }

    func setOutputCallback(for node: AUNode, unit: AudioUnit) {
        var status: OSStatus = noErr
        let pointer = UnsafeMutableRawPointer.from(object: self)
        var callbackStruct = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: pointer)
        let sizeOfASBD = MemoryLayout.size(ofValue: asbd)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(sizeOfASBD))
        guard let audioGraph = _audioGraph else {
            #if DEBUG
                fatalError("Output Callback Not Set!!!!!!!")
            #else
                return
            #endif
        }
        do {
            if status == noErr {
                try AUGraphSetNodeInputCallback(audioGraph, node, 0, &callbackStruct).throwCheck()
            } else {
                var format: AudioStreamBasicDescription = AudioStreamBasicDescription()
                var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                try AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, &size).throwCheck()
                let converterNode = createConverterNode(for: asbd, destFormat: format)
                guard let c = converterNode else {
                    #if DEBUG
                        fatalError("Output Callback Not Set!!!!!!!")
                    #else
                        return
                    #endif
                }
                try AUGraphSetNodeInputCallback(audioGraph, c, 0, &callbackStruct).throwCheck()
                try AUGraphConnectNodeInput(audioGraph, c, 0, node, 0).throwCheck()
            }
        } catch let APlay.Error.player(err) {
            eventPipeline.call(.error(.player(err)))
        } catch {
            eventPipeline.call(.unknown(error))
        }
    }

    func connect(node: AUNode, destNode: AUNode, unit: AudioUnit, destUnit: AudioUnit) {
        guard let audioGraph = _audioGraph else { return }
        var status: OSStatus = noErr
        var needConverter = false
        var srcFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
        var desFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        do {
            try AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &srcFormat, &size).throwCheck()
            try AudioUnitGetProperty(destUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &desFormat, &size).throwCheck()

            needConverter = memcmp(&srcFormat, &desFormat, MemoryLayout.size(ofValue: srcFormat)) != 0
            if needConverter {
                status = AudioUnitSetProperty(destUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &srcFormat, UInt32(MemoryLayout.size(ofValue: srcFormat)))
                needConverter = status != noErr
            }
            if needConverter {
                if let convertNode = createConverterNode(for: srcFormat, destFormat: desFormat) {
                    try AUGraphConnectNodeInput(audioGraph, node, 0, convertNode, 0).throwCheck()
                    try AUGraphConnectNodeInput(audioGraph, convertNode, 0, destNode, 0).throwCheck()
                }

            } else {
                try AUGraphConnectNodeInput(audioGraph, node, 0, destNode, 0).throwCheck()
            }
        } catch let APlay.Error.player(err) {
            eventPipeline.call(.error(.player(err)))
        } catch {
            eventPipeline.call(.unknown(error))
        }
    }

    func createConverterNode(for format: AudioStreamBasicDescription, destFormat: AudioStreamBasicDescription) -> AUNode? {
        guard let audioGraph = _audioGraph else { return nil }
        var convertNode = AUNode()
        var convertUnit: AudioUnit?
        do {
            try AUGraphAddNode(audioGraph, &AUPlayer.convertUnit, &convertNode).throwCheck()
            try AUGraphNodeInfo(audioGraph, convertNode, &AUPlayer.mixer, &convertUnit).throwCheck()
            guard let unit = convertUnit else { return nil }
            var srcFormat = format
            try AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &srcFormat, UInt32(MemoryLayout.size(ofValue: format))).throwCheck()
            var desFormat = destFormat
            try AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &desFormat, UInt32(MemoryLayout.size(ofValue: destFormat))).throwCheck()
            try AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &Player.maxFramesPerSlice, UInt32(MemoryLayout.size(ofValue: Player.maxFramesPerSlice))).throwCheck()
            _converterNodes.append(convertNode)
            return convertNode
        } catch let APlay.Error.player(err) {
            eventPipeline.call(.error(.player(err)))
            return nil
        } catch {
            eventPipeline.call(.unknown(error))
            return nil
        }
    }

    private func audioGraphIsRunning() -> Bool {
        guard let graph = _audioGraph else { return false }
        var isRuning: DarwinBoolean = false
        guard AUGraphIsRunning(graph, &isRuning) == noErr else { return false }
        return isRuning.boolValue
    }
}

// MARK: - Model

extension AUPlayer {
    

  
    static var ringBufferSize: UInt32 = 1024 * 1024 * 2

    
    static let maxReadPerSlice: Int = Int(Player.maxFramesPerSlice * canonical.mBytesPerPacket)
    static let minimumBufferCount: Int = 8
    static let minimumBufferSize: Int = maxReadPerSlice * minimumBufferCount

    static var outputUnit: AudioComponentDescription = {
        #if os(OSX)
            let subType = kAudioUnitSubType_DefaultOutput
        #else
            let subType = kAudioUnitSubType_RemoteIO
        #endif
        let component = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: subType, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        return component
    }()

    static var canonical: AudioStreamBasicDescription = APlay.Configuration.canonical

    static var canonicalSize: UInt32 = {
        UInt32(MemoryLayout.size(ofValue: canonical))
    }()

    static var convertUnit: AudioComponentDescription = {
        let component = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_AUConverter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        return component
    }()

    static var mixer: AudioComponentDescription = {
        let component = AudioComponentDescription(componentType: kAudioUnitType_Mixer, componentSubType: kAudioUnitSubType_MultiChannelMixer, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        return component
    }()

    static func record() -> AudioStreamBasicDescription {
        var component = AudioStreamBasicDescription()
        component.mFormatID = kAudioFormatMPEG4AAC
        component.mFormatFlags = AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue)
        component.mChannelsPerFrame = canonical.mChannelsPerFrame
        component.mSampleRate = canonical.mSampleRate
        return component
    }

    static var nbandUnit: AudioComponentDescription = {
        let component = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_NBandEQ, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        return component
    }()
}

// MARK: - AURenderCallback

/// renderCallback
private func renderCallback(userInfo: UnsafeMutableRawPointer, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp _: UnsafePointer<AudioTimeStamp>, inBusNumber _: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let sself = userInfo.to(object: AUPlayer.self)

    let size = sself._pcmBufferFrameSizeInBytes * inNumberFrames
    ioData?.pointee.mBuffers.mNumberChannels = 2
    ioData?.pointee.mBuffers.mDataByteSize = size
    let raw = sself._buffers.advanced(by: sself._currentIndex * sself._pageSize)

    sself.increaseBufferIndex()
    let (readSize, _) = sself.readClosure(size, raw)
    var totalReadFrame: UInt32 = inNumberFrames
    ioActionFlags.pointee = AudioUnitRenderActionFlags.unitRenderAction_PreRender
    if readSize == 0 {
        ioActionFlags.pointee = AudioUnitRenderActionFlags.unitRenderAction_OutputIsSilence
        memset(raw, 0, Int(size))
        return noErr
    } else if readSize != size {
        totalReadFrame = readSize / sself._pcmBufferFrameSizeInBytes
        let left = size - readSize
        memset(raw.advanced(by: Int(readSize)), 0, Int(left))
    }
    ioData?.pointee.mBuffers.mData = UnsafeMutableRawPointer(raw)

    sself._stateQueue.async(flags: .barrier) { sself._progress += Float(totalReadFrame) }
    return noErr
}
