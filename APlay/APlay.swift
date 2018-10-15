//
//  APlay.swift
//  APlay
//
//  Created by lincoln on 2018/5/8.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation
import AVFoundation
#if canImport(UIKit)
    import UIKit
#endif

/// A public class for control audio playback
public final class APlay {
    /// Current framework version
    public static var version: String = "0.0.4"

    /// Loop pattern for playback list
    public var loopPattern: PlayList.LoopPattern {
        get { return playlist.loopPattern }
        set {
            playlist.loopPattern = newValue
            eventPipeline.call(.playModeChanged(newValue))
        }
    }

    /// Event callback for audio playback
    public private(set) var eventPipeline = Delegated<Event, Void>()
    /// Metadatas for current audio
    public private(set) lazy var metadatas: [MetadataParser.Item] = []
    /// Player Configuration
    public let config: ConfigurationCompatible

    private let _player: PlayerCompatible
    private let _nowPlayingInfo: NowPlayingInfo

    private var _state: State = .idle
    private var _playlist: PlayList
    private var _propertiesQueue = DispatchQueue(concurrentName: "APlay.properties")

    private lazy var __isSteamerEndEncounted = false
    private lazy var __isDecoderEndEncounted = false
    private lazy var __isCalledDelayPaused = false
    private lazy var __isFlagReseted = false
    private lazy var __lastDelta: Float = -1
    private lazy var __lastDeltaHitCount: Int = 0
    private var __currentComposer: Composer?
    private let _maxOpenRestry = 5
    private lazy var _currentOpenRestry = 0

    private lazy var _obs: [NSObjectProtocol] = []

    deinit {
        destroy()
        _obs.forEach({ NotificationCenter.default.removeObserver($0) })
        config.endBackgroundTask(isToDownloadImage: false)
        debug_log("\(self) \(#function)")
    }

    public init(configuration: ConfigurationCompatible = Configuration()) {
        config = configuration

        if #available(iOS 11.0, *) {
            _player = APlayer(config: config)
        } else {
            _player = AUPlayer(config: config)
        }

        _playlist = PlayList(pipeline: eventPipeline)

        _nowPlayingInfo = NowPlayingInfo(config: config)

        addInteruptOb()

        _player.eventPipeline.delegate(to: self) { obj, event in
            switch event {
            case let .state(state):
                let stateValue: State
                switch state {
                case .idle: stateValue = .idle
                case .running:
                    stateValue = .playing
                    obj._currentOpenRestry = 0
                case .paused: stateValue = .paused
                }
                obj.state = stateValue
                obj.eventPipeline.call(.state(stateValue))
            case let .playback(time):
                // synchronize playback time for first time since reset
                if obj._isFlagReseted {
                    obj._isFlagReseted = false
                    obj._nowPlayingInfo.play(elapsedPlayback: time)
                    debug_log("NowPlayingInfo:\(obj._nowPlayingInfo.info)")
                }
                obj.eventPipeline.call(.playback(time))
            case let .error(error):
                if case let APlay.Error.open(value) = error, obj._currentOpenRestry < obj._maxOpenRestry {
                    obj._currentOpenRestry += 1
                    obj.seek(to: 0)
                    debug_log("reopen by using seek, \(value)")
                    return
                }
                let state = APlay.State.error(error)
                obj.state = state
                obj.eventPipeline.call(.state(state))
            case let .unknown(error):
                let state = APlay.State.unknown(error)
                obj.state = state
                obj.eventPipeline.call(.state(state))
            }
        }
    }
}

// MARK: - Public API

public extension APlay {
    /// play with a autoclosure
    ///
    /// - Parameter url: a autoclosure to produce URL
    func play(_ url: @autoclosure () -> URL) {
        let u = url()
        let urls = [u]
        playlist.changeList(to: urls, at: 0)
        _play(u)
    }

    /// play whit variable parametric
    ///
    /// - Parameter urls: variable parametric URL input
    @inline(__always)
    func play(_ urls: URL..., at index: Int = 0) { play(urls, at: index) }

    /// play whit URL array
    ///
    /// - Parameter urls: URL array
    func play(_ urls: [URL], at index: Int = 0) {
        guard let url = urls[ap_safe: index] else {
            let msg = "Can not found item at \(index) in list \(urls)"
            eventPipeline.call(.error(.playItemNotFound(msg)))
            return
        }
        playlist.changeList(to: urls, at: index)
        _play(url)
    }

    func play(at index: Int) {
        guard let url = playlist.play(at: index) else {
            let msg = "Can not found item at \(index) in list \(playlist.list)"
            eventPipeline.call(.error(.playItemNotFound(msg)))
            return
        }
        _play(url)
    }

    /// toggle play/pause for player
    func toggle() {
        _player.toggle()
        switch _player.state {
        case .running: _state = .playing
        case .paused: _state = .paused
        case .idle: _state = .idle
        }
    }

    /// resume playback
    func resume() {
        _player.resume()
        _nowPlayingInfo.play(elapsedPlayback: _player.currentTime())
    }

    /// pause playback
    func pause() {
        _player.pause()
        _nowPlayingInfo.pause(elapsedPlayback: _player.currentTime())
    }

    /// Seek to specific time
    ///
    /// - Parameter time: TimeInterval
    func seek(to time: TimeInterval) {
        resetFlag(clearNowPlayingInfo: false)
        guard let current = _currentComposer else { return }
        var maybeTime = time
        let p = current.position(for: &maybeTime)
        current.destroy()
        let com = createComposer()
        _player.startTime = Float(maybeTime)
        com.play(current.url, position: p, info: current.streamInfo)
        _currentComposer = com
        _nowPlayingInfo.play(elapsedPlayback: Float(maybeTime))
        eventPipeline.call(.duration(_nowPlayingInfo.duration))
    }

    /// play next song in list
    func next() {
        guard let url = playlist.nextURL() else { return }
        _play(url)
        indexChanged()
    }

    /// play previous song in list
    func previous() {
        guard let url = playlist.previousURL() else { return }
        _play(url)
        indexChanged()
    }

    /// destroy player
    func destroy() {
        _currentComposer?.destroy()
        _player.destroy()
    }

    /// whether current song support seek
    func seekable() -> Bool {
        return _currentComposer?.seekable() ?? false
    }

    func metadataUpdate(title: String? = nil, album: String? = nil, artist: String? = nil, cover: UIImage? = nil) {
        if let value = title { _nowPlayingInfo.name = value }
        if let value = artist { _nowPlayingInfo.artist = value }
        if let value = album { _nowPlayingInfo.album = value }
        if let value = cover { _nowPlayingInfo.artwork = value }
        _nowPlayingInfo.update()
    }
}

// MARK: - Private Utils

private extension APlay {

    // MARK: Playback

    func _play(_ url: URL) {
        resetFlag()
        _currentComposer?.destroy()
        let com = createComposer()
        com.play(url)
        _currentComposer = com
        _nowPlayingInfo.play(elapsedPlayback: 0)
    }

    func resetFlag(clearNowPlayingInfo: Bool = true) {
        _isSteamerEndEncounted = false
        _isDecoderEndEncounted = false
        _lastDelta = -1
        _lastDeltaHitCount = 0
        _player.startTime = 0
        _isFlagReseted = true
        config.logger.reset()
        if clearNowPlayingInfo { _nowPlayingInfo.remove() }
    }

    func checkPlayEnded() {
        if _isSteamerEndEncounted == false {
            // bad network condition, show waiting
            eventPipeline.call(.waitForStreaming)
            return
        }
        guard let dur = _currentComposer?.duration else { return }
        let currentTime = _player.currentTime()
        let delta = abs(currentTime - dur)
        let deltaThreshold: Float = 0.02
        let lastDeltaThreshold: Float = 1
        let lastDeltaHitThreshold = 2
        if delta <= deltaThreshold {
            pauseAll(after: delta)
        } else {
            if _lastDelta != delta {
                _lastDelta = delta
            } else if _lastDelta <= deltaThreshold {
                pauseAll(after: delta)
            } else {
                _lastDeltaHitCount += 1
                if _lastDeltaHitCount > lastDeltaHitThreshold, _lastDelta <= lastDeltaThreshold {
                    pauseAll(after: _lastDelta)
                }
            }
        }
    }

    func pauseAll(after time: Float) {
        guard _isCalledDelayPaused == false else { return }
        _isCalledDelayPaused = true
        let delay = DispatchTimeInterval.milliseconds(Int(floor(time * 1000)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let dur = self._currentComposer?.duration {
                self.eventPipeline.call(.playback(dur))
            }
            self._player.pause()
            self._currentComposer?.pause()
            self.eventPipeline.call(.playEnded)
            self._isCalledDelayPaused = false
            self.next()
        }
    }

    func indexChanged() {
        guard let index = playlist.playingIndex else { return }
        eventPipeline.call(.playingIndexChanged(index))
    }

    // MARK: Composer

    func createComposer() -> Composer {
        let com = Composer(player: _player, config: config)
        com.eventPipeline.delegate(to: self) { obj, event in
            switch event {
            case let .seekable(value):
                obj.eventPipeline.call(.seekable(value))
            case let .buffering(p):
                obj.eventPipeline.call(.buffering(p))
            case .streamerEndEncountered:
                obj._isSteamerEndEncounted = true
                obj.eventPipeline.call(.streamerEndEncountered)
            case let .duration(value):
                obj.eventPipeline.call(.duration(value))
                obj._nowPlayingInfo.duration = value
                obj._nowPlayingInfo.update()
            case let .error(err):
                obj.eventPipeline.call(.error(err))
            case .decoderEmptyEncountered:
                obj.checkPlayEnded()
            case let .unknown(error):
                let state = APlay.State.unknown(error)
                obj.state = state
                obj.eventPipeline.call(.state(state))
            case let .flac(value):
                obj.eventPipeline.call(.flac(value))
            case let .metadata(values):
                obj.metadatas = values
                obj.eventPipeline.call(.metadata(values))
                guard obj.config.isAutoFillID3InfoToNowPlayingCenter else { return }
                for val in values {
                    switch val {
                    case let .album(text): obj._nowPlayingInfo.album = text
                    case let .artist(text): obj._nowPlayingInfo.artist = text
                    case let .title(text): obj._nowPlayingInfo.name = text
                        #if canImport(UIKit)
                            case let .cover(cov): obj._nowPlayingInfo.artwork = UIImage(data: cov)
                        #endif
                    default: break
                    }
                }
                obj._nowPlayingInfo.update()
            }
        }
        return com
    }

    private func addInteruptOb() {
        guard config.isAutoHandlingInterruptEvent else { return }
        /// RouteChange
        let note1 = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {[weak self] (note) in
            let interuptionDict = note.userInfo
            // "Headphone/Line was pulled. Stopping player...."
            if let routeChangeReason = interuptionDict?[AVAudioSessionRouteChangeReasonKey] as? UInt, routeChangeReason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                self?.pause()
            }
        }

        var playingStateBeforeInterrupte = state.isPlaying
        let note2 = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self](note) -> Void in
            guard let sself = self else { return }
            let info = note.userInfo
            guard let type = info?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            if type == AVAudioSession.InterruptionType.began.rawValue {
                // 中断开始
                playingStateBeforeInterrupte = sself.state.isPlaying
                if playingStateBeforeInterrupte == true { sself.pause() }
            } else {
                // 中断结束
                guard let options = info?[AVAudioSessionInterruptionOptionKey] as? UInt, options == AVAudioSession.InterruptionOptions.shouldResume.rawValue, playingStateBeforeInterrupte == true else { return }
                sself.resume()
            }
        }
        _obs = [note1, note2]
    }

}

// MARK: - Thread Safe

extension APlay {
    /// playback list
    public var playlist: PlayList {
        get { return _propertiesQueue.sync { _playlist } }
        set { _propertiesQueue.async(flags: .barrier) { self._playlist = newValue } }
    }

    /// playback state
    public var state: State {
        get { return _propertiesQueue.sync { _state } }
        set { _propertiesQueue.async(flags: .barrier) { self._state = newValue } }
    }

    /// duration for current song
    public var duration: Int {
        return _nowPlayingInfo.duration
    }

    private var _isSteamerEndEncounted: Bool {
        get { return _propertiesQueue.sync { __isSteamerEndEncounted } }
        set { _propertiesQueue.async(flags: .barrier) { self.__isSteamerEndEncounted = newValue } }
    }

    private var _isDecoderEndEncounted: Bool {
        get { return _propertiesQueue.sync { __isDecoderEndEncounted } }
        set { _propertiesQueue.async(flags: .barrier) { self.__isDecoderEndEncounted = newValue } }
    }

    private var _isCalledDelayPaused: Bool {
        get { return _propertiesQueue.sync { __isCalledDelayPaused } }
        set { _propertiesQueue.async(flags: .barrier) { self.__isCalledDelayPaused = newValue } }
    }

    private var _isFlagReseted: Bool {
        get { return _propertiesQueue.sync { __isFlagReseted } }
        set { _propertiesQueue.async(flags: .barrier) { self.__isFlagReseted = newValue } }
    }

    private var _lastDelta: Float {
        get { return _propertiesQueue.sync { __lastDelta } }
        set { _propertiesQueue.async(flags: .barrier) { self.__lastDelta = newValue } }
    }

    private var _lastDeltaHitCount: Int {
        get { return _propertiesQueue.sync { __lastDeltaHitCount } }
        set { _propertiesQueue.async(flags: .barrier) { self.__lastDeltaHitCount = newValue } }
    }

    private var _currentComposer: Composer? {
        get { return _propertiesQueue.sync { __currentComposer } }
        set { _propertiesQueue.async(flags: .barrier) { self.__currentComposer = newValue } }
    }
}

// MARK: - Enums

public extension APlay {
    /// Event for playback
    ///
    /// - state: player state
    /// - buffering: buffer event with progress
    /// - waitForStreaming: bad network detech, waiting for more data to come
    /// - streamerEndEncountered: stream end
    /// - playEnded: playback complete
    /// - playback: playback with current time
    /// - duration: song duration
    /// - seekable: seekable event
    /// - playlistChanged: playlist changed
    /// - playModeChanged: loop pattern changed
    /// - error: error
    /// - metadata: song matadata
    /// - flac: flac metadata
    public enum Event {
        case state(State)
        case buffering(Float)
        case waitForStreaming
        case streamerEndEncountered
        case playEnded
        case playback(Float)
        case duration(Int)
        case seekable(Bool)
        case playingIndexChanged(Int)
        case playlistChanged([URL], Int)
        case playModeChanged(PlayList.LoopPattern)
        case error(APlay.Error)
        case metadata([MetadataParser.Item])
        case flac(FlacMetadata)
    }

    /// Player State
    ///
    /// - idle: init state
    /// - playing: playing
    /// - paused: paused
    /// - error: error
    /// - unknown: exception
    public enum State {
        case idle
        case playing
        case paused
        case error(APlay.Error)
        case unknown(Swift.Error)

        public var isPlaying: Bool {
            switch self {
            case .playing: return true
            default: return false
            }
        }
    }

    /// Error for APlay
    ///
    /// - none: init state
    /// - open: error when opening stream
    /// - openedAlready: try to reopen a stream
    /// - streamParse: parser error
    /// - network: network error
    /// - networkPermission: network permission result
    /// - reachMaxRetryTime: reach max retry time error
    /// - networkStatusCode: networ reponse with status code
    /// - parser: parser error with OSStatus
    /// - player: player error
    public enum Error: Swift.Error {
        case none, open(String), openedAlready(String), streamParse(String), network(String), networkPermission(String), reachMaxRetryTime, networkStatusCode(Int), parser(OSStatus), player(String), playItemNotFound(String)
    }
}
