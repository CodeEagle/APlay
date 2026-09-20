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

final class Composer: @unchecked Sendable {
    lazy var eventPipeline: Delegated<Event, Void> = Delegated<Event, Void>()
    /// True while the composer is buffering a prepared track without playing it
    /// (see `prepare`). `startPlayback` flips it back to false.
    private(set) var isPreloading = false
    /// True while this composer buffers a track *ahead* of the current one (see
    /// `preload(_:)`). `APlay` withholds its events and the output unit is left
    /// alone until `activate()` installs this composer as the read source.
    private(set) var isPreloadAhead = false
    private(set) var isRunning: Bool {
        get { return _queue.sync { _isRuning } }
        set { _queue.async(flags: .barrier) { self._isRuning = newValue } }
    }

    private weak var _player: PlayerCompatible?
    private let _streamer: StreamProviderCompatible
    private let _decoder: AudioDecoderCompatible
    private let _ringBuffer = Uroboros(capacity: 2 << 21) // 2MB
    private lazy var _queue = DispatchQueue(concurrentName: "Composer")
    private lazy var _isRuning = false
    private lazy var __isDoubleChecked = false

    private var _isDoubleChecked: Bool {
        get { return _queue.sync { __isDoubleChecked } }
        set { _queue.async(flags: .barrier) { self.__isDoubleChecked = newValue } }
    }

    private unowned let _config: ConfigurationCompatible
    #if DEBUG
        private nonisolated(unsafe) static var count = 0
        private let _id: Int
        deinit {
            debug_log("\(self) \(#function)")
        }
    #endif

    init(player: PlayerCompatible, config: ConfigurationCompatible) {
        #if DEBUG
            _id = Composer.count
            Composer.count = Composer.count &+ 1
        #endif
        _config = config
        _streamer = config.streamerBuilder(config)
        _decoder = config.audioDecoderBuilder(config)
        _player = player
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
                if sself._streamer.info.isRemoteWave {
                    let targetPercentage = sself._config.preBufferWaveFormatPercentageBeforePlay
                    if bufProgress > targetPercentage {
                        DispatchQueue.main.async {
                            sself._player?.resume()
                        }
                    }
                }
                sself._decoder.info.fileHint = sself._streamer.info.fileHint
                sself._decoder.inputStream.call((data, count, isFirstPacket))
            case .endEncountered:
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
            case .empty:
                sself.eventPipeline.call(.decoderEmptyEncountered)
            case let .output(item):
                // A track buffering ahead of the current one must not
                // reconfigure the audio unit — that would stop the track
                // that is actually playing. The decision is captured here rather
                // than read inside the block: a block queued while preloading
                // can run after `activate()`, and `activate()` configures the
                // unit itself if the formats differ.
                let configuringAllowed = sself.isPreloadAhead == false
                DispatchQueue.main.async {
                    guard configuringAllowed else { return }
                    if let player = sself._player {
                        let dstFormat = sself._decoder.info.dstFormat
                        let srcFormat = sself._decoder.info.srcFormat
                        if srcFormat.isLinearPCM, player.asbd != srcFormat {
                            player.setup(srcFormat)
                            debug_log("⛑ 0 set asbd")
                        } else if dstFormat != player.asbd {
                            player.setup(dstFormat)
                            debug_log("⛑ 1 set asbd")
                        }
                    }
                }
                sself._ringBuffer.write(data: item.0, amount: item.1)
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

    var url: URL { return _streamer.info.url }

    func play(_ url: URL, position: StreamProvider.Position = 0, info: AudioDecoder.Info? = nil, autoplay: Bool = true) {
        isPreloading = autoplay == false
        eventPipeline.toggle(enable: true)
        if let value = info { _decoder.info.update(from: value) }
        _decoder.resume()
        _streamer.open(url: url, at: position)
        _player?.setup(Player.canonical)
        installReadSource()
        if autoplay, _streamer.info.isRemoteWave == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: { [weak self] in
                self?._player?.resume()
            })
        }
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
    func activate() {
        guard isPreloadAhead else { return }
        isPreloadAhead = false
        isPreloading = false
        guard needsAudioUnitReconfiguration, let player = _player else {
            installReadSource()
            // The unit is already rendering for an end-of-track handoff; only a
            // handoff the user triggered while paused needs the output started. The
            // guard keeps `resume()` — which touches main-actor APIs on iOS — off
            // the realtime render thread.
            if _player?.state != .running {
                _player?.resume()
            }
            return
        }
        // A change of sample format has to re-initialise the audio unit, which
        // stops and restarts the AVAudioEngine render graph. That must never run
        // on the render thread: `activate()` is reached from the render
        // callback's end-of-track chain, and `setup` waits for the render in
        // flight to finish — deadlocking against the very callback that called
        // it, so the handoff tail never runs and the end-of-track flag stays
        // set forever. Finish the swap on the main queue instead; the current
        // track has already run dry, so the unit emits silence for the few
        // milliseconds until the swap lands rather than stalling, and a
        // cross-format transition was never seamless anyway.
        DispatchQueue.main.async { [weak self] in
            guard let sself = self else { return }
            player.setup(sself.outputFormat)
            sself.installReadSource()
            if player.state != .running {
                player.resume()
            }
        }
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
        _player?.readClosure = { [weak self] size, pointer in
            guard let sself = self else { return (0, false) }
            let (readSize, isFirstData) = sself._ringBuffer.read(amount: size, into: pointer)
            if sself._decoder.info.srcFormat.isLinearPCM, readSize == 0 {
                sself._decoder.outputStream.call(.empty)
            }
            return (readSize, isFirstData)
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
        _decoder.pause()
        _streamer.pause()
    }

    func destroy() {
        _ringBuffer.clear()
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
