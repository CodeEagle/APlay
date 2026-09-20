//
//  VorbisDecoder.swift
//  APlayVorbis
//
//  Optional Vorbis (`.ogg`) decoder. The reference libvorbis is vendored as
//  `CAPlayVorbis` (with the Ogg framing layer in `CAPlayOgg`); this wrapper
//  implements `AudioDecoderCompatible` and plugs into the same
//  `audioDecoderBuilder` seam as `APlayExtras` and `APlayWavPack`.
//  Add the product only when you need it — plain `APlay` is unchanged.
//
//  Wire it once on the configuration:
//  ```swift
//  let config = APlay.Configuration(
//     audioDecoderBuilder: APlayVorbis.decoder(fallback: APlay.Configuration().audioDecoderBuilder))
//  ```
//

import APlay
import CAPlayOgg
import CAPlayVorbis
import AudioToolbox
import CoreAudio
import Foundation

/// Routes `.ogg` URLs to the vendored libvorbis and leaves everything else on
/// the decoder it wraps.
public enum APlayVorbis {
    /// The file hints this library owns.
    public static let handledHints: [AudioFileType] = [.ogg]

    /// Builds an `audioDecoderBuilder` that routes Ogg/Vorbis files through this
    /// decoder and everything else through a fallback decoder you supply.
    /// `APlay.Configuration().audioDecoderBuilder` is the framework default.
    public static func decoder(fallback: @escaping AudioDecoderBuilder) -> AudioDecoderBuilder {
        return { VorbisDecoder(config: $0, fallback: fallback($0)) }
    }
}

/// A Vorbis decoder backed by the vendored libvorbis.
///
/// A local `.ogg` file is buffered whole and handed to `ov_open_callbacks`, so
/// the decoder is seekable. Live streams are not supported — an Ogg page stream
/// cannot be reliably rewound, and Vorbis needs its three header packets before
/// any audio can be produced.
public final class VorbisDecoder: @unchecked Sendable, AudioDecoderCompatible {

    private unowned let _config: ConfigurationCompatible
    private let _fallback: AudioDecoderCompatible
    private var _info = AudioDecoder.Info()
    private let _outputStream = Delegated<AudioDecoder.Event, Void>()
    private let _inputStream = Delegated<AudioDecoder.AudioInput, Void>()

    private let _stateQueue = DispatchQueue(label: "APlayVorbis.State")
    private let _decodeQueue = DispatchQueue(label: "APlayVorbis.Decode", qos: .userInitiated)
    private var _timer: DispatchSourceTimer?
    private var _isStopped = true
    private var _isDestroyed = false
    /// Set when `resume` arrives before the file is open; the timer starts once
    /// `prepare` has a context.
    private var _pendingResume = false

    private var _vorbisFile = OggVorbis_File()
    fileprivate var _fileData = Data()
    fileprivate var _readOffset = 0
    private let _callbacks = ov_callbacks(
        read_func: vorbisReadFunc,
        seek_func: vorbisSeekFunc,
        close_func: nil,
        tell_func: vorbisTellFunc)

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

    private static let decodeChannels = 2
    private var _floatBuffer = [Float]()
    private var _outputBuffer = [UInt8]()
    private let _decodeChunk = 4096            // frames per ov_read_float call

    public init(config: ConfigurationCompatible, fallback: AudioDecoderCompatible) {
        _config = config
        _fallback = fallback
        let timer = DispatchSource.makeTimerSource(flags: [], queue: _decodeQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.decodeTick() }
        _timer = timer
    }

    /// Satisfies `AudioDecoderCompatible.init(config:)`. Direct construction has
    /// no fallback for other formats, so anything that is not Ogg/Vorbis fails
    /// cleanly instead of misbehaving — use `APlayVorbis.decoder(fallback:)` to
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
            // `ov_clear` is a no-op on an uninitialised struct, but the state
            // queue keeps the close ordered against an in-flight decode tick.
            if _isOpen {
                ov_clear(&_vorbisFile)
            }
            _fileData.removeAll(keepingCapacity: false)
            _readOffset = 0
        }
    }

    private var _isOpen: Bool { _vorbisFile.vi != nil }

    // MARK: - ov_callbacks

    /// Copies out of the buffered file; called from libvorbis's read path.
    /// `size * nmemb` is the requested byte count, mirroring `fread`.
    fileprivate func read(into ptr: UnsafeMutableRawPointer?, size: Int, nmemb: Int) -> Int {
        let count = size * nmemb
        let available = _fileData.count - _readOffset
        let toCopy = min(count, available)
        guard toCopy > 0 else { return 0 }
        _fileData.withUnsafeBytes { rawBuffer in
            let source = rawBuffer.baseAddress!.advanced(by: _readOffset)
            ptr?.copyMemory(from: source, byteCount: toCopy)
        }
        _readOffset += toCopy
        return toCopy
    }

    /// `fseek` semantics: 0 = absolute, 1 = relative, 2 = from the end.
    fileprivate func seek(offset: Int64, whence: Int32) -> Int32 {
        var base = 0
        switch whence {
        case 1: base = _readOffset
        case 2: base = _fileData.count
        default: base = 0
        }
        let target = Int(offset) + base
        guard target >= 0, target <= _fileData.count else { return -1 }
        _readOffset = target
        return 0
    }

    fileprivate func tell() -> Int64 { Int64(_readOffset) }

    // MARK: - Opening

    private func openFile(at url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        closeFile()
        _fileData = data

        // libvorbis keeps no reference to the datasource beyond the callbacks,
        // so the decoder itself is the `datasource` pointer.
        let myself = Unmanaged.passUnretained(self).toOpaque()
        let status = withUnsafeMutablePointer(to: &_vorbisFile) { filePtr in
            ov_open_callbacks(myself, filePtr, nil, 0, _callbacks)
        }
        guard status == 0 else {
            _config.logger.log("ov_open_callbacks failed: \(status)",
                               to: .audioDecoder, method: #function)
            _vorbisFile = OggVorbis_File()
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        if _pendingResume {
            _pendingResume = false
            startTimer()
        }

        guard let info = ov_info(&_vorbisFile, -1)?.pointee else {
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        let sampleRate = Double(info.rate)
        let channels = max(Int(info.channels), 1)
        _floatBuffer = Array(repeating: 0, count: _decodeChunk * channels)

        _info.srcFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: CoreAudio.kAudioFormatLinearPCM,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        _info.dstFormat = Self.canonical
        _info.sampleRate = sampleRate
        _info.audioDataByteCount = UInt(data.count)
        _info.dataOffset = 0
        _info.fileHint = .ogg
    }

    // MARK: - Decoding

    private func decodeTick() {
        guard _isOpen, !_isDestroyed else { return }
        _outputBuffer.removeAll(keepingCapacity: true)

        // One call fills at most `_decodeChunk` frames per channel; the loop
        // keeps the callback running until a full chunk is gathered.
        var totalFrames = 0
        while totalFrames < _decodeChunk {
            var pcm: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
            let frames = withUnsafeMutablePointer(to: &pcm) { pcmPtr in
                ov_read_float(&_vorbisFile, pcmPtr,
                              Int32(_decodeChunk - totalFrames), nil)
            }
            guard frames > 0, let channelBuffers = pcm else { break }
            convertToCanonical(channelBuffers, frames: Int(frames))
            totalFrames += Int(frames)
        }

        guard totalFrames > 0 else {
            // Nothing more to deliver: the stream is exhausted.
            stop()
            outputStream.call(.empty)
            return
        }
        _outputBuffer.withUnsafeBytes { rawBuffer in
            outputStream.call(.output((rawBuffer.baseAddress!, UInt32(rawBuffer.count))))
        }
    }

    /// Converts libvorbis's non-interleaved per-channel float output to
    /// canonical 16-bit stereo PCM, down/up-mixing channels and resampling to
    /// 44.1 kHz when the source differs, so the pipeline always gets the
    /// format it was configured for.
    private func convertToCanonical(
        _ channelBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
        frames: Int) {
        let channels = _info.srcFormat.mChannelsPerFrame > 0
            ? Int(_info.srcFormat.mChannelsPerFrame)
            : Self.decodeChannels
        let ratio = _info.sampleRate / Double(Self.canonical.mSampleRate)

        var srcFrame = 0.0
        for _ in 0..<frames {
            let index = Int(srcFrame)
            guard index < frames else { break }
            var left: Float = 0, right: Float = 0
            for channel in 0..<channels {
                guard let buffer = channelBuffers[channel] else { continue }
                let value = buffer[index]
                switch channel {
                case 0: left = value
                case 1: right = value
                default: right += value
                }
            }
            if channels > 2 { left /= Float(channels); right /= Float(channels - 1) }
            if channels == 1 { right = left }
            appendSample(left)
            appendSample(right)
            srcFrame += ratio
        }
    }

    private func appendSample(_ value: Float) {
        // Vorbis float output is already in [-1, 1]; clamp before scaling.
        let scaled = Int16(max(min(value, 1), -1) * 32767)
        var little = scaled.littleEndian
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

    public var info: AudioDecoder.Info { _info }
    public var outputStream: Delegated<AudioDecoder.Event, Void> { _outputStream }
    public var inputStream: Delegated<AudioDecoder.AudioInput, Void> { _inputStream }

    /// The whole file is buffered, so a seek to any position is possible once
    /// the file is open.
    public func seekable() -> Bool {
        _stateQueue.sync { _isOpen }
    }

    public func prepare(for provider: StreamProviderCompatible, at position: StreamProvider.Position) throws {
        // Only own Ogg hints; anything else belongs to the fallback decoder.
        guard case let .local(url, hint) = provider.info, APlayVorbis.handledHints.contains(hint) else {
            return try _fallback.prepare(for: provider, at: position)
        }
        try openFile(at: url)
    }

    public func pause() {
        guard _isOpen else { return _fallback.pause() }
        _pendingResume = false
        stop()
    }

    public func resume() {
        guard _isOpen else {
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

/// A stand-in decoder used when `VorbisDecoder` is constructed directly rather
/// than through `APlayVorbis.decoder(fallback:)`. Every non-Ogg URL fails with a
/// parser error instead of being silently mishandled.
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

/// C function pointers cannot point at Swift instance methods, so the
/// `ov_callbacks` are module-level functions that recover the decoder from the
/// `datasource` pointer (an unmanaged reference; libvorbis never retains it).
private func vorbisDecoder(from datasource: UnsafeMutableRawPointer?) -> VorbisDecoder? {
    guard let datasource else { return nil }
    return Unmanaged<VorbisDecoder>.fromOpaque(datasource).takeUnretainedValue()
}

private func vorbisReadFunc(_ ptr: UnsafeMutableRawPointer?,
                            _ size: Int,
                            _ nmemb: Int,
                            _ datasource: UnsafeMutableRawPointer?) -> Int {
    vorbisDecoder(from: datasource)?.read(into: ptr, size: size, nmemb: nmemb) ?? 0
}

private func vorbisSeekFunc(_ datasource: UnsafeMutableRawPointer?,
                            _ offset: ogg_int64_t,
                            _ whence: Int32) -> Int32 {
    vorbisDecoder(from: datasource)?.seek(offset: offset, whence: whence) ?? -1
}

private func vorbisTellFunc(_ datasource: UnsafeMutableRawPointer?) -> Int {
    Int(vorbisDecoder(from: datasource)?.tell() ?? 0)
}
