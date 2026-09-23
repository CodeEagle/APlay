//
//  MidiDecoder.swift
//  APlayMidi
//
//  Optional Standard MIDI File (`.mid` / `.midi` / `.kar`) playback. Core Audio
//  has no MIDI decoder, so this product renders the sequence itself: the file
//  is loaded into an `AVAudioSequencer` and played through an
//  `AVAudioUnitSampler` loaded with a SoundFont (`.sf2`) or DLS (`.dls`) bank,
//  inside an `AVAudioEngine` running in *offline* manual rendering mode. Each
//  tick pulls canonical 16-bit stereo PCM straight out of the engine, so the
//  wrapper fits the same `AudioDecoderCompatible` seam as the other optional
//  codec libraries.
//
//  Add the product only when you need it — plain `APlay` is unchanged:
//  ```swift
//  let config = APlay.Configuration(
//     audioDecoderBuilder: APlayMidi.decoder(
//         fallback: APlay.Configuration().audioDecoderBuilder,
//         soundfont: .file(URL(fileURLWithPath: "/path/to/GeneralUser.sf2")))
//  ```
//

import APlay
import AVFoundation
import CoreAudio

/// Routes `.mid` URLs through the sampler and leaves everything else on the
/// decoder it wraps.
public enum APlayMidi {
    /// The file hints this library owns.
    public static let handledHints: [AudioFileType] = [.midi]

    /// Builds an `audioDecoderBuilder` that routes MIDI files through this
    /// decoder and everything else through a fallback decoder you supply.
    /// `APlay.Configuration().audioDecoderBuilder` is the framework default.
    public static func decoder(fallback: @escaping AudioDecoderBuilder,
                               soundfont: Soundfont = .default) -> AudioDecoderBuilder {
        return { MidiDecoder(config: $0, fallback: fallback($0), soundfont: soundfont) }
    }

    /// A SoundFont/DLS bank the sampler loads for its instruments.
    ///
    /// Core Audio ships no default `.sf2`, so a MIDI file is silent (or a plain
    /// tone) until a bank is supplied. Ship one with your app and point at it,
    /// or leave `.default` for the sampler's built-in fallback.
    public struct Soundfont: Sendable {
        /// `nil` uses the sampler's built-in fallback instrument.
        public let url: URL?
        /// GM program (instrument) number within the bank.
        public let program: UInt8
        /// SF2 bank number; `0` selects the General MIDI melodic bank.
        public let bank: UInt16

        public init(url: URL? = nil, program: UInt8 = 0, bank: UInt16 = 0) {
            self.url = url
            self.program = program
            self.bank = bank
        }

        /// No bank file — the sampler's built-in fallback instrument.
        public static let `default` = Soundfont()
    }
}

/// The pipeline's canonical format: 44.1 kHz, 16-bit signed integer, native
/// endian, packed, stereo. Mirrors `Player.canonical` in the core module (which
/// is not public), so this library renders exactly the PCM the rest of APlay
/// expects.
private let canonicalFormat: AudioStreamBasicDescription = {
    let bytesPerSample = UInt32(MemoryLayout<Int16>.size)
    let flags = CoreAudio.kAudioFormatFlagIsSignedInteger
        | CoreAudio.kAudioFormatFlagsNativeEndian
        | CoreAudio.kAudioFormatFlagIsPacked
    return AudioStreamBasicDescription(
        mSampleRate: 44100,
        mFormatID: CoreAudio.kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: bytesPerSample * 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerSample * 2,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 8 * bytesPerSample,
        mReserved: 0)
}()

private let renderFormat: AVAudioFormat = {
    AVAudioFormat(commonFormat: .pcmFormatInt16,
                  sampleRate: canonicalFormat.mSampleRate,
                  channels: canonicalFormat.mChannelsPerFrame,
                  interleaved: true)!
}()

/// A MIDI decoder backed by `AVAudioSequencer` + `AVAudioUnitSampler`.
///
/// The whole file is buffered, so playback is seekable. The engine renders
/// offline, so no audio device is touched and the work happens on the decode
/// queue like every other decoder in this framework.
public final class MidiDecoder: @unchecked Sendable, AudioDecoderCompatible {

    private unowned let _config: ConfigurationCompatible
    private let _fallback: AudioDecoderCompatible
    private let _soundfont: APlayMidi.Soundfont
    private var _info = AudioDecoder.Info()
    private let _outputStream = Delegated<AudioDecoder.Event, Void>()
    private let _inputStream = Delegated<AudioDecoder.AudioInput, Void>()

    private let _stateQueue = DispatchQueue(label: "APlayMidi.State")
    private let _decodeQueue = DispatchQueue(label: "APlayMidi.Decode", qos: .userInitiated)
    private var _timer: DispatchSourceTimer?
    private var _isStopped = true
    private var _isDestroyed = false
    /// True while a `prepare` was routed to the fallback, so `info`, seekability
    /// and the byte stream follow it instead of this decoder's empty state.
    private var _handedOff = false
    /// Set when `resume` arrives before the file is open; the timer starts
    /// once `prepare` has built the engine.
    private var _pendingResume = false

    private var _engine: AVAudioEngine?
    private var _sequencer: AVAudioSequencer?
    private var _renderBuffer: AVAudioPCMBuffer?
    private var _duration: TimeInterval = 0
    /// Rendered this far past the end before reporting the track exhausted,
    /// so the last note's release tail is not cut.
    private let _tailSeconds: TimeInterval = 0.5
    private let _framesPerTick: AVAudioFrameCount = 4096

    public init(config: ConfigurationCompatible, fallback: AudioDecoderCompatible,
                soundfont: APlayMidi.Soundfont) {
        _config = config
        _fallback = fallback
        _soundfont = soundfont
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

    /// Satisfies `AudioDecoderCompatible.init(config:)`. Direct construction
    /// has no fallback for other formats, so anything that is not MIDI fails
    /// cleanly instead of misbehaving — use `APlayMidi.decoder(fallback:)` to
    /// keep every other format working.
    public convenience init(config: ConfigurationCompatible) {
        self.init(config: config, fallback: UnhandledDecoder(config: config),
                  soundfont: .default)
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
            _sequencer?.stop()
            _engine?.stop()
            _sequencer = nil
            _engine = nil
            _renderBuffer = nil
            _duration = 0
        }
    }

    // MARK: - Opening

    private func openFile(at url: URL, position: StreamProvider.Position,
                          contentLength: UInt) throws {
        guard let data = try? Data(contentsOf: url),
              let smf = SMFFile(data: data) else {
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        closeFile()
        _duration = smf.duration

        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        try engine.enableManualRenderingMode(.offline, format: renderFormat,
                                             maximumFrameCount: _framesPerTick)

        let sequencer = AVAudioSequencer(audioEngine: engine)
        do {
            try sequencer.load(from: url)
        } catch {
            _config.logger.log("AVAudioSequencer could not load \(url.lastPathComponent): \(error)",
                               to: .audioDecoder, method: #function)
            let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(error))
            throw error
        }
        try engine.start()

        if let bankURL = _soundfont.url {
            // A bank is optional, but a failed load must not kill the track:
            // the sampler still renders with its fallback instrument.
            do {
                try sampler.loadSoundBankInstrument(at: bankURL,
                                                    program: _soundfont.program,
                                                    bankMSB: bankMSB,
                                                    bankLSB: bankLSB)
            } catch {
                _config.logger.log("Could not load soundfont \(bankURL.lastPathComponent): \(error)",
                                   to: .audioDecoder, method: #function)
            }
        }

        // The pipeline seeks by byte position; map it back to a fraction of
        // the track and hand the sequencer the equivalent time.
        let progress = contentLength > 0
            ? Double(position) / Double(contentLength)
            : (position > 0 ? 1 : 0)
        let startSeconds = min(max(progress, 0), 1) * _duration
        sequencer.currentPositionInSeconds = startSeconds

        _engine = engine
        _sequencer = sequencer
        _renderBuffer = AVAudioPCMBuffer(pcmFormat: renderFormat,
                                         frameCapacity: _framesPerTick)

        let sampleRate = renderFormat.sampleRate
        let channels = UInt(renderFormat.channelCount)
        let totalFrames = UInt(_duration * sampleRate)
        _info.srcFormat = canonicalFormat
        _info.dstFormat = canonicalFormat
        _info.sampleRate = sampleRate
        _info.audioDataByteCount = totalFrames * channels * 2
        _info.audioDataPacketCount = totalFrames
        _info.dataOffset = 0
        _info.fileHint = .midi
        _info.markAsUpdated()

        if _pendingResume {
            _pendingResume = false
            startTimer()
        }
    }

    /// `AVAudioUnitSampler` selects banks with the MIDI bank-select convention:
    /// MSB 121 (0x79) asks for the General MIDI melodic set, which is where an
    /// SF2 bank 0 lives. Other banks split across MSB/LSB.
    private var bankMSB: UInt8 {
        _soundfont.bank == 0 ? 0x79 : UInt8((_soundfont.bank >> 7) & 0x7F)
    }
    private var bankLSB: UInt8 {
        _soundfont.bank == 0 ? 0 : UInt8(_soundfont.bank & 0x7F)
    }

    // MARK: - Decoding

    private func decodeTick() {
        guard !_isDestroyed,
              let engine = _engine,
              let sequencer = _sequencer,
              let buffer = _renderBuffer else { return }

        do {
            let status = try engine.renderOffline(_framesPerTick, to: buffer)
            guard status == .success else {
                stop()
                outputStream.call(.empty)
                return
            }
            let frameCount = Int(buffer.frameLength)
            if let samples = buffer.int16ChannelData?[0], frameCount > 0 {
                let bytes = frameCount * Int(buffer.format.channelCount)
                    * MemoryLayout<Int16>.size
                outputStream.call(.output((UnsafeRawPointer(samples), UInt32(bytes))))
            }
            // Past the end (plus the release tail) the track is exhausted.
            if sequencer.currentPositionInSeconds >= _duration + _tailSeconds {
                stop()
                outputStream.call(.empty)
            }
        } catch {
            _config.logger.log("offline render failed: \(error)",
                               to: .audioDecoder, method: #function)
            let renderError = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
            outputStream.call(.error(renderError))
            stop()
        }
    }

    // MARK: - Timer

    private func startTimer() {
        _isStopped = false
        do {
            try _sequencer?.start()
        } catch {
            _config.logger.log("AVAudioSequencer failed to start: \(error)",
                               to: .audioDecoder, method: #function)
        }
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

    /// The whole file is buffered and the sequencer is positionable, so a seek
    /// to any time is possible once the file is open.
    public func seekable() -> Bool {
        if _handedOff { return _fallback.seekable() }
        return _stateQueue.sync { _engine != nil }
    }

    public func prepare(for provider: StreamProviderCompatible,
                        at position: StreamProvider.Position) throws {
        // Only own MIDI hints; anything else belongs to the fallback decoder.
        guard case let .local(url, hint) = provider.info,
              APlayMidi.handledHints.contains(hint) else {
            _handedOff = true
            return try _fallback.prepare(for: provider, at: position)
        }
        if _handedOff {
            _handedOff = false
            _fallback.pause()
        }
        try openFile(at: url, position: position, contentLength: provider.contentLength)
    }

    public func pause() {
        guard _engine != nil else { return _fallback.pause() }
        _pendingResume = false
        stop()
    }

    public func resume() {
        guard _engine != nil else {
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

/// A stand-in decoder used when `MidiDecoder` is constructed directly rather
/// than through `APlayMidi.decoder(fallback:)`. Every non-MIDI URL fails with a
/// parser error instead of being silently mishandled.
private final class UnhandledDecoder: AudioDecoderCompatible {
    var info = AudioDecoder.Info()
    let outputStream = Delegated<AudioDecoder.Event, Void>()
    let inputStream = Delegated<AudioDecoder.AudioInput, Void>()

    init(config: ConfigurationCompatible) {}

    func prepare(for provider: StreamProviderCompatible,
                 at position: StreamProvider.Position) throws {
        let error = APlay.Error.parser(kAudioFileUnsupportedDataFormatError)
        outputStream.call(.error(error))
        throw error
    }
    func pause() {}
    func resume() {}
    func destroy() {}
    func seekable() -> Bool { false }
}
