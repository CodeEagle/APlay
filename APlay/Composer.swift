//
//  Composer.swift
//  APlayer
//
//  Created by lincoln on 2018/4/16.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// One decoder writer and one render reader. Only the writer may wait; the
/// audio side uses bounded atomic operations and memcpy. Closing never resets
/// cursors underneath an in-flight read; source retirement owns the storage.
private final class ComposerPCMBuffer {
    private let capacity: Int64
    private let storage: UnsafeMutableRawPointer
    private let written = RenderAtomic()
    private let consumed = RenderAtomic()
    private let closed = RenderAtomic()
    private let writerLock = NSLock()
    private let writerWake = DispatchSemaphore(value: 0)
    init(capacity: Int) {
        self.capacity = Int64(capacity)
        storage = .allocate(byteCount: capacity, alignment: 16)
    }
    deinit { storage.deallocate() }
    var availableData: UInt32 { UInt32(max(0, written.load() - consumed.load())) }
    func clear() { _ = closed.exchange(1); writerWake.signal() }
    func write(data: UnsafeRawPointer, amount: UInt32) {
        writerLock.lock(); defer { writerLock.unlock() }
        var offset = 0
        while offset < Int(amount), closed.load() == 0 {
            let tail = written.load()
            let free = Int(capacity - (tail - consumed.load()))
            guard free > 0 else {
                // Backpressure belongs to the decoder, never the audio callback.
                // Wait without a timeout: `read` and `clear` both wake this
                // semaphore, so the decoder thread is parked rather than waking
                // every 5 ms to re-test a buffer that a torn-down composer will
                // never drain — the polling loop is what kept orphaned composers
                // pinned on a live thread, unreachable by ARC.
                writerWake.wait()
                continue
            }
            let count = min(free, Int(amount) - offset)
            let index = Int(tail % capacity)
            let first = min(count, Int(capacity) - index)
            memcpy(storage.advanced(by: index), data.advanced(by: offset), first)
            if first < count { memcpy(storage, data.advanced(by: offset + first), count - first) }
            _ = written.add(Int64(count))
            offset += count
        }
    }
    func read(amount: UInt32, into pointer: UnsafeMutableRawPointer) -> (UInt32, Bool) {
        guard closed.load() == 0 else { return (0, false) }
        let head = consumed.load()
        let count = min(Int(amount), Int(written.load() - head))
        guard count > 0 else { return (0, false) }
        let index = Int(head % capacity)
        let first = min(count, Int(capacity) - index)
        memcpy(pointer, storage.advanced(by: index), first)
        if first < count { memcpy(pointer.advanced(by: first), storage, count - first) }
        _ = consumed.add(Int64(count))
        // Wake the decoder thread parked in `write` on a full buffer: the bytes
        // it is waiting for room for have just been consumed.
        writerWake.signal()
        return (UInt32(count), head == 0)
    }
}

final class Composer: @unchecked Sendable {
    lazy var eventPipeline: Delegated<Event, Void> = Delegated<Event, Void>()
    /// True while the composer is buffering a prepared track without playing it
    /// (see `prepare`). `startPlayback` flips it back to false.
    private let preloading = RenderAtomic()
    private(set) var isPreloading: Bool {
        get { preloading.load() != 0 }
        set { _ = preloading.exchange(newValue ? 1 : 0) }
    }
    /// True while this composer buffers a track *ahead* of the current one (see
    /// `preload(_:)`). `APlay` withholds its events and the output unit is left
    /// alone until `activate()` installs this composer as the read source.
    private let preloadAhead = RenderAtomic()
    private(set) var isPreloadAhead: Bool {
        get { preloadAhead.load() != 0 }
        set { _ = preloadAhead.exchange(newValue ? 1 : 0) }
    }
    private(set) var isRunning: Bool {
        get { return _queue.sync { _isRuning } }
        set { _queue.async(flags: .barrier) { self._isRuning = newValue } }
    }

    private weak var _player: PlayerCompatible?
    private let _streamer: StreamProviderCompatible
    private let _decoder: AudioDecoderCompatible
    private let _ringBuffer = ComposerPCMBuffer(capacity: 2 << 21) // 4 MiB
    private lazy var _queue = DispatchQueue(concurrentName: "Composer")
    private lazy var _isRuning = false
    private lazy var __isDoubleChecked = false
    private let _resumeLock = NSLock()
    /// A token makes automatic startup one-shot and invalidates queued work on teardown.
    private var _pendingResume: UUID?
    private let generation = UUID()
    private let alive = RenderAtomic(1)
    private let emptyMailbox = RenderAtomic()
    private let streamEnded = RenderAtomic()
    private let exhausted = RenderAtomic()
    private let didArm = RenderAtomic()
    private let renderSourceActivated = RenderAtomic()
    private let bufferedCallbackLock = NSLock()
    private var onBufferedAhead: (() -> Void)?
    /// The URL this composer was opened for. `play` and `preload` record it
    /// before they touch the streamer, so callers that key on the URL
    /// (`APlay.next` reusing a preload, `prepare`-then-`play`) do not race with
    /// the stream open — `preload` opens off-thread, and the streamer's `info`
    /// only carries the URL once that open lands.
    private let urlLock = NSLock()
    private var recordedURL: URL?
    var bufferedAhead: (() -> Void)? {
        get { bufferedCallbackLock.lock(); defer { bufferedCallbackLock.unlock() }; return onBufferedAhead }
        set { bufferedCallbackLock.lock(); onBufferedAhead = newValue; bufferedCallbackLock.unlock() }
    }

    private func configureOutput(_ format: AudioStreamBasicDescription, ready: Bool) {
        guard let player = _player else { return }
        if let output = player as? APlayer {
            output.configure(format, token: generation, exhausted: exhausted, valid: { [weak self] in
                self?.alive.load() == 1 && self?.isPreloadAhead == false
            }, source: makeReadSource(), ready: { [weak self] in
                ready && self?.alive.load() == 1 && self?.isBufferedAhead == true
            })
        } else {
            guard alive.load() == 1 else { return }
            if player.asbd != format { player.setup(format) }
        }
    }

    func armHandoff(valid: @escaping () -> Bool, completion: @escaping () -> Void) {
        guard let output = _player as? APlayer, isBufferedAhead,
              didArm.compare(0, 1) else { return }
        output.armNext(outputFormat, token: generation, enabled: alive, exhausted: exhausted,
                       valid: { [weak self] in self?.alive.load() == 1 && valid() },
                       source: makeReadSource()) { [weak self] in
            guard let self else { return }
            _ = self.renderSourceActivated.compare(0, 1)
            completion()
        }
    }

    private var _isDoubleChecked: Bool {
        get { return _queue.sync { __isDoubleChecked } }
        set { _queue.async(flags: .barrier) { self.__isDoubleChecked = newValue } }
    }

    private unowned let _config: ConfigurationCompatible
    /// Guards the first-audio duration announcement (see the `.output` case):
    /// formats that never emit a bitrate event would otherwise stay silent on
    /// duration forever, even though the value is already computable.
    private var hasAnnouncedDuration = false
    #if DEBUG
        /// Live (not yet `destroy()`ed) instance count. One current composer plus
        /// at most one buffering ahead is the whole budget; anything more is an
        /// orphaned composer whose streamer/decoder are still running.
        private nonisolated(unsafe) static var _liveCount = 0
        static var liveCount: Int {
            _liveCountLock.lock(); defer { _liveCountLock.unlock() }
            return _liveCount
        }
        private static let _liveCountLock = NSLock()
        private let _id: Int
        deinit {
            debug_log("\(self) \(#function)")
        }
    #endif

    init(player: PlayerCompatible, config: ConfigurationCompatible) {
        #if DEBUG
            Composer._liveCountLock.lock()
            _id = Composer._liveCount
            Composer._liveCount += 1
            Composer._liveCountLock.unlock()
        #endif
        _config = config
        _streamer = config.streamerBuilder(config)
        _decoder = config.audioDecoderBuilder(config)
        _player = player
        if let output = player as? APlayer {
            output.observe(generation) { [weak self] in
                guard let self, self.alive.load() == 1 else { return }
                if self.emptyMailbox.exchange(0) != 0 {
                    self.eventPipeline.call(.decoderEmptyEncountered)
                }
            }
        }
        _streamer.outputPipeline.delegate(to: self) { sself, value in
            switch value {
            case let .flac(value):
                sself._decoder.info.flacMetadata = value
                sself.eventPipeline.call(.flac(value))
            case let .unknown(error):
                sself.eventPipeline.call(.unknown(error))
            case .readyForRead:
                sself.prepare()
            case let .hasBytesAvailable(data, count, isFirstPacket):
                let bufProgress = sself._streamer.bufferingProgress
                sself.eventPipeline.call(.buffering(bufProgress))
                sself._decoder.info.fileHint = sself._streamer.info.fileHint
                sself._decoder.inputStream.call((data, count, isFirstPacket))
            case .endEncountered:
                _ = sself.streamEnded.compare(0, 1)
                if sself._decoder.info.srcFormat.isLinearPCM { _ = sself.exhausted.compare(0, 1) }
                sself.eventPipeline.call(.streamerEndEncountered)
            case let .metadataSize(size):
                sself._decoder.info.metadataSize = UInt(size)
            case let .errorOccurred(error):
                sself.eventPipeline.call(.error(error))
            case let .metadata(map):
                sself.modifyMetadata(of: map)
            }
        }

        _decoder.outputStream.delegate(to: self) { sself, value in
            switch value {
            case let .seekable(value):
                sself.eventPipeline.call(.seekable(value))
            case let .metadata(items):
                sself.modifyMetadata(of: items)
            case .empty:
                if sself.streamEnded.load() == 1 { _ = sself.exhausted.compare(0, 1) }
                if sself._player is APlayer { _ = sself.emptyMailbox.compare(0, 1) }
                else { sself.eventPipeline.call(.decoderEmptyEncountered) }
            case let .output(item):
                let format = sself.outputFormat
                sself._ringBuffer.write(data: item.0, amount: item.1)
                if sself.isPreloadAhead {
                    if item.1 > 0 { sself.bufferedAhead?() }
                } else if sself._player is APlayer {
                    sself.configureOutput(format, ready: item.1 > 0)
                } else {
                    DispatchQueue.main.async { [weak sself] in
                        guard let sself, sself.alive.load() == 1, !sself.isPreloadAhead else { return }
                        sself.configureOutput(format, ready: item.1 > 0)
                    }
                    if item.1 > 0 { sself.resumeWhenBuffered() }
                }
                // Bitrate events are the usual trigger, but they never arrive
                // for three classes of track that can still compute a duration:
                // Opus/MIDI report it through the container instead of the
                // bitrate property, and a short file can stop before the
                // 50-packet bitrate fallback accumulates. Announce on the
                // first decoded audio so the pipeline gets a duration either
                // way; the bitrate path keeps refining it afterwards.
                if sself.isPreloadAhead == false,
                   sself.hasAnnouncedDuration == false,
                   sself.duration > 0 {
                    sself.hasAnnouncedDuration = true
                    sself.updateDuration()
                }
            case let .error(err):
                sself.eventPipeline.call(.error(err))
                if case APlay.Error.parser = err {
                    sself._player?.pause()
                    sself._decoder.pause()
                }
            case .bitrate:
                sself.updateDuration()
            }
        }
    }

    private func updateDuration() {
        DispatchQueue.main.async {
            let d = Int(ceil(self.duration))
            self.eventPipeline.call(.duration(d))
        }
    }

    /// Decoded bytes, rather than the absolute download position, establish
    /// readiness after every open/seek (including local files and unknown lengths).
    /// Enqueued after format setup and the ring-buffer write, so rendering can
    /// consume audio immediately. Prepared tracks never arm this token.
    private func resumeWhenBuffered() {
        _resumeLock.lock()
        let token = _pendingResume
        _resumeLock.unlock()
        guard let token else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self._resumeLock.lock()
            let shouldResume = self._pendingResume == token
            if shouldResume { self._pendingResume = nil }
            self._resumeLock.unlock()
            guard shouldResume, self.alive.load() == 1, !self.isPreloadAhead else { return }
            self._player?.resume()
        }
    }

    private func prepare() {
        do {
            eventPipeline.call(.buffering(0))
            try _decoder.prepare(for: _streamer, at: _streamer.position)
        } catch {
            guard let e = error as? APlay.Error else {
                eventPipeline.call(.unknown(error))
                return
            }
            eventPipeline.call(.error(e))
        }
    }

    private func modifyMetadata(of data: [MetadataParser.Item]) {
        var ori = data
        for (index, item) in data.enumerated() {
            guard case let MetadataParser.Item.title(value) = item else { continue }
            if value.isEmpty {
                ori.remove(at: index)
                break
            } else {
                eventPipeline.call(.metadata(ori))
                return
            }
        }
        let title = _streamer.info.fileName
        ori.append(MetadataParser.Item.title(title))
        eventPipeline.call(.metadata(ori))
    }
}

extension Composer {
    var duration: Float {
        let _srcFormat = _decoder.info.srcFormat
        let framesPerPacket = _srcFormat.mFramesPerPacket
        let rate = _srcFormat.mSampleRate
        if _decoder.info.audioDataPacketCount > 0, framesPerPacket > 0 {
            return Float(_decoder.info.audioDataPacketCount) * Float(framesPerPacket) / Float(rate)
        }
        // Not enough data provided by the format, use bit rate based estimation
        var audioFileLength: UInt = 0
        let _audioDataByteCount = _decoder.info.audioDataByteCount
        let _metaDataSizeInBytes = _decoder.info.metadataSize
        let contentLength = _streamer.contentLength
        if _audioDataByteCount > 0 {
            audioFileLength = _audioDataByteCount
        } else {
            // FIXME: May minus more bytes
            /// http://www.beaglebuddy.com/content/pages/javadocs/index.html
            if contentLength > _metaDataSizeInBytes {
                audioFileLength = contentLength - _metaDataSizeInBytes
            }
        }
        if audioFileLength > 0 {
            let bitrate = Float(_decoder.info.bitrate)
            // 总播放时间 = 文件大小 * 8 / 比特率
            let rate = ceil(bitrate / 1000) * 1000 * 0.125
            if rate > 0 {
                let length = Float(audioFileLength)
                let dur = floor(length / rate)
                return dur
            }
        }
        return 0
    }

    var streamInfo: AudioDecoder.Info { return _decoder.info }

    var url: URL {
        urlLock.lock(); defer { urlLock.unlock() }
        return recordedURL ?? _streamer.info.url
    }

    func play(_ url: URL, position: StreamProvider.Position = 0, info: AudioDecoder.Info? = nil, autoplay: Bool = true) {
        urlLock.lock(); recordedURL = url; urlLock.unlock()
        isPreloading = autoplay == false
        _resumeLock.lock()
        _pendingResume = autoplay ? UUID() : nil
        _resumeLock.unlock()
        eventPipeline.toggle(enable: true)
        if let value = info { _decoder.info.update(from: value) }
        if let output = _player as? APlayer {
            output.select(generation, autoplay: autoplay)
            // Wait for the actual decoded format before publishing its source.
        } else {
            _player?.setup(Player.canonical)
            installReadSource()
        }
        _decoder.resume()
        _streamer.open(url: url, at: position)
        isRunning = true
        _config.startBackgroundTask(isToDownloadImage: false)
    }

    /// Opens a track without making it the current one: the streamer and decoder
    /// run and fill the ring buffer while the output unit keeps reading the
    /// track that is playing. No render source is installed and the audio unit
    /// is not touched; `APlay` withholds the events until `activate()`.
    ///
    /// This is the `prepare(_:)` semantics turned into a background preload for
    /// gapless playback.
    func preload(_ url: URL) {
        urlLock.lock(); recordedURL = url; urlLock.unlock()
        isPreloading = true
        isPreloadAhead = true
        eventPipeline.toggle(enable: true)
        _decoder.resume()
        isRunning = true
        // The stream must not be opened on the caller's thread: `preload` is
        // reached from the replayed end-of-stream event of the track that just
        // took over, which lands on the main queue, and the open does
        // synchronous file work plus a cross-queue close that would freeze the
        // UI and block the very queue that has to finish the handoff tail. The
        // flags above are set first, so every event the open produces already
        // sees this composer as merely buffering ahead — its events are
        // withheld and the output unit is left alone until `activate()`.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?._streamer.open(url: url, at: 0)
            self?._config.startBackgroundTask(isToDownloadImage: false)
        }
    }

    /// Takes over as the current track: installs this composer's ring buffer as
    /// the player's read source through the atomic render slot, so the audio
    /// unit keeps running and reads the buffered data from the next render
    /// slice on. Two tracks sharing a sample format hand over seamlessly; a
    /// change of format re-initialises the unit first (see
    /// `needsAudioUnitReconfiguration`).
    func activate(preservePlaybackIntent: Bool = false) {
        guard isPreloadAhead else { return }
        isPreloadAhead = false
        isPreloading = false
        if let output = _player as? APlayer {
            if renderSourceActivated.load() != 0 { return }
            output.select(generation, autoplay: preservePlaybackIntent ? nil : true)
            configureOutput(outputFormat, ready: isBufferedAhead)
            return
        }
        if needsAudioUnitReconfiguration { _player?.setup(outputFormat) }
        installReadSource()
        if _player?.state != .running { _player?.resume() }
    }

    /// The format the audio unit must be configured with to render this track.
    private var outputFormat: AudioStreamBasicDescription {
        let info = _decoder.info
        return info.srcFormat.isLinearPCM ? info.srcFormat : info.dstFormat
    }

    /// True once the track's sample format is known and differs from the audio
    /// unit's current configuration, so `setup(_:)` has to run before this
    /// composer can render. Cross-format handoffs are quick but not seamless —
    /// the unit is re-initialised.
    var needsAudioUnitReconfiguration: Bool {
        guard _decoder.info.isUpdated, let player = _player else { return false }
        return outputFormat != player.asbd
    }

    /// Whether the preloaded track has decoded audio waiting in the ring buffer.
    var isBufferedAhead: Bool {
        return _ringBuffer.availableData > 0
    }

    /// Installs the ring buffer (and the linear-PCM end-of-track detection) as
    /// the player's active render source.
    private func installReadSource() {
        _player?.readClosure = makeReadSource()
    }

    private func makeReadSource() -> (UInt32, UnsafeMutablePointer<UInt8>) -> (UInt32, Bool) {
        let linearPCM = _decoder.info.srcFormat.isLinearPCM
        let realtime = _player is APlayer
        return { [self] size, pointer in
            guard alive.load() == 1 else { return (0, false) }
            let result = _ringBuffer.read(amount: size, into: pointer)
            if linearPCM, result.0 == 0 {
                if realtime { _ = emptyMailbox.compare(0, 1) }
                else { _decoder.outputStream.call(.empty) }
            }
            return result
        }
    }

    /// Starts the output unit for a track opened with `autoplay: false`.
    /// The ring buffer already holds decoded data, so playback starts from it.
    func startPlayback() {
        guard isPreloading else { return }
        isPreloading = false
        _player?.resume()
    }

    func position(for time: inout TimeInterval) -> StreamProvider.Position {
        let d = duration
        guard d > 0 else { return 0 }
        var finalTime = time
        if time > TimeInterval(d) { finalTime = TimeInterval(d) - 1 }
        let percentage = Float(finalTime) / d
        // more accuracy using `_decoder.streamInfo.metadataSize` then `streamerinfo.dataOffset`, may id3v2 and id3v1 tag both exist.
        var dataOffset = percentage * Float(_streamer.contentLength - _decoder.info.metadataSize)

        let fileHint = streamInfo.fileHint
        if fileHint == .wave {
            let blockSize = Float(streamInfo.waveSubchunk1Size)
            let min = Int(dataOffset / blockSize)
            dataOffset = Float(min) * blockSize
        } else if fileHint == .flac, let flac = streamInfo.flacMetadata {
            // https://github.com/xiph/flac/blob/01eb19708c11f6aae1013e7c9c29c83efda33bfb/src/libFLAC/stream_decoder.c#L2990-L3198
            // consider no seektable condition
            if let (targetTime, offset) = flac.nearestOffset(for: time) {
                dataOffset = Float(offset)
                debug_log("flac seek: support to \(time), real time:\(targetTime)")
                time = targetTime
            }
        }
        let seekByteOffset = Float(streamInfo.dataOffset) + dataOffset
        return StreamProvider.Position(UInt(seekByteOffset))
    }

    func resume() {
        _decoder.resume()
        _streamer.resume()
    }

    func pause() {
        _resumeLock.lock(); _pendingResume = nil; _resumeLock.unlock()
        _decoder.pause()
        _streamer.pause()
    }

    func destroy() {
        // Idempotent: the composer slots are overwritten on every track
        // change, and a slot that lost a race can be destroyed twice. Only the
        // first teardown owns the live-count bookkeeping and the real work.
        guard alive.exchange(0) == 1 else { return }
        #if DEBUG
            Composer._liveCountLock.lock()
            Composer._liveCount -= 1
            Composer._liveCountLock.unlock()
        #endif
        // Synchronous order matters: the ring buffer is closed first so a
        // decoder thread parked in `write` on a full buffer is released before
        // anything below touches the components that thread may be calling.
        // The streamer task is cancelled and its callbacks dropped after the
        // decoder, so no in-flight network byte reaches a decommissioned
        // decoder.
        _ringBuffer.clear()
        (_player as? APlayer)?.unobserve(generation)
        bufferedAhead = nil
        _resumeLock.lock()
        _pendingResume = nil
        _resumeLock.unlock()
        eventPipeline.toggle(enable: false)
        _decoder.destroy()
        _streamer.destroy()
    }

    func seekable() -> Bool {
        return _decoder.seekable()
    }
}

extension Composer {
    enum Event {
        case buffering(Float)
        case streamerEndEncountered
        case decoderEmptyEncountered
        case error(APlay.Error)
        case unknown(Error)
        case duration(Int)
        case seekable(Bool)
        case metadata([MetadataParser.Item])
        case flac(FlacMetadata)
    }
}
