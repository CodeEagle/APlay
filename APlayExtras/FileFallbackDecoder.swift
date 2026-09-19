//
//  FileFallbackDecoder.swift
//  APlayExtras
//
//  Routes local CAF/AIFF/AIFF-C files to `SeekableFileDecoder` and leaves
//  everything else on a decoder you supply (normally the framework's built-in
//  streaming decoder).
//

import APlay
import AudioToolbox
import Foundation

/// A drop-in `AudioDecoderCompatible` that adds support for the containers the
/// framework's streaming decoder cannot open, without changing how any other
/// format plays back.
///
/// The framework hands a decoder the streamer and the URL's file hint at
/// `prepare` time, which is also the first moment the container is known — so
/// the routing happens there. `readyForRead` is always posted before the first
/// byte arrives, which means the right decoder exists before any data flows.
///
/// Wire it once on the configuration:
/// ```swift
/// let config = APlay.Configuration()
/// config.audioDecoderBuilder = APlayExtras.fileDecoder(fallback: config.audioDecoderBuilder)
/// ```
public final class FileFallbackDecoder: @unchecked Sendable {

    private unowned let _config: ConfigurationCompatible
    private let _fallback: (ConfigurationCompatible) -> AudioDecoderCompatible
    private let _lock = NSLock()
    private var _active: AudioDecoderCompatible?
    private var _pendingResume = false
    private let _ownInfo = AudioDecoder.Info()
    private let _inputStream = Delegated<AudioDecoder.AudioInput, Void>()
    private let _outputStream = Delegated<AudioDecoder.Event, Void>()

    public init(config: ConfigurationCompatible,
                fallback: @escaping (ConfigurationCompatible) -> AudioDecoderCompatible) {
        _config = config
        _fallback = fallback
        // Bytes the streamer pushes before a decoder exists (they cannot arrive
        // before the `readyForRead` that triggers `prepare`) are forwarded to
        // whichever decoder `prepare` picked.
        _inputStream.delegate(to: self) { sself, input in
            sself._lock.lock()
            let active = sself._active
            sself._lock.unlock()
            active?.inputStream.call(input)
        }
    }

    /// The protocol-required builder entry point. Without a fallback, every URL
    /// the file decoder does not handle reports unsupported, so a router built
    /// this way can only play local CAF/AIFF/AIFF-C — prefer
    /// `APlayExtras.fileDecoder(fallback:)`.
    public convenience init(config: ConfigurationCompatible) {
        self.init(config: config, fallback: { NoFallbackDecoder(config: $0) })
    }

    private func active() -> AudioDecoderCompatible? {
        _lock.lock()
        defer { _lock.unlock() }
        return _active
    }

    /// True when the URL is a local file whose container the built-in streaming
    /// decoder provably cannot open.
    private static func wantsFileDecoder(for info: StreamProvider.URLInfo) -> Bool {
        if case let .local(_, hint) = info {
            return SeekableFileDecoder.handledHints.contains(hint)
        }
        return false
    }
}

// MARK: - No fallback

/// The router's default fallback: reports every URL as unsupported so a router
/// built without supplying one fails loudly rather than silently playing
/// nothing. Apps should go through `APlayExtras.fileDecoder(fallback:)`.
private final class NoFallbackDecoder: AudioDecoderCompatible {
    let info = AudioDecoder.Info()
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

// MARK: - AudioDecoderCompatible

extension FileFallbackDecoder: AudioDecoderCompatible {

    public var info: AudioDecoder.Info {
        active()?.info ?? _ownInfo
    }

    public var outputStream: Delegated<AudioDecoder.Event, Void> { _outputStream }
    public var inputStream: Delegated<AudioDecoder.AudioInput, Void> { _inputStream }

    public func seekable() -> Bool {
        return active()?.seekable() ?? false
    }

    public func prepare(for provider: StreamProviderCompatible, at position: StreamProvider.Position) throws {
        let wantsFile = Self.wantsFileDecoder(for: provider.info)
        let existing = active()

        let decoder: AudioDecoderCompatible
        if let existing, existing is SeekableFileDecoder == wantsFile {
            // Reuse: a re-`prepare` for a seek keeps the decoder already chosen
            // for this track (the hint cannot change under one URL).
            decoder = existing
        } else {
            let new: AudioDecoderCompatible = wantsFile
                ? SeekableFileDecoder(config: _config)
                : _fallback(_config)
            // Forward whatever the chosen decoder emits; the pipeline subscribed
            // to *this* decoder at construction time.
            new.outputStream.delegate(to: self) { sself, event in
                sself._outputStream.call(event)
            }
            _lock.lock()
            let old = _active
            _active = new
            let pendingResume = _pendingResume
            _pendingResume = false
            _lock.unlock()
            // `play` resumes before the streamer is even open, so a decoder chosen
            // here may have a resume waiting on it; apply it now, then prepare.
            if pendingResume { new.resume() }
            // The abandoned decoder's idle loop would keep ticking `.empty` forever;
            // stop it so only the chosen decoder can emit.
            old?.destroy()
            decoder = new
        }
        try decoder.prepare(for: provider, at: position)
    }

    public func pause() {
        _lock.lock()
        let active = _active
        _pendingResume = false
        _lock.unlock()
        active?.pause()
    }

    public func resume() {
        _lock.lock()
        let active = _active
        if active == nil { _pendingResume = true }
        _lock.unlock()
        active?.resume()
    }

    public func destroy() {
        _lock.lock()
        let active = _active
        _active = nil
        _pendingResume = false
        _lock.unlock()
        active?.destroy()
    }
}
