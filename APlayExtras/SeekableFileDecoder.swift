//
//  SeekableFileDecoder.swift
//  APlayExtras
//
//  Part of the optional `APlayExtras` library: decodes local, seekable files
//  whose containers the framework's streaming decoder cannot handle.
//

import APlay
import AudioToolbox
import CoreAudio
import Foundation

/// Decodes local files through the file-based `ExtAudioFile` API.
///
/// The framework's built-in `DefaultAudioDecoder` is a *streaming* decoder: it
/// drives `AudioFileStream`, which cannot cope with two container shapes even
/// though Core Audio decodes their payload just fine:
///
/// - ALAC in a CAF container keeps its packet table after the audio data, so the
///   streaming parser reports `optm` ("not optimised") and never hands the
///   converter a usable packet description.
/// - AIFF / AIFF-C PCM makes `AudioFileStream` report a packet discontinuity
///   (`dsc!`) and decode nothing at all.
///
/// Opening the same file with `ExtAudioFileOpenURL` reads the packet table up
/// front, so both shapes decode. The trade-off is in the name: it needs a
/// seekable local file and cannot work on a live stream. `FileFallbackDecoder`
/// routes only local CAF/AIFF/AIFF-C URLs here and leaves everything else on the
/// built-in streaming path.
public final class SeekableFileDecoder: @unchecked Sendable {

    /// Container hints this decoder handles. Everything else is a job for the
    /// built-in streaming decoder.
    public static let handledHints: [AudioFileType] = [.caf, .aiff, .aifc]

    private unowned let _config: ConfigurationCompatible
    private var _info = AudioDecoder.Info()
    private let _inputStream = Delegated<AudioDecoder.AudioInput, Void>()
    private let _outputStream = Delegated<AudioDecoder.Event, Void>()

    /// The pipeline's canonical output format: 44.1 kHz, stereo, 16-bit signed
    /// native-endian packed PCM. Mirrors the internal `Player.canonical` that the
    /// built-in decoder converts every compressed format to; duplicated here
    /// because that constant is not public.
    private static let canonical: AudioStreamBasicDescription = {
        let bytesPerSample = UInt32(MemoryLayout<Int16>.size)
        let flags = CoreAudio.kAudioFormatFlagIsSignedInteger | CoreAudio.kAudioFormatFlagsNativeEndian | CoreAudio.kAudioFormatFlagIsPacked
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

    private let _stateQueue = DispatchQueue(label: "APlayExtras.SeekableFileDecoder.State")
    private let _decodeQueue = DispatchQueue(label: "APlayExtras.SeekableFileDecoder.Decode", qos: .userInitiated)
    private var _timer: DispatchSourceTimer?
    private var _isStopped = true
    private var _isDestroyed = false

    private var _extFile: ExtAudioFileRef?
    private var _clientFormat = AudioStreamBasicDescription()
    private var _srcFormat = AudioStreamBasicDescription()
    private var _isLinearPCM = false
    private var _totalFrames: Int64 = 0
    private var _nextFrame: Int64 = 0
    private var _readBuffer: [UInt8] = []

    public init(config: ConfigurationCompatible) {
        _config = config
        // Never hand Core Audio a buffer smaller than one canonical frame.
        _readBuffer = Array(repeating: 0,
                            count: max(Int(config.decodeBufferSize),
                                       Int(Self.canonical.mBytesPerFrame)))
        let timer = DispatchSource.makeTimerSource(flags: [], queue: _decodeQueue)
        timer.schedule(deadline: .now() + .milliseconds(30), repeating: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.decodeTick() }
        // A dispatch source starts suspended, so the bookkeeping starts "stopped".
        _timer = timer
    }

    deinit {
        // Reading `_isStopped` inline is safe: deinit has exclusive access, so no
        // pause/resume or timer handler can be racing it. Syncing to the state
        // queue here instead would deadlock whenever the last release happens on
        // that queue itself.
        _timer?.setEventHandler(handler: nil)
        _timer?.cancel()
        if _isStopped { _timer?.resume() }
        disposeFile()
    }

    // MARK: - File lifecycle

    private func disposeFile() {
        _stateQueue.sync {
            if let file = _extFile {
                ExtAudioFileDispose(file)
                _extFile = nil
            }
        }
    }

    private func openFile(at url: URL) throws -> ExtAudioFileRef {
        var file: ExtAudioFileRef?
        let status = ExtAudioFileOpenURL(url as NSURL, &file)
        guard status == noErr, let opened = file else {
            _config.logger.log("ExtAudioFileOpenURL failed with \(status)", to: .audioDecoder, method: #function)
            throw APlay.Error.parser(status)
        }
        return opened
    }
}

// MARK: - AudioDecoderCompatible

extension SeekableFileDecoder: AudioDecoderCompatible {

    public var info: AudioDecoder.Info { _info }
    public var outputStream: Delegated<AudioDecoder.Event, Void> { _outputStream }
    public var inputStream: Delegated<AudioDecoder.AudioInput, Void> { _inputStream }

    /// A local file is seekable by nature; non-nil storage means `prepare` has
    /// already read the formats, which is what the pipeline is really asking.
    public func seekable() -> Bool {
        return _stateQueue.sync { _extFile != nil }
    }

    public func prepare(for provider: StreamProviderCompatible, at position: StreamProvider.Position) throws {
        guard case let .local(url, hint) = provider.info else {
            // A stream (or an unknown URL) has no packet table to read. Report it
            // so the router can fall back instead of failing silently.
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        disposeFile()
        if position == 0 { _info = AudioDecoder.Info() }
        _info.fileHint = hint

        let file = try openFile(at: url)
        var srcFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = withUnsafeMutablePointer(to: &srcFormat) { ptr in
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, ptr)
        }
        guard status == noErr else {
            let error = APlay.Error.parser(status)
            outputStream.call(.error(error))
            throw error
        }
        _srcFormat = srcFormat
        _isLinearPCM = srcFormat.mFormatID == CoreAudio.kAudioFormatLinearPCM

        // Linear PCM is passed through untouched, exactly as the built-in decoder
        // does for WAVE: the pipeline renders the source format directly, so no
        // conversion (and no resampling) happens. Everything else is converted to
        // the canonical format the ring buffer and audio unit expect.
        var clientFormat = _isLinearPCM ? srcFormat : Self.canonical
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = withUnsafeMutablePointer(to: &clientFormat) { ptr in
            ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, ptr)
        }
        guard status == noErr else {
            let error = APlay.Error.parser(status)
            outputStream.call(.error(error))
            throw error
        }
        _clientFormat = clientFormat

        var totalFrames = Int64(0)
        size = UInt32(MemoryLayout<Int64>.size)
        status = withUnsafeMutablePointer(to: &totalFrames) { ptr in
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, ptr)
        }
        // When the frame count is unavailable, leave it at 0 and let
        // `ExtAudioFileRead` report end-of-data itself.
        _totalFrames = (status == noErr) ? totalFrames : 0
        _nextFrame = 0

        _info.srcFormat = srcFormat
        _info.dstFormat = clientFormat
        _info.sampleRate = srcFormat.mSampleRate
        _info.packetDuration = srcFormat.mFramesPerPacket > 0
            ? Double(srcFormat.mFramesPerPacket) / srcFormat.mSampleRate
            : 0
        _info.packetBufferSize = srcFormat.mBytesPerPacket
        // The whole file is the data; Composer derives seeks from the content
        // length, so a byte count keeps that arithmetic consistent.
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        _info.audioDataByteCount = UInt(fileSize)
        _info.audioDataPacketCount = srcFormat.mFramesPerPacket > 0
            ? UInt(_totalFrames) / UInt(srcFormat.mFramesPerPacket)
            : UInt(_totalFrames)
        let duration = srcFormat.mSampleRate > 0
            ? Double(_totalFrames) / srcFormat.mSampleRate
            : 0
        if duration > 0 {
            // Average bitrate including the container: display-only, duration has
            // the exact packet-count path above to lean on.
            _info.bitrate = UInt32(Double(fileSize) * 8 / duration)
        }
        _info.markAsUpdated()

        _stateQueue.sync { _extFile = file }

        outputStream.call(.seekable(true))
        if _info.bitrate > 0 { outputStream.call(.bitrate(_info.bitrate)) }

        if position > 0 { seek(toByte: position) }
    }

    public func pause() {
        _stateQueue.sync {
            guard _isStopped == false, let timer = _timer else { return }
            timer.suspend()
            _isStopped = true
        }
    }

    public func resume() {
        _stateQueue.sync {
            guard _isDestroyed == false, _isStopped, let timer = _timer else { return }
            timer.resume()
            _isStopped = false
        }
    }

    public func destroy() {
        _stateQueue.sync {
            _isDestroyed = true
            if _isStopped == false, let timer = _timer {
                timer.suspend()
                _isStopped = true
            }
            if let file = _extFile {
                ExtAudioFileDispose(file)
                _extFile = nil
            }
        }
        _timer?.setEventHandler(handler: nil)
        _timer?.cancel()
    }
}

// MARK: - Decode

private extension SeekableFileDecoder {

    func decodeTick() {
        guard _stateQueue.sync(execute: { _isDestroyed }) == false else { return }
        guard let file = _stateQueue.sync(execute: { _extFile }) else { return }
        guard _clientFormat.mBytesPerFrame > 0 else { return }

        if _totalFrames > 0, _nextFrame >= _totalFrames {
            // Everything has been converted. Report empty so the pipeline drains
            // and ends the track, mirroring the built-in decoder's idle tick.
            outputStream.call(.empty)
            return
        }

        let capacity = UInt32(_readBuffer.count)
        var frames = capacity / _clientFormat.mBytesPerFrame
        guard frames > 0 else { return }
        if _totalFrames > 0 {
            let remaining = UInt32(_totalFrames - _nextFrame)
            if frames > remaining { frames = remaining }
        }

        var numFrames = frames
        let status = _readBuffer.withUnsafeMutableBufferPointer { bufferPtr -> OSStatus in
            guard let base = bufferPtr.baseAddress else { return kAudio_ParamError }
            var bufferList = AudioBufferList(mNumberBuffers: 1,
                                             mBuffers: AudioBuffer(mNumberChannels: _clientFormat.mChannelsPerFrame,
                                                                   mDataByteSize: capacity,
                                                                   mData: UnsafeMutableRawPointer(base)))
            return ExtAudioFileRead(file, &numFrames, &bufferList)
        }
        guard status == noErr else {
            outputStream.call(.error(.parser(status)))
            return
        }
        guard numFrames > 0 else {
            outputStream.call(.empty)
            return
        }
        _nextFrame += Int64(numFrames)
        let bytes = numFrames * _clientFormat.mBytesPerFrame
        _readBuffer.withUnsafeBufferPointer { bufferPtr in
            guard let base = bufferPtr.baseAddress else { return }
            // The delegate copies synchronously, so the pointer is valid for the
            // whole call — same contract the built-in decoder relies on.
            outputStream.call(.output((UnsafeRawPointer(base), bytes)))
        }
    }

    /// Maps a pipeline byte offset onto a frame and seeks the file.
    func seek(toByte position: StreamProvider.Position) {
        guard let file = _stateQueue.sync(execute: { _extFile }), _totalFrames > 0 else { return }
        let frame: Int64
        if _isLinearPCM, _srcFormat.mBytesPerFrame > 0 {
            // Exact for PCM: a frame *is* a fixed number of bytes.
            frame = Int64(position) / Int64(_srcFormat.mBytesPerFrame)
        } else if _info.audioDataByteCount > 0 {
            // Approximate for VBR: the offset is itself a fraction of the file, so
            // a proportional mapping lands in the right neighbourhood and the
            // converter resyncs from there.
            let fraction = Float(position) / Float(_info.audioDataByteCount)
            frame = Int64(fraction * Float(_totalFrames))
        } else {
            return
        }
        let clamped = max(0, min(frame, _totalFrames))
        ExtAudioFileSeek(file, clamped)
        _nextFrame = clamped
    }
}
