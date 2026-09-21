//
//  OpusDecoder.swift
//  APlayOpus
//
//  Optional Opus decoder for WebM (`.webm`) and Matroska audio (`.mka`).
//
//  Core Audio ships an Opus decoder but no AudioFileStream parser for the
//  EBML container, so this wrapper demuxes the track in pure Swift
//  (`WebMDemuxer`) and hands the bare Opus packets to `AudioConverter`. No C
//  library is vendored — the codec itself is the platform's.
//
//  Wire it once on the configuration:
//  ```swift
//  let config = APlay.Configuration(
//     audioDecoderBuilder: APlayOpus.decoder(fallback: APlay.Configuration().audioDecoderBuilder))
//  ```
//

import APlay
import AudioToolbox
import CoreAudio
import Foundation

/// A WebM/Matroska Opus decoder backed by Core Audio's Opus converter.
///
/// A local file is buffered whole and demuxed up front, so the decoder is
/// seekable. Live streams are not supported — EBML cannot be parsed from a
/// non-seekable stream, and the packets are needed in order.
public final class OpusDecoder: @unchecked Sendable, AudioDecoderCompatible {

    private unowned let _config: ConfigurationCompatible
    private let _fallback: AudioDecoderCompatible
    private var _info = AudioDecoder.Info()
    private let _outputStream = Delegated<AudioDecoder.Event, Void>()
    private let _inputStream = Delegated<AudioDecoder.AudioInput, Void>()

    private let _stateQueue = DispatchQueue(label: "APlayOpus.State")
    private let _decodeQueue = DispatchQueue(label: "APlayOpus.Decode", qos: .userInitiated)
    private var _timer: DispatchSourceTimer?
    private var _isStopped = true
    private var _isDestroyed = false
    /// Set once the last packet has been consumed; the end is reported after
    /// any PCM still in flight, exactly once.
    private var _isAtEnd = false
    /// Set when `resume` arrives before the file is open; the timer starts
    /// once `prepare` has a context.
    private var _pendingResume = false

    private var _converter: AudioConverterRef?
    private var _packets: [Data] = []
    private var _packetIndex = 0
    /// The scratch the converter fills; one tick's worth of canonical PCM.
    private var _scratch = [UInt8]()
    private var _outputBuffer = [UInt8]()
    /// Storage the input proc hands out. Every fill is synchronous, so it is
    /// freed when the tick that allocated it ends.
    private var _inputBuffers: [UnsafeMutablePointer<UInt8>] = []
    private var _inputDescriptions: [UnsafeMutablePointer<AudioStreamPacketDescription>] = []

    /// True while a `prepare` was routed to the fallback, so `info`, seekability
    /// and the byte stream follow it instead of this decoder's empty state.
    private var _handedOff = false

    /// Decoded PCM is delivered in the pipeline's canonical format.
    private static let canonical: AudioStreamBasicDescription = {
        let bytesPerSample = UInt32(MemoryLayout<Int16>.size)
        let flags = CoreAudio.kAudioFormatFlagIsSignedInteger
            | CoreAudio.kAudioFormatFlagsNativeEndian
            | CoreAudio.kAudioFormatFlagIsPacked
        return AudioStreamBasicDescription(mSampleRate: 44100,
                                           mFormatID: CoreAudio.kAudioFormatLinearPCM,
                                           mFormatFlags: flags,
                                           mBytesPerPacket: bytesPerSample * 2,
                                           mFramesPerPacket: 1,
                                           mBytesPerFrame: bytesPerSample * 2,
                                           mChannelsPerFrame: 2,
                                           mBitsPerChannel: 8 * bytesPerSample,
                                           mReserved: 0)
    }()

    /// Frames decoded per timer tick.
    private static let framesPerTick: UInt32 = 4096

    public init(config: ConfigurationCompatible, fallback: AudioDecoderCompatible) {
        _config = config
        _fallback = fallback
        // The pipeline subscribes to *this* decoder when it is built, so a URL
        // the fallback takes must still surface its events and its bytes —
        // otherwise installing this product would silence every format it does
        // not own.
        _fallback.outputStream.delegate(to: self) { decoder, event in
            decoder._outputStream.call(event)
        }
        _inputStream.delegate(to: self) { decoder, input in
            guard decoder._handedOff else { return }
            decoder._fallback.inputStream.call(input)
        }
        let timer = DispatchSource.makeTimerSource(flags: [], queue: _decodeQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.decodeTick() }
        _timer = timer
    }

    /// Satisfies `AudioDecoderCompatible.init(config:)`. Direct construction has
    /// no fallback for other formats, so anything that is not WebM/Matroska
    /// fails cleanly instead of misbehaving — use `APlayOpus.decoder(fallback:)`
    /// to keep every other format working.
    public convenience init(config: ConfigurationCompatible) {
        self.init(config: config, fallback: UnhandledDecoder(config: config))
    }

    deinit {
        _timer?.setEventHandler(handler: nil)
        _timer?.cancel()
        if _isStopped { _timer?.resume() }
        closeFile()
    }

    // MARK: - File lifecycle

    private func closeFile() {
        _stateQueue.sync {
            if let converter = _converter {
                AudioConverterDispose(converter)
                _converter = nil
            }
            _packets.removeAll(keepingCapacity: false)
            _packetIndex = 0
            _isAtEnd = false
        }
    }

    // MARK: - Opening

    private func openFile(at url: URL, hint: AudioFileType) throws {
        guard let data = try? Data(contentsOf: url) else {
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        closeFile()

        guard let parsed = WebMDemuxer.parse(data), let track = parsed.track else {
            // Not EBML, or a Matroska file whose track is not A_OPUS.
            _config.logger.log("APlayOpus: no A_OPUS track in \(url.lastPathComponent)",
                               to: .audioDecoder, method: #function)
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        guard !parsed.packets.isEmpty else {
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        _packets = parsed.packets
        _packetIndex = 0

        var source = AudioStreamBasicDescription()
        source.mSampleRate = track.sampleRate
        source.mFormatID = kAudioFormatOpus
        source.mChannelsPerFrame = UInt32(track.channels)

        var destination = Self.canonical
        var converter: AudioConverterRef?
        // The converter takes the Opus packets straight to the pipeline's
        // canonical PCM — one step, no intermediate buffer.
        let status = AudioConverterNew(&source, &destination, &converter)
        guard status == noErr, let converter else {
            _config.logger.log("APlayOpus: AudioConverterNew failed with \(status)",
                               to: .audioDecoder, method: #function)
            let error = APlay.Error.parser(status)
            outputStream.call(.error(error))
            throw error
        }
        _converter = converter
        _scratch = [UInt8](repeating: 0,
                           count: Int(Self.framesPerTick) * Int(Self.canonical.mBytesPerFrame))

        _info.srcFormat = source
        _info.dstFormat = Self.canonical
        _info.sampleRate = track.sampleRate
        _info.audioDataByteCount = UInt(data.count)
        _info.dataOffset = 0
        _info.fileHint = hint
        // The container states the length, so the duration is exact rather
        // than estimated from the byte rate.
        if parsed.duration > 0 {
            _info.audioDataPacketCount = UInt(parsed.duration * track.sampleRate)
            _info.srcFormat.mFramesPerPacket = 1
        }
        _info.markAsUpdated()

        // Emitted before the timer starts so Now Playing data precedes the PCM.
        if !parsed.metadata.isEmpty {
            outputStream.call(.metadata(parsed.metadata))
        }

        // The timer is started last: `decodeTick` reads the converter and the
        // packets, so both must exist first.
        if _pendingResume {
            _pendingResume = false
            startTimer()
        }
    }

    // MARK: - Decoding

    private func decodeTick() {
        guard let converter = _converter, !_isDestroyed, !_isAtEnd else { return }
        _outputBuffer.removeAll(keepingCapacity: true)
        _inputBuffers.removeAll(keepingCapacity: true)
        _inputDescriptions.removeAll(keepingCapacity: true)
        defer {
            for buffer in _inputBuffers { buffer.deallocate() }
            for description in _inputDescriptions { description.deallocate() }
        }

        let bytesPerFrame = Int(Self.canonical.mBytesPerFrame)
        var framesThisTick: UInt32 = 0

        while framesThisTick < Self.framesPerTick, !_isAtEnd {
            var frames = Self.framesPerTick - framesThisTick
            var status = noErr
            _scratch.withUnsafeMutableBytes { raw in
                var list = AudioBufferList()
                list.mNumberBuffers = 1
                list.mBuffers = AudioBuffer(mNumberChannels: Self.canonical.mChannelsPerFrame,
                                            mDataByteSize: UInt32(raw.count),
                                            mData: raw.baseAddress)
                status = AudioConverterFillComplexBuffer(converter, opusInputProc,
                                                         Unmanaged.passUnretained(self).toOpaque(),
                                                         &frames, &list, nil)
            }
            if status != noErr {
                stop()
                outputStream.call(.error(APlay.Error.parser(status)))
                return
            }
            if frames == 0 {
                // The converter has nothing more to give: the packets ran out.
                _isAtEnd = true
                stop()
                break
            }
            _outputBuffer.append(contentsOf: _scratch.prefix(Int(frames) * bytesPerFrame))
            framesThisTick += frames
        }

        if !_outputBuffer.isEmpty {
            _outputBuffer.withUnsafeBytes { raw in
                outputStream.call(.output((raw.baseAddress!, UInt32(raw.count))))
            }
        }
        if _isAtEnd {
            // The PCM was delivered first, so the end follows it.
            outputStream.call(.empty)
        }
    }

    /// Hands the converter one packet, or reports the end of the stream.
    ///
    /// Called from `AudioConverterFillComplexBuffer`, so it runs on the decode
    /// queue — the same thread as `decodeTick`.
    fileprivate func fillInput(_ packets: UnsafeMutablePointer<UInt32>,
                               _ ioData: UnsafeMutablePointer<AudioBufferList>,
                               _ outDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        guard _packetIndex < _packets.count else {
            // No packets left is a clean end of stream, not an error.
            packets.pointee = 0
            outDescription?.pointee = nil
            return noErr
        }
        let packet = _packets[_packetIndex]
        // The converter dereferences the buffer after this proc returns, so
        // the bytes are copied into storage that outlives the call.
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: packet.count)
        packet.withUnsafeBytes { raw in
            storage.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                           count: packet.count)
        }
        _inputBuffers.append(storage)
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        description.pointee = AudioStreamPacketDescription(mStartOffset: 0,
                                                           mVariableFramesInPacket: 0,
                                                           mDataByteSize: UInt32(packet.count))
        _inputDescriptions.append(description)
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers = AudioBuffer(mNumberChannels: Self.canonical.mChannelsPerFrame,
                                              mDataByteSize: UInt32(packet.count),
                                              mData: storage)
        outDescription?.pointee = description
        packets.pointee = 1
        _packetIndex += 1
        return noErr
    }

    // MARK: - Timer

    private func startTimer() {
        _isStopped = false
        _timer?.resume()
    }

    private func stop() {
        guard !_isStopped else { return }
        _isStopped = true
        _timer?.suspend()
    }

    // MARK: - AudioDecoderCompatible

    public var info: AudioDecoder.Info { _handedOff ? _fallback.info : _info }
    public var outputStream: Delegated<AudioDecoder.Event, Void> { _outputStream }
    public var inputStream: Delegated<AudioDecoder.AudioInput, Void> { _inputStream }

    /// The whole file is buffered and demuxed, so any position is reachable
    /// once the file is open.
    public func seekable() -> Bool {
        if _handedOff { return _fallback.seekable() }
        return _stateQueue.sync { _converter != nil }
    }

    public func prepare(for provider: StreamProviderCompatible,
                        at position: StreamProvider.Position) throws {
        // Only own WebM/Matroska hints; anything else belongs to the fallback.
        guard case let .local(url, hint) = provider.info,
              APlayOpus.handledHints.contains(hint) else {
            _handedOff = true
            return try _fallback.prepare(for: provider, at: position)
        }
        if _handedOff {
            _handedOff = false
            _fallback.pause()
        }
        try openFile(at: url, hint: hint)
    }

    public func pause() {
        guard _converter != nil else { return _fallback.pause() }
        _pendingResume = false
        stop()
    }

    public func resume() {
        guard _converter != nil else {
            _pendingResume = true
            return _fallback.resume()
        }
        guard !_isDestroyed, !_isAtEnd else { return }
        startTimer()
    }

    public func destroy() {
        _isDestroyed = true
        stop()
        closeFile()
        _fallback.destroy()
    }
}

/// A stand-in decoder used when `OpusDecoder` is constructed directly rather
/// than through `APlayOpus.decoder(fallback:)`. Every non-WebM/Matroska URL
/// fails with a parser error instead of being silently mishandled.
private final class UnhandledDecoder: AudioDecoderCompatible {
    var info = AudioDecoder.Info()
    let outputStream = Delegated<AudioDecoder.Event, Void>()
    let inputStream = Delegated<AudioDecoder.AudioInput, Void>()

    init(config: ConfigurationCompatible) {}

    func prepare(for provider: StreamProviderCompatible, at position: StreamProvider.Position) throws {
        let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
        outputStream.call(.error(error))
        throw error
    }
    func pause() {}
    func resume() {}
    func destroy() {}
    func seekable() -> Bool { false }
}

// MARK: - C function-pointer trampoline

/// C function pointers cannot point at Swift instance methods, so the
/// converter's input proc is a module-level function that recovers the decoder
/// from the `userdata` it was handed (an unmanaged reference the converter
/// never retains).
private func opusInputProc(_ converter: AudioConverterRef,
                           _ packets: UnsafeMutablePointer<UInt32>,
                           _ ioData: UnsafeMutablePointer<AudioBufferList>,
                           _ outDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                           _ userdata: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userdata else { return noErr }
    let decoder = Unmanaged<OpusDecoder>.fromOpaque(userdata).takeUnretainedValue()
    return decoder.fillInput(packets, ioData, outDescription)
}
