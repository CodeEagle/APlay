//
//  WavPackDecoder.swift
//  APlayWavPack
//
//  Optional WavPack (`.wv`) decoder. The C library is vendored as the
//  `CAPlayWavPack` target; this wrapper implements `AudioDecoderCompatible`
//  and plugs into the same `audioDecoderBuilder` seam as `APlayExtras`.
//  Add the product only when you need it — plain `APlay` is unchanged.
//
//  Wire it once on the configuration:
//  ```swift
//  let config = APlay.Configuration(
//     audioDecoderBuilder: APlayWavPack.decoder(fallback: APlay.Configuration().audioDecoderBuilder))
//  ```
//

import APlay
import CAPlayWavPack
import AudioToolbox
import CoreAudio
import Foundation

/// Routes `.wv` URLs to the vendored WavPack library and leaves everything else
/// on the decoder it wraps.
public enum APlayWavPack {
    /// The file hints this library owns.
    public static let handledHints: [AudioFileType] = [.wavpack]

    /// Builds an `audioDecoderBuilder` that routes WavPack files through this
    /// decoder and everything else through a fallback decoder you supply.
    /// `APlay.Configuration().audioDecoderBuilder` is the framework default.
    public static func decoder(fallback: @escaping AudioDecoderBuilder) -> AudioDecoderBuilder {
        return { WavPackDecoder(config: $0, fallback: fallback($0)) }
    }
}

/// A WavPack decoder backed by the vendored C library.
///
/// A local `.wv` file is buffered whole and handed to the library through its
/// stream-reader callbacks, so the decoder is seekable. Live streams are not
/// supported — WavPack's framing is not a streaming format and a stream cannot
/// be seeked.
public final class WavPackDecoder: @unchecked Sendable, AudioDecoderCompatible {

    private unowned let _config: ConfigurationCompatible
    private let _fallback: AudioDecoderCompatible
    private var _info = AudioDecoder.Info()
    private let _outputStream = Delegated<AudioDecoder.Event, Void>()
    private let _inputStream = Delegated<AudioDecoder.AudioInput, Void>()

    private let _stateQueue = DispatchQueue(label: "APlayWavPack.State")
    private let _decodeQueue = DispatchQueue(label: "APlayWavPack.Decode", qos: .userInitiated)
    private var _timer: DispatchSourceTimer?
    private var _isStopped = true
    private var _isDestroyed = false
    /// Set when `resume` arrives before the file is open; the timer starts
    /// once `prepare` has a context.
    private var _pendingResume = false

    private var _context: OpaquePointer?
    fileprivate var _fileData = Data()
    fileprivate var _readOffset = 0
    private var _reader = WavpackStreamReader64(
        read_bytes: nil, write_bytes: nil, get_pos: nil,
        set_pos_abs: nil, set_pos_rel: nil, push_back_byte: nil,
        get_length: nil, can_seek: nil, truncate_here: nil, close: nil)

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

    private var _unpackBuffer: [Int32] = []
    private var _outputBuffer = [UInt8]()
    private let _unpackChunk = 4096            // interleaved samples per unpack call
    private var _srcChannels = 1

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

    /// True while a `prepare` was routed to the fallback, so `info`, seekability
    /// and the byte stream follow it instead of this decoder's empty state.
    private var _handedOff = false

    /// Satisfies `AudioDecoderCompatible.init(config:)`. Direct construction has
    /// no fallback for other formats, so anything that is not WavPack fails
    /// cleanly instead of misbehaving — use `APlayWavPack.decoder(fallback:)` to
    /// keep every other format working.
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
            if let context = _context {
                WavpackCloseFile(context)
                _context = nil
            }
            _fileData.removeAll(keepingCapacity: false)
            _readOffset = 0
        }
    }

    // MARK: - WavpackStreamReader64 callbacks

    /// Copies out of the buffered file; called from the library's read path.
    fileprivate func readBytes(_ data: UnsafeMutableRawPointer, count: Int) -> Int32 {
        let available = _fileData.count - _readOffset
        let toCopy = min(count, available)
        guard toCopy > 0 else { return 0 }
        _fileData.withUnsafeBytes { rawBuffer in
            let source = rawBuffer.baseAddress!.advanced(by: _readOffset)
            data.copyMemory(from: source, byteCount: toCopy)
        }
        _readOffset += toCopy
        return Int32(toCopy)
    }

    // MARK: - Opening

    private func openFile(at url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        closeFile()
        _fileData = data

        let myself = Unmanaged.passUnretained(self).toOpaque()
        _reader.read_bytes = wavpackReadBytes
        _reader.get_pos = wavpackGetPos
        _reader.set_pos_abs = wavpackSetPosAbs
        _reader.set_pos_rel = wavpackSetPosRel
        _reader.push_back_byte = wavpackPushBackByte
        _reader.get_length = wavpackGetLength
        _reader.can_seek = wavpackCanSeek
        _reader.truncate_here = wavpackTruncateHere
        _reader.close = wavpackClose

        var errorText = [CChar](repeating: 0, count: 256)
        let context = withUnsafeMutablePointer(to: &_reader) { readerPtr in
            errorText.withUnsafeMutableBufferPointer { errorPtr in
                WavpackOpenFileInputEx64(readerPtr, myself, nil, errorPtr.baseAddress, 0, 0)
            }
        }
        guard let context else {
            _config.logger.log("WavpackOpenFileInputEx64 failed: \(String(cString: errorText))",
                               to: .audioDecoder, method: #function)
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        _context = context

        let sampleRate = WavpackGetSampleRate(context)
        let channels = max(Int(WavpackGetNumChannels(context)), 1)
        _srcChannels = channels
        // The library writes `frames * channels` int32s for a `frames` request.
        _unpackBuffer = Array(repeating: 0, count: _unpackChunk * channels)

        _info.srcFormat = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: CoreAudio.kAudioFormatLinearPCM,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        _info.dstFormat = Self.canonical
        _info.sampleRate = Double(sampleRate)
        _info.audioDataByteCount = UInt(data.count)
        _info.dataOffset = 0
        _info.fileHint = .wavpack

        // The APEv2 trailer is read straight off the buffered file; the library
        // exposes it through WavpackGetTagItem, but that touches a NULL
        // ape_tag_data on files without a tag, so the bytes are parsed here.
        // Emitted before the timer starts so Now Playing data precedes the PCM.
        emitMetadata()

        // The timer is started last: `decodeTick` unpacks into
        // `_unpackBuffer` and reads `_info`, so both must exist first — an
        // earlier start had the library write 16 KB into an empty array.
        if _pendingResume {
            _pendingResume = false
            startTimer()
        }
    }

    /// The APEv2 trailer (where FFmpeg writes title/artist/album) is parsed
    /// out of the buffered file and surfaced before any audio.
    private func emitMetadata() {
        guard let items = APEv2TagParser.parse(_fileData), !items.isEmpty else { return }
        outputStream.call(.metadata(items))
    }

    // MARK: - Decoding

    private func decodeTick() {
        guard let context = _context, !_isDestroyed else { return }
        _outputBuffer.removeAll(keepingCapacity: true)

        // The count is per-channel frames; the buffer holds frames * channels.
        let unpacked = WavpackUnpackSamples(context, &_unpackBuffer, UInt32(_unpackChunk))
        guard unpacked > 0 else {
            // Nothing more to deliver: the file is exhausted.
            stop()
            outputStream.call(.empty)
            return
        }
        _unpackBuffer.withUnsafeBufferPointer { buffer in
            convertToCanonical(buffer.baseAddress!, count: Int(unpacked))
        }
        _outputBuffer.withUnsafeBytes { rawBuffer in
            outputStream.call(.output((rawBuffer.baseAddress!, UInt32(rawBuffer.count))))
        }
    }

    /// Converts interleaved int32 samples to canonical 16-bit stereo PCM,
    /// down/up-mixing channels and resampling to 44.1 kHz when the source
    /// differs, so the pipeline always gets the format it was configured for.
    /// 16-bit sources arrive left-aligned in the int32 range, so the high half
    /// carries the payload.
    private func convertToCanonical(_ samples: UnsafePointer<Int32>, count: Int) {
        let channels = _srcChannels
        let frames = count / channels
        let ratio = _info.sampleRate / Double(Self.canonical.mSampleRate)

        var srcFrame = 0.0
        for _ in 0..<frames {
            let index = Int(srcFrame) * channels
            if index + channels <= count {
                var left = 0, right = 0
                for channel in 0..<channels {
                    let value = samples[index + channel]
                    switch channel {
                    case 0: left = Int(value)
                    case 1: right = Int(value)
                    default: right &+= Int(value)
                    }
                }
                if channels > 2 { left /= channels; right /= (channels - 1) }
                if channels == 1 { right = left }
                appendSample(Int16(truncatingIfNeeded: left >> 16))
                appendSample(Int16(truncatingIfNeeded: right >> 16))
            }
            srcFrame += ratio
        }
    }

    private func appendSample(_ value: Int16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { _outputBuffer.append(contentsOf: $0) }
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

    /// The whole file is buffered, so a seek to any position is possible once
    /// the file is open.
    public func seekable() -> Bool {
        if _handedOff { return _fallback.seekable() }
        return _stateQueue.sync { _context != nil }
    }

    public func prepare(for provider: StreamProviderCompatible, at position: StreamProvider.Position) throws {
        // Only own WavPack hints; anything else belongs to the fallback decoder.
        guard case let .local(url, hint) = provider.info, APlayWavPack.handledHints.contains(hint) else {
            _handedOff = true
            return try _fallback.prepare(for: provider, at: position)
        }
        if _handedOff {
            _handedOff = false
            _fallback.pause()
        }
        try openFile(at: url)
    }

    public func pause() {
        guard _context != nil else { return _fallback.pause() }
        _pendingResume = false
        stop()
    }

    public func resume() {
        guard _context != nil else {
            _pendingResume = true
            return _fallback.resume()
        }
        guard !_isDestroyed else { return }
        startTimer()
    }

    public func destroy() {
        _isDestroyed = true
        stop()
        closeFile()
        _fallback.destroy()
    }
}

/// A stand-in decoder used when `WavPackDecoder` is constructed directly rather
/// than through `APlayWavPack.decoder(fallback:)`. Every non-WavPack URL fails
/// with a parser error instead of being silently mishandled.
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

// MARK: - C function-pointer trampolines

/// C function pointers cannot point at Swift instance methods, so the reader
/// callbacks are module-level functions that recover the decoder from the
/// reader `id` (an unmanaged reference; the library never retains it).
private func wavpackDecoder(from id: UnsafeMutableRawPointer?) -> WavPackDecoder? {
    guard let id else { return nil }
    return Unmanaged<WavPackDecoder>.fromOpaque(id).takeUnretainedValue()
}

private func wavpackReadBytes(_ id: UnsafeMutableRawPointer?,
                              _ data: UnsafeMutableRawPointer?,
                              _ bcount: Int32) -> Int32 {
    guard let mine = wavpackDecoder(from: id), let data else { return 0 }
    return mine.readBytes(data, count: Int(bcount))
}

private func wavpackGetPos(_ id: UnsafeMutableRawPointer?) -> Int64 {
    Int64(wavpackDecoder(from: id)?._readOffset ?? 0)
}

private func wavpackSetPosAbs(_ id: UnsafeMutableRawPointer?, _ pos: Int64) -> Int32 {
    guard let mine = wavpackDecoder(from: id) else { return -1 }
    if pos < 0 || pos > mine._fileData.count { return -1 }
    mine._readOffset = Int(pos)
    return 0
}

private func wavpackGetLength(_ id: UnsafeMutableRawPointer?) -> Int64 {
    Int64(wavpackDecoder(from: id)?._fileData.count ?? 0)
}

private func wavpackSetPosRel(_ id: UnsafeMutableRawPointer?, _ delta: Int64, _ mode: Int32) -> Int32 {
    guard let mine = wavpackDecoder(from: id) else { return -1 }
    // mode mirrors fseek: 0 = relative to the file start, 1 = relative to the
    // current position, 2 = relative to the end.
    var base: Int64 = 0
    switch mode {
    case 1: base = Int64(mine._readOffset)
    case 2: base = Int64(mine._fileData.count)
    default: base = 0
    }
    let target = base + delta
    guard target >= 0, target <= Int64(mine._fileData.count) else { return -1 }
    mine._readOffset = Int(target)
    return 0
}

private func wavpackPushBackByte(_ id: UnsafeMutableRawPointer?, _ byte: Int32) -> Int32 {
    guard let mine = wavpackDecoder(from: id), mine._readOffset > 0 else { return -1 }
    mine._readOffset -= 1
    return Int32(mine._fileData[mine._readOffset])
}

/// The wrapper never writes tags, so truncation and closing are no-ops.
/// The whole file is buffered, so every position is reachable.
private func wavpackCanSeek(_ id: UnsafeMutableRawPointer?) -> Int32 {
    wavpackDecoder(from: id) != nil ? 1 : 0
}

/// The wrapper never writes tags, so truncation and closing are no-ops.
private func wavpackTruncateHere(_ id: UnsafeMutableRawPointer?) -> Int32 { 0 }

private func wavpackClose(_ id: UnsafeMutableRawPointer?) -> Int32 { 0 }
