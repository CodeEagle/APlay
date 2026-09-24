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
public final class APlay: @unchecked Sendable {
    /// Current framework version
    public static let version: String = "2.0.0"

    /// Loop pattern for playback list
    public var loopPattern: PlayList.LoopPattern {
        get { return playlist.loopPattern }
        set {
            discardPreload()
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
    #if os(iOS) || os(visionOS)
        /// Lock screen / Control Center / AirPlay 2 remote-command handlers.
        /// Kept alive for the player's lifetime so the installed targets stay
        /// installed; nil when the feature is disabled in the configuration.
        private var _remoteCommandController: RemoteCommandController?
    #endif

    private var _state: State = .idle
    private var _playlist: PlayList
    private var _propertiesQueue = DispatchQueue(concurrentName: "APlay.properties")

    private var __isSteamerEndEncounted = false
    private var __isDecoderEndEncounted = false
    private var __isCalledDelayPaused = false
    private let __delayPausedLock = NSLock()
    private var __isFlagReseted = false
    private var __lastDelta: Float = -1
    private var __lastDeltaHitCount: Int = 0
    private var __lastFrozenTime: Float = -1
    private var __frozenHitCount: Int = 0
    private let __frozenLock = NSLock()
    private var __currentComposer: Composer?
    /// The track buffering one step ahead of `__currentComposer`, so the
    /// handover at the end of the current track needs no reopen and no pause.
    private var __nextComposer: Composer?
    /// Events collected while `__nextComposer` is only buffering ahead; they are
    /// replayed through the forwarder the moment the track takes over.
    private let __pendingNextEvents = PendingComposerEvents()
    private var __isPlayingBeforeInterrupt = false
    private let _maxOpenRestry = 5
    private var _currentOpenRestry = 0

    private var _obs: [NSObjectProtocol] = []

    deinit {
        // deinit runs under exclusive access to self: no other strong reference
        // exists, so the backing storage can be touched directly. Going through
        // the queue-safe accessors here would be wrong as well as wasteful — the
        // last release can happen on _propertiesQueue itself (a block it captured
        // is destroyed while the queue drains), and a `sync` onto the queue that
        // is already executing the current thread is a deadlock.
        __currentComposer?.destroy()
        __nextComposer?.destroy()
        _player.destroy()
        _obs.forEach({ NotificationCenter.default.removeObserver($0) })
        config.endBackgroundTask(isToDownloadImage: false)
        debug_log("\(self) \(#function)")
    }

    convenience public init(configuration: ConfigurationCompatible = Configuration()) {
        self.init(player: APlayer(config: configuration), configuration: configuration)
    }

    /// Test/preview seam: inject a player without exposing the internal
    /// `PlayerCompatible` protocol (and its raw-pointer render closure) in the
    /// public initialiser's signature.
    internal init(player: PlayerCompatible, configuration: ConfigurationCompatible) {
        config = configuration

        _player = player

        _playlist = PlayList(pipeline: eventPipeline)

        _nowPlayingInfo = NowPlayingInfo(config: config)

        #if os(iOS) || os(visionOS)
            if config.isEnabledRemoteCommandHandling {
                _remoteCommandController = RemoteCommandController(player: self)
            }
        #endif

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
                // A stream that never reports a usable duration (opus in an ogg
                // container) also stops emitting decoder-`.empty` events once the
                // streamer is done, so end-of-track is detected here instead:
                // `checkPlayEnded` fires on the second identical sample.
                if obj._isSteamerEndEncounted {
                    obj.checkPlayEnded()
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
    /// Realtime PCM observer for spectrum analyzers and visualizers.
    ///
    /// Set to a closure to receive the interleaved samples about to enter the
    /// render graph; the closure runs on the audio thread and must not allocate
    /// or block. Set to `nil` to detach. See `PlayerCompatible.pcmTap`.
    var pcmTap: ((UnsafePointer<AudioBufferList>, UInt32, AVAudioFormat) -> Void)? {
        get { _player.pcmTap }
        set { _player.pcmTap = newValue }
    }

    /// Track metadata for the system's Now Playing card.
    ///
    /// Pass this to `play(_:metadata:)` / `prepare(_:metadata:)` so the engine
    /// can publish the new track the moment it clears the previous one —
    /// `_play` clears the card and, without this, only the URL is known, which
    /// leaves the card blank until the host notices and pushes metadata of
    /// its own. Everything is optional and `nil` fields are left untouched.
    public struct NowPlayingMetadata: Sendable {
        public var title: String?
        public var artist: String?
        public var album: String?
        /// Fetched asynchronously (URLCache-backed) and published on arrival.
        public var artworkURL: String?
        /// Set directly, for hosts that already have the image in memory.
        public var artwork: APlayImage?

        public init(
            title: String? = nil,
            artist: String? = nil,
            album: String? = nil,
            artworkURL: String? = nil,
            artwork: APlayImage? = nil
        ) {
            self.title = title
            self.artist = artist
            self.album = album
            self.artworkURL = artworkURL
            self.artwork = artwork
        }
    }

    /// play with a autoclosure
    ///
    /// - Parameters:
    ///   - url: a autoclosure to produce URL
    ///   - metadata: the new track's Now Playing metadata, published as soon as
    ///     the previous track's card is cleared
    func play(_ url: @autoclosure () -> URL, metadata: NowPlayingMetadata? = nil) {
        let u = url()
        // If the same track is already preloaded (buffered but not playing),
        // start playback from the filled ring buffer instead of reopening it.
        // The metadata still has to be applied here — this branch never runs
        // `_play`, so the `apply` there would be skipped.
        if let com = _currentComposer, com.url == u, com.isPreloading {
            if let metadata { _nowPlayingInfo.apply(metadata) }
            com.startPlayback()
            return
        }
        let urls = [u]
        playlist.changeList(to: urls, at: 0)
        _play(u, metadata: metadata)
    }

    /// Preload a track without starting playback.
    ///
    /// The streamer and decoder run and fill the ring buffer, but the output
    /// audio unit is not started. A subsequent `play` of the same URL picks up
    /// the buffered data and starts immediately. See issue #14.
    ///
    /// - Parameters:
    ///   - url: a autoclosure to produce URL
    ///   - metadata: the new track's Now Playing metadata, applied now so it is
    ///     already in place when a later `play` of the same URL takes the
    ///     preload fast path
    func prepare(_ url: @autoclosure () -> URL, metadata: NowPlayingMetadata? = nil) {
        let u = url()
        let urls = [u]
        playlist.changeList(to: urls, at: 0)
        _play(u, autoplay: false, metadata: metadata)
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
        playlist.changeList(to: urls, at: index)
        guard let url = playlist.currentList[ap_safe: index] else {
            let msg = "Can not found item at \(index) in list \(urls)"
            eventPipeline.call(.error(.playItemNotFound(msg)))
            return
        }
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
        _currentComposer = com
        com.play(current.url, position: p, info: current.streamInfo)
        _nowPlayingInfo.play(elapsedPlayback: Float(maybeTime))
        eventPipeline.call(.duration(_nowPlayingInfo.duration))
    }

    /// play next song in list
    func next() {
        guard let url = playlist.nextURL() else { return }
        // A skip onto the track that is already buffered ahead of the current
        // one takes the buffer instead of reopening the stream.
        if let pre = _nextComposer, pre.url == url, canTakeOverPreload(pre) {
            _isCalledDelayPaused = true
            activatePreloadedTrack(pre)
        } else {
            discardPreload()
            _play(url)
        }
        indexChanged()
    }

    /// play previous song in list
    func previous() {
        guard let url = playlist.previousURL() else { return }
        discardPreload()
        _play(url)
        indexChanged()
    }

    /// destroy player
    func destroy() {
        discardPreload()
        _currentComposer?.destroy()
        _player.destroy()
    }

    /// whether current song support seek
    func seekable() -> Bool {
        return _currentComposer?.seekable() ?? false
    }

    /// Current playback time, in seconds.
    ///
    /// Backs the remote-command skip-forward / skip-backward handlers, which
    /// need the live position to jump from.
    func currentTime() -> TimeInterval {
        return TimeInterval(_player.currentTime())
    }

    func metadataUpdate(title: String? = nil, album: String? = nil, artist: String? = nil, cover: APlayImage? = nil) {
        if let value = title { _nowPlayingInfo.name = value }
        if let value = artist { _nowPlayingInfo.artist = value }
        if let value = album { _nowPlayingInfo.album = value }
        if let value = cover { _nowPlayingInfo.artwork = value }
        _nowPlayingInfo.update()
    }

    /// Set the gain of an equalizer band at runtime.
    ///
    /// - Parameters:
    ///   - gain: Band gain in dB (clamped to `-96 ... 24`).
    ///   - index: Band index, in the same order as `Configuration.equalizerBandFrequencies`.
    /// - Note: Has no effect when the built-in equalizer is unavailable (e.g. players that
    ///   don't build an audio graph) or when `index` is out of range.
    func setEqualizerBandGain(_ gain: Float, at index: Int) {
        guard config.equalizerBandFrequencies.indices.contains(index) else {
            config.logger.log("Equalizer band index \(index) is out of range (\(config.equalizerBandFrequencies.count) bands)", to: .player)
            return
        }
        _player.setEqualizerBandGain(index: index, gain: gain)
    }

    /// The current gain of every equalizer band, in dB, ordered like
    /// `Configuration.equalizerBandFrequencies`.
    var equalizerGains: [Float] {
        return _player.equalizerBandGains
    }

    /// Applies an equalizer preset to the running player. Band gains change
    /// immediately — playback is not paused or restarted.
    ///
    /// A preset whose band count differs from `Configuration
    /// .equalizerBandFrequencies` is ignored (and logged), so a preset saved
    /// against one band layout never silently shifts the wrong frequencies when
    /// the configuration changes.
    /// - Parameter preset: The preset to apply.
    /// - Returns: `true` if the preset was applied; `false` if its band count
    ///   did not match the configuration.
    @discardableResult
    func applyEqualizerPreset(_ preset: EqualizerPreset) -> Bool {
        let bandCount = config.equalizerBandFrequencies.count
        guard preset.gains.count == bandCount else {
            config.logger.log("Equalizer preset \"\(preset.name)\" has \(preset.gains.count) bands but the configuration has \(bandCount); ignored", to: .player)
            return false
        }
        for (index, gain) in preset.gains.enumerated() {
            _player.setEqualizerBandGain(index: index, gain: gain)
        }
        return true
    }
}

// MARK: - Private Utils

private extension APlay {

    // MARK: Playback

    func _play(_ url: URL, autoplay: Bool = true, metadata: NowPlayingMetadata? = nil) {
        resetFlag()
        discardPreload()
        _currentComposer?.destroy()
        let com = createComposer()
        _currentComposer = com
        com.play(url, autoplay: autoplay)
        // `resetFlag` has just cleared the card; the new track's metadata goes
        // in before the publish below, so the card never describes the old
        // track and never sits blank waiting for the host to notice.
        if let metadata { _nowPlayingInfo.apply(metadata) }
        _nowPlayingInfo.play(elapsedPlayback: 0)
    }

    func resetFlag(clearNowPlayingInfo: Bool = true) {
        _isSteamerEndEncounted = false
        _isDecoderEndEncounted = false
        _lastDelta = -1
        _lastDeltaHitCount = 0
        _lastFrozenTime = -1
        _frozenHitCount = 0
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
        let frozenHitThreshold = 2
        let currentTime = _player.currentTime()
        // Playback time that stops advancing while the stream is already fully
        // received is a truer end-of-track signal than the estimated duration
        // (opus in an ogg container reports none that Core Audio honours, and
        // the estimate can even come back NaN while the format is still being
        // pinned down, so a delta-based check alone never fires).
        if currentTime > 0 {
            if _lastFrozenTime != currentTime {
                _lastFrozenTime = currentTime
                _frozenHitCount = 0
            } else {
                _frozenHitCount += 1
                if _frozenHitCount >= frozenHitThreshold {
                    handlePlayEnded(after: 0)
                    return
                }
            }
        }
        // A duration of 0 means the format never reported one (WavPack,
        // Vorbis, Speex and other whole-file decoders outside Core Audio).
        // The delta check below is meaningless against it — `currentTime` is
        // still 0 while the track buffers, so `delta` is 0 and the track would
        // be pronounced over before it ever started, replaying it forever.
        // End detection for these tracks is the frozen-time path above.
        guard let dur = _currentComposer?.duration, dur.isFinite, dur > 0 else { return }
        let delta = abs(currentTime - dur)
        let deltaThreshold: Float = 0.02
        let lastDeltaHitThreshold = 2
        if delta <= deltaThreshold {
            handlePlayEnded(after: delta)
        } else {
            if _lastDelta != delta {
                _lastDelta = delta
                _lastDeltaHitCount = 0
            } else if _lastDelta <= deltaThreshold {
                handlePlayEnded(after: delta)
            } else {
                // Playback time stopped advancing while the stream is already
                // done: the track has run dry even though the estimated duration
                // never agreed with reality (opus in an ogg container reports
                // no duration Core Audio honours).
                _lastDeltaHitCount += 1
                if _lastDeltaHitCount > lastDeltaHitThreshold {
                    handlePlayEnded(after: _lastDelta)
                }
            }
        }
    }

    /// End of the current track: hand over to the preloaded next track without
    /// stopping the output unit when one is ready, otherwise fall back to the
    /// classic pause → `playEnded` → rebuild path.
    func handlePlayEnded(after time: Float) {
        if let pre = _nextComposer, canTakeOverPreload(pre), pre.url == playlist.peekNextURL() {
            // `_isCalledDelayPaused` guards the whole end-of-track sequence, not
            // just the delayed pause: it stops a second `.empty` event (the
            // decoder reports one every timer tick) from re-entering the handoff
            // before the main-queue tail resets it.
            _isCalledDelayPaused = true
            performGaplessHandoff()
            return
        }
        pauseAll(after: time)
    }

    /// Whether the buffered track is in a state where it can take the output
    /// over. The URL match is the caller's business: the end of a track peeks at
    /// the playlist, a manual skip already knows which URL it is moving to (and
    /// has already moved the index, so a peek would point one track too far).
    private func canTakeOverPreload(_ pre: Composer) -> Bool {
        guard config.isGaplessPlaybackEnabled else { return false }
        guard pre.isBufferedAhead, __pendingNextEvents.failed == false else { return false }
        return true
    }

    /// The current track ran dry with a preloaded one waiting: move the
    /// playlist on to it and hand the output over.
    private func performGaplessHandoff() {
        guard let next = _nextComposer else { return }
        guard let url = playlist.nextURL(), url == next.url else {
            // The list or the loop pattern changed since the preload started, so
            // the buffered track is no longer the one up next.
            discardPreload()
            _isCalledDelayPaused = false
            pauseAll(after: 0)
            return
        }
        activatePreloadedTrack(next, preservePlaybackIntent: true)
    }

    /// Control-side tail. Built-in rendering only publishes atomic handoff/empty
    /// mailboxes; the player control queue consumes them before arriving here.
    /// A same-format handoff has already switched sources at the render boundary.
    /// Manual skips also enter here from their non-realtime caller.
    private func activatePreloadedTrack(_ next: Composer, preservePlaybackIntent: Bool = false) {
        let old = _currentComposer
        _nextComposer = nil
        if __pendingNextEvents.streamerEnded {
            _isSteamerEndEncounted = true
        }
        resetFlag()
        if __pendingNextEvents.streamerEnded {
            // `resetFlag` clears the flag asynchronously, so re-assert it after;
            // the new track's end detection must see the stream as ended from
            // its first `.empty` event on.
            _isSteamerEndEncounted = true
        }
        next.activate(preservePlaybackIntent: preservePlaybackIntent)
        _currentComposer = next
        old?.destroy()
        DispatchQueue.main.async { [weak self] in
            guard let sself = self else { return }
            sself.eventPipeline.call(.playEnded)
            sself.indexChanged()
            sself.replayPendingEvents()
            sself._nowPlayingInfo.play(elapsedPlayback: sself._player.currentTime())
            sself._isCalledDelayPaused = false
        }
    }

    private func replayPendingEvents() {
        let events = __pendingNextEvents.takeAll()
        for event in events {
            switch event {
            case .decoderEmptyEncountered:
                // End-of-track detection for the new track starts from its live
                // events; the ones collected while it was merely buffering are
                // stale and would make a short preloaded track end early.
                continue
            default:
                handleComposerEvent(event)
            }
        }
    }

    /// Starts buffering the next track ahead of the current one, once the
    /// current track's stream has been fully received.
    private func preloadNextTrack() {
        guard config.isGaplessPlaybackEnabled else { return }
        guard _nextComposer == nil else { return }
        guard let current = _currentComposer else { return }
        guard let url = playlist.peekNextURL() else { return }
        // Single-track loop would just rebuffer the track that is already
        // decoded, and `.stopWhenAllPlayed` has nothing after the last track.
        guard url != current.url else { return }
        let com = createComposer()
        _nextComposer = com
        // `preload` marks the composer as buffering ahead synchronously and
        // opens the stream off the main thread (see the comment there), so the
        // track is visible as the buffered one — and its events are withheld —
        // from the moment it is registered.
        com.bufferedAhead = { [weak self, weak com] in
            guard let self, let com else { return }
            com.armHandoff(valid: { [weak self, weak com] in
                guard let self, let com else { return false }
                return self._nextComposer === com &&
                    self.playlist.peekNextURL() == com.url
            }, completion: { [weak self] in self?.performGaplessHandoff() })
        }
        com.preload(url)
    }

    /// Drops the track buffering ahead of the current one. Called whenever the
    /// user moves somewhere else in the list, or the buffered track takes over.
    private func discardPreload() {
        _nextComposer?.destroy()
        _nextComposer = nil
        __pendingNextEvents.clear()
    }

    func pauseAll(after time: Float) {
        guard _isCalledDelayPaused == false else { return }
        _isCalledDelayPaused = true
        let delay = DispatchTimeInterval.milliseconds(Int(floor(time * 1000)))
        // Capture the track this end-of-track pause was scheduled for. If the
        // user switches tracks before it fires, the stale pause must not stop
        // the new track's output unit — the new composer resumes it on its own
        // schedule — and must not advance the list either.
        let scheduledFor = _currentComposer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self._currentComposer === scheduledFor else {
                self._isCalledDelayPaused = false
                return
            }
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
        // `com` is captured weakly: the pipeline lives on the composer, so a
        // strong capture would be a cycle. While the composer buffers ahead of
        // the current track its events are collected instead of forwarded.
        com.eventPipeline.delegate(to: self) { [weak com] obj, event in
            if let composer = com, composer.isPreloadAhead {
                obj.queuePreloadEvent(event)
                return
            }
            guard let composer = com, obj._currentComposer === composer else { return }
            obj.handleComposerEvent(event)
        }
        return com
    }

    private func queuePreloadEvent(_ event: Composer.Event) {
        __pendingNextEvents.append(event)
    }

    /// Every event of the *current* composer flows through here, and so do the
    /// replayed events of the track that just took over from it.
    func handleComposerEvent(_ event: Composer.Event) {
        switch event {
        case let .seekable(value):
            eventPipeline.call(.seekable(value))
        case let .buffering(p):
            eventPipeline.call(.buffering(p))
        case .streamerEndEncountered:
            _isSteamerEndEncounted = true
            eventPipeline.call(.streamerEndEncountered)
            preloadNextTrack()
        case let .duration(value):
            eventPipeline.call(.duration(value))
            _nowPlayingInfo.duration = value
            _nowPlayingInfo.update()
        case let .error(err):
            eventPipeline.call(.error(err))
        case .decoderEmptyEncountered:
            checkPlayEnded()
        case let .unknown(error):
            let state = APlay.State.unknown(error)
            self.state = state
            eventPipeline.call(.state(state))
        case let .flac(value):
            eventPipeline.call(.flac(value))
        case let .metadata(values):
            metadatas = values
            eventPipeline.call(.metadata(values))
            guard config.isAutoFillID3InfoToNowPlayingCenter else { return }
            for val in values {
                switch val {
                case let .album(text): _nowPlayingInfo.album = text
                case let .artist(text): _nowPlayingInfo.artist = text
                case let .title(text): _nowPlayingInfo.name = text
                    case let .cover(cov): _nowPlayingInfo.artwork = APlayImage(data: cov)
                default: break
                }
            }
            _nowPlayingInfo.update()
        }
    }

    private func addInteruptOb() {
        config.logger.log("config.isAutoHandlingInterruptEvent: \(config.isAutoHandlingInterruptEvent)", to: .player)
        guard config.isAutoHandlingInterruptEvent else { return }
        #if os(iOS) || os(visionOS)
            /// RouteChange

            let note1 = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {[weak self] (note) in
                let interuptionDict = note.userInfo
                // "Headphone/Line was pulled. Stopping player...."
                self?.config.logger.log("routeChange: \(interuptionDict ?? [:])", to: .player)
                if let routeChangeReason = interuptionDict?[AVAudioSessionRouteChangeReasonKey] as? UInt, routeChangeReason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.config.logger.log("routeChange pause", to: .player)
                    self?.pause()
                }
            }

            let note2 = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self](note) -> Void in
                guard let sself = self else { return }
                let info = note.userInfo
                sself.config.logger.log("interruption event \(info ?? [:])", to: .player)
                guard let type = info?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    // 中断开始
                    let playing = sself.state.isPlaying
                    sself._isPlayingBeforeInterrupt = playing
                    if playing { sself.pause() }
                } else {
                    // 中断结束
                    guard let options = info?[AVAudioSessionInterruptionOptionKey] as? UInt, options == AVAudioSession.InterruptionOptions.shouldResume.rawValue, sself._isPlayingBeforeInterrupt else { return }
                    sself.resume()
                }
            }
            _obs = [note1, note2]
        #endif
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
        get { __delayPausedLock.lock(); defer { __delayPausedLock.unlock() }; return __isCalledDelayPaused }
        // Synchronous, not a queued barrier: the end-of-track sequence is a
        // check-then-act pair (read the flag, set it, schedule the pause), and an
        // async write lets a second decoder tick read a stale `false` before the
        // write lands, scheduling two end-of-track sequences for one track. The
        // read also blocks on the properties queue's barrier, which the render
        // thread can starve.
        set { __delayPausedLock.lock(); __isCalledDelayPaused = newValue; __delayPausedLock.unlock() }
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

    private var _lastFrozenTime: Float {
        get { __frozenLock.lock(); defer { __frozenLock.unlock() }; return __lastFrozenTime }
        set { __frozenLock.lock(); __lastFrozenTime = newValue; __frozenLock.unlock() }
    }

    private var _frozenHitCount: Int {
        get { __frozenLock.lock(); defer { __frozenLock.unlock() }; return __frozenHitCount }
        set { __frozenLock.lock(); __frozenHitCount = newValue; __frozenLock.unlock() }
    }

    private var _currentComposer: Composer? {
        get { return _propertiesQueue.sync { __currentComposer } }
        set { _propertiesQueue.async(flags: .barrier) { self.__currentComposer = newValue } }
    }

    private var _nextComposer: Composer? {
        get { return _propertiesQueue.sync { __nextComposer } }
        set { _propertiesQueue.async(flags: .barrier) { self.__nextComposer = newValue } }
    }

    private var _isPlayingBeforeInterrupt: Bool {
        get { return _propertiesQueue.sync { __isPlayingBeforeInterrupt } }
        set { _propertiesQueue.async(flags: .barrier) { self.__isPlayingBeforeInterrupt = newValue } }
    }
}

// MARK: - Pending Events

/// Events of the composer that buffers one track ahead of the current one.
/// They are kept back until that track takes over, so the app never sees the
/// next track's duration/metadata/buffering while the current one is playing,
/// and nothing is lost at the handoff either.
private final class PendingComposerEvents {
    private let lock = NSLock()
    private var _events: [Composer.Event] = []

    func append(_ event: Composer.Event) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        _events.removeAll()
        lock.unlock()
    }

    /// The preloaded track's stream already reported end while it was buffering.
    /// The new track's end-of-track detection needs the state from its first
    /// `.empty` event on, which can arrive before the main-queue replay.
    var streamerEnded: Bool {
        return contains { if case .streamerEndEncountered = $0 { return true }; return false }
    }

    /// The preload hit an error, so it must not take over — the normal rebuild
    /// path replays the URL and surfaces the error.
    var failed: Bool {
        return contains { if case .error = $0 { return true }; return false }
    }

    private func contains(_ predicate: (Composer.Event) -> Bool) -> Bool {
        lock.lock()
        let value = _events.contains(where: predicate)
        lock.unlock()
        return value
    }

    func takeAll() -> [Composer.Event] {
        lock.lock()
        let events = _events
        _events.removeAll()
        lock.unlock()
        return events
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
    enum Event {
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
    enum State: @unchecked Sendable {
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
    enum Error: Swift.Error {
        case none, open(String), openedAlready(String), streamParse(String), network(String), networkPermission(String), reachMaxRetryTime, networkStatusCode(Int), parser(OSStatus), player(String), playItemNotFound(String)
    }
}
