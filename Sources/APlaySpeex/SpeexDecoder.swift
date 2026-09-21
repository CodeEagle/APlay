//
//  SpeexDecoder.swift
//  APlaySpeex
//
//  Optional Speex (`.spx`) decoder. The reference libspeex is vendored as
//  `CAPlaySpeex` (with the Ogg framing layer in `CAPlayOgg`); this wrapper
//  implements `AudioDecoderCompatible` and plugs into the same
//  `audioDecoderBuilder` seam as the other optional libraries.
//  Add the product only when you need it — plain `APlay` is unchanged.
//
//  Wire it once on the configuration:
//  ```swift
//  let config = APlay.Configuration(
//     audioDecoderBuilder: APlaySpeex.decoder(fallback: APlay.Configuration().audioDecoderBuilder))
//  ```
//

import APlay
import CAPlayOgg
import CAPlaySpeex
import AudioToolbox
import CoreAudio
import Foundation

/// Routes `.spx` URLs to the vendored libspeex and leaves everything else on
/// the decoder it wraps.
public enum APlaySpeex {
    /// The file hints this library owns.
    public static let handledHints: [AudioFileType] = [.speex]

    /// Builds an `audioDecoderBuilder` that routes Speex files through this
    /// decoder and everything else through a fallback decoder you supply.
    /// `APlay.Configuration().audioDecoderBuilder` is the framework default.
    public static func decoder(fallback: @escaping AudioDecoderBuilder) -> AudioDecoderBuilder {
        return { SpeexDecoder(config: $0, fallback: fallback($0)) }
    }
}

/// A Speex decoder backed by the vendored libspeex.
///
/// A local `.spx` file is buffered whole. Its Ogg pages are demuxed with
/// libogg and the Speex packets are handed to `speex_decode`, so the decoder is
/// seekable. Live streams are not supported — an Ogg page stream cannot be
/// rewound, and Speex needs its header packet before any audio appears.
public final class SpeexDecoder: @unchecked Sendable, AudioDecoderCompatible {

    private unowned let _config: ConfigurationCompatible
    private let _fallback: AudioDecoderCompatible
    private var _info = AudioDecoder.Info()
    private let _outputStream = Delegated<AudioDecoder.Event, Void>()
    private let _inputStream = Delegated<AudioDecoder.AudioInput, Void>()

    private let _stateQueue = DispatchQueue(label: "APlaySpeex.State")
    private let _decodeQueue = DispatchQueue(label: "APlaySpeex.Decode", qos: .userInitiated)
    private var _timer: DispatchSourceTimer?
    private var _isStopped = true
    private var _isDestroyed = false
    /// Set when `resume` arrives before the file is open; the timer starts once
    /// `prepare` has a context.
    private var _pendingResume = false

    private var _state: UnsafeMutableRawPointer?
    private var _stereoState: UnsafeMutablePointer<SpeexStereoState>?
    private var _bits = SpeexBits()
    private var _oggStream = ogg_stream_state()
    private var _oggSync = ogg_sync_state()
    private var _page = ogg_page()
    private var _packet = ogg_packet()
    fileprivate var _fileData = Data()
    fileprivate var _feedOffset = 0
    private var _sampleRate = 0.0
    private var _srcChannels = 1
    private var _frameSize = 0
    /// `speex_decode_int` writes one frame of interleaved samples per call.
    private var _decodeBuffer = [Int16]()
    private var _outputBuffer = [UInt8]()
    private var _headerParsed = false
    /// The header and the Ogg comment packet precede the first audio packet.
    fileprivate static let firstAudioPacket = 2
    private var _packetsSeen = 0

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

    public init(config: ConfigurationCompatible, fallback: AudioDecoderCompatible) {
        _config = config
        _fallback = fallback
        let timer = DispatchSource.makeTimerSource(flags: [], queue: _decodeQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.decodeTick() }
        _timer = timer
    }

    /// Satisfies `AudioDecoderCompatible.init(config:)`. Direct construction has
    /// no fallback for other formats, so anything that is not Speex fails
    /// cleanly instead of misbehaving — use `APlaySpeex.decoder(fallback:)` to
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
            if let state = _state {
                speex_decoder_destroy(state)
                _state = nil
            }
            if let stereo = _stereoState {
                speex_stereo_state_destroy(stereo)
                _stereoState = nil
            }
            speex_bits_destroy(&_bits)
            ogg_stream_clear(&_oggStream)
            ogg_sync_clear(&_oggSync)
            _fileData.removeAll(keepingCapacity: false)
            _feedOffset = 0
            _headerParsed = false
            _packetsSeen = 0
        }
    }

    // MARK: - Ogg demuxing

    /// Feeds the whole buffered file into libogg's sync buffer once; returning
    /// false means the stream is exhausted.
    private func feedPages() -> Bool {
        let remaining = _fileData.count - _feedOffset
        guard remaining > 0 else { return false }
        let chunk = min(remaining, 8192)
        let written: Int32 = _fileData.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Int32 in
            guard let base = rawBuffer.baseAddress,
                  let buffer = ogg_sync_buffer(&_oggSync, Int(chunk)) else { return -1 }
            memcpy(buffer, base.advanced(by: _feedOffset), chunk)
            return ogg_sync_wrote(&_oggSync, chunk)
        }
        guard written >= 0 else { return false }
        _feedOffset += chunk
        return true
    }

    /// Pulls one packet out of the Ogg stream, buffering more pages as needed.
    private func nextPacket() -> Bool {
        while true {
            let result = ogg_stream_packetout(&_oggStream, &_packet)
            if result == 1 { return true }
            guard result == 0 else { continue }   // a hole; keep pulling
            guard feedPages() else { return false }
            while ogg_sync_pageout(&_oggSync, &_page) == 1 {
                if _oggStream.serialno == 0 {
                    ogg_stream_init(&_oggStream, ogg_page_serialno(&_page))
                }
                // An end-of-stream page still carries audio packets, so it is
                // paged in like any other.
                _ = ogg_stream_pagein(&_oggStream, &_page)
            }
        }
    }
    // MARK: - Opening

    private func openFile(at url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw parserError()
        }
        closeFile()
        _fileData = data

        ogg_sync_init(&_oggSync)
        speex_bits_init(&_bits)

        guard let header = nextPacketHeader() else {
            _config.logger.log("Speex: no header packet",
                               to: .audioDecoder, method: #function)
            throw parserError()
        }

        guard let mode = mode(for: header) else { throw parserError() }
        var rate = header.rate

        _state = speex_decoder_init(mode)
        guard let state = _state else { throw parserError() }
        _ = speex_decoder_ctl(state, SPEEX_SET_SAMPLING_RATE, &rate)
        _stereoState = speex_stereo_state_init()
        _sampleRate = Double(rate)
        _srcChannels = Int(header.nb_channels)
        _headerParsed = true
        _packetsSeen = 1
        if _pendingResume {
            _pendingResume = false
            startTimer()
        }

        var frameSize: Int32 = 0
        _ = speex_decoder_ctl(state, SPEEX_GET_FRAME_SIZE, &frameSize)
        _frameSize = Int(max(frameSize, 1))
        _decodeBuffer = Array(repeating: 0, count: _frameSize * max(_srcChannels, 2))

        _info.srcFormat = AudioStreamBasicDescription(
            mSampleRate: _sampleRate,
            mFormatID: CoreAudio.kAudioFormatLinearPCM,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(_srcChannels),
            mBitsPerChannel: 0, mReserved: 0)
        _info.dstFormat = Self.canonical
        _info.sampleRate = _sampleRate
        _info.audioDataByteCount = UInt(data.count)
        _info.dataOffset = 0
        _info.fileHint = .speex
    }

    /// The parser error every open-time failure reports.
    private func parserError() -> APlay.Error {
        let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
        outputStream.call(.error(error))
        return error
    }

    /// The header's `mode` selects the band (0=narrow, 1=wide, 2=ultra);
    /// `rate` is reported to the decoder as-is, exactly as `speexdec` does.
    private func mode(for header: SpeexHeader) -> UnsafePointer<SpeexMode>? {
        let modeID = header.mode
        guard modeID >= 0, modeID < SPEEX_NB_MODES else {
            _config.logger.log("Speex: unknown mode \(modeID)",
                               to: .audioDecoder, method: #function)
            return nil
        }
        guard let mode = speex_lib_get_mode(modeID),
              mode.pointee.bitstream_version >= header.mode_bitstream_version else {
            return nil
        }
        return mode
    }

    /// Reads and consumes the Speex header packet, returning the parsed fields.
    /// `speex_packet_to_header` handles the endianness conversion.
    private func nextPacketHeader() -> SpeexHeader? {
        guard nextPacket(), let packetBuffer = _packet.packet else { return nil }
        guard let parsed = speex_packet_to_header(packetBuffer, Int32(_packet.bytes)) else {
            return nil
        }
        return parsed.pointee
    }

    // MARK: - Decoding

    private func decodeTick() {
        guard _state != nil, !_isDestroyed else { return }
        _outputBuffer.removeAll(keepingCapacity: true)

        while nextPacket(), let state = _state, let packetBuffer = _packet.packet {
            // The packet after the header is the Ogg comment metadata; Speex
            // audio starts from the third packet.
            if _packetsSeen < SpeexDecoder.firstAudioPacket {
                _packetsSeen += 1
                // The packet after the header is the Ogg comment packet; parse it
                // on the way past — Speex audio starts from the next packet.
                if _packetsSeen == 2 {
                    emitMetadata(from: packetBuffer, length: Int(_packet.bytes))
                }
                continue
            }
            speex_bits_read_from(&_bits, packetBuffer, Int32(_packet.bytes))
            let status = _decodeBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
                speex_decode_int(state, &_bits, buffer.baseAddress)
            }
            guard status >= 0 else { continue }
            if let stereo = _stereoState, _srcChannels == 2 {
                _decodeBuffer.withUnsafeMutableBufferPointer { buffer in
                    speex_decode_stereo_int(buffer.baseAddress, Int32(_frameSize), stereo)
                }
            }
            convertToCanonical(_decodeBuffer, frames: _frameSize)
        }
        guard !_outputBuffer.isEmpty else {
            // Nothing more to deliver: the stream is exhausted.
            stop()
            outputStream.call(.empty)
            return
        }
        _outputBuffer.withUnsafeBytes { rawBuffer in
            outputStream.call(.output((rawBuffer.baseAddress!, UInt32(rawBuffer.count))))
        }
    }

    /// The Ogg comment packet uses the Vorbis comment layout: an optional
    /// `[3]["vorbis"]` prefix, a vendor string, then `KEY=value` fields. Speex
    /// has no library call for it, so it is read by hand on the way past.
    private func emitMetadata(from pointer: UnsafeMutablePointer<UInt8>, length: Int) {
        guard length > 0 else { return }
        let buffer = UnsafeBufferPointer(start: pointer, count: length)
        var offset = 0
        if length >= 7, buffer[0] == 3, "vorbis".utf8.elementsEqual(buffer[1..<7]) {
            offset = 7
        }
        func littleEndian32() -> UInt32? {
            guard offset + 4 <= length else { return nil }
            let value = UInt32(buffer[offset])
                | (UInt32(buffer[offset + 1]) << 8)
                | (UInt32(buffer[offset + 2]) << 16)
                | (UInt32(buffer[offset + 3]) << 24)
            offset += 4
            return value
        }
        guard let vendorLength = littleEndian32(),
              offset + Int(vendorLength) <= length else { return }
        offset += Int(vendorLength)
        guard let fieldCount = littleEndian32() else { return }
        var items: [MetadataParser.Item] = []
        for _ in 0..<fieldCount {
            guard let fieldLength = littleEndian32(),
                  offset + Int(fieldLength) <= length else { return }
            if let field = String(bytes: buffer[offset..<offset + Int(fieldLength)], encoding: .utf8),
               let item = Self.metadataItem(for: field) {
                items.append(item)
            }
            offset += Int(fieldLength)
        }
        if !items.isEmpty {
            outputStream.call(.metadata(items))
        }
    }

    /// Maps one `KEY=value` Vorbis comment field onto a metadata item. Field
    /// names are case-insensitive in the spec (and FFmpeg writes them lower).
    static func metadataItem(for field: String) -> MetadataParser.Item? {
        guard let equal = field.firstIndex(of: "=") else { return nil }
        let key = field[..<equal].uppercased()
        let value = String(field[field.index(after: equal)...])
        switch key {
        case "TITLE": return .title(value)
        case "ARTIST": return .artist(value)
        case "ALBUM": return .album(value)
        case "GENRE": return .genre(value)
        case "TRACKNUMBER", "TRACK": return .track(value)
        case "DATE", "YEAR": return .year(value)
        case "COMMENT", "DESCRIPTION": return .comment(value)
        default: return .other([key: value])
        }
    }

    /// Converts interleaved 16-bit samples to canonical 16-bit stereo PCM,
    /// down/up-mixing channels and resampling to 44.1 kHz when the source
    /// differs, so the pipeline always gets the format it was configured for.
    private func convertToCanonical(_ samples: [Int16], frames: Int) {
        let channels = max(_srcChannels, 1)
        let ratio = _sampleRate / Double(Self.canonical.mSampleRate)

        var srcFrame = 0.0
        for _ in 0..<frames {
            let index = Int(srcFrame) * channels
            guard index + channels <= samples.count else { break }
            var left: Int32 = 0, right: Int32 = 0
            for channel in 0..<channels {
                let value = Int32(samples[index + channel])
                switch channel {
                case 0: left = value
                case 1: right = value
                default: right &+= value
                }
            }
            if channels > 2 { left /= Int32(channels); right /= Int32(channels - 1) }
            if channels == 1 { right = left }
            appendSample(Int16(truncatingIfNeeded: left))
            appendSample(Int16(truncatingIfNeeded: right))
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

    public var info: AudioDecoder.Info { _info }
    public var outputStream: Delegated<AudioDecoder.Event, Void> { _outputStream }
    public var inputStream: Delegated<AudioDecoder.AudioInput, Void> { _inputStream }

    /// The whole file is buffered, so a seek to any position is possible once
    /// the file is open.
    public func seekable() -> Bool {
        _stateQueue.sync { _state != nil }
    }

    public func prepare(for provider: StreamProviderCompatible, at position: StreamProvider.Position) throws {
        // Only own Speex hints; anything else belongs to the fallback decoder.
        guard case let .local(url, hint) = provider.info, APlaySpeex.handledHints.contains(hint) else {
            return try _fallback.prepare(for: provider, at: position)
        }
        try openFile(at: url)
    }

    public func pause() {
        guard _state != nil else { return _fallback.pause() }
        _pendingResume = false
        stop()
    }

    public func resume() {
        guard _state != nil else {
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

/// A stand-in decoder used when `SpeexDecoder` is constructed directly rather
/// than through `APlaySpeex.decoder(fallback:)`. Every non-Speex URL fails with
/// a parser error instead of being silently mishandled.
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
