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

final class Composer {
    lazy var eventPipeline: Delegated<Event, Void> = Delegated<Event, Void>()
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
        private static var count = 0
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
                DispatchQueue.main.async {
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
            audioFileLength = contentLength - _metaDataSizeInBytes
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

    func play(_ url: URL, position: StreamProvider.Position = 0, info: AudioDecoder.Info? = nil) {
        eventPipeline.toggle(enable: true)
        if let value = info { _decoder.info.update(from: value) }
        _decoder.resume()
        _streamer.open(url: url, at: position)
        _player?.setup(Player.canonical)
        _player?.readClosure = { [weak self] size, pointer in
            guard let sself = self else { return (0, false) }
            let (readSize, isFirstData) = sself._ringBuffer.read(amount: size, into: pointer)
            if sself._decoder.info.srcFormat.isLinearPCM, readSize == 0 {
                sself._decoder.outputStream.call(.empty)
            }
            return (readSize, isFirstData)
        }
        if _streamer.info.isRemoteWave == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
                self._player?.resume()
            })
        }
        isRunning = true
        _config.startBackgroundTask(isToDownloadImage: false)
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
