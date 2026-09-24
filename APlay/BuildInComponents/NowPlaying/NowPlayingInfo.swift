//
//  FreePlayer+MPPlayingCenter.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/3/1.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif
#if os(macOS) || os(iOS) || os(visionOS)
    import MediaPlayer
#endif
extension APlay {
    final class NowPlayingInfo: @unchecked Sendable {
        var name = ""
        var artist = ""
        var album = ""
        var artwork: APlayImage?
        var duration = 0
        var playbackRate: Float = 0
        var playbackTime: Float = 0
        private var _queue: DispatchQueue = DispatchQueue(concurrentName: "NowPlayingInfo")
        private var _coverTask: URLSessionDataTask?
        private unowned var _config: ConfigurationCompatible

        #if DEBUG
            deinit {
                debug_log("\(self) \(#function)")
            }
        #endif

        init(config: ConfigurationCompatible) {
            _config = config
        }

        var info: [String: Any] {
            return _queue.sync(execute: { () -> [String: Any] in
                var map = [String: Any]()
                map[MPMediaItemPropertyTitle] = name
                map[MPMediaItemPropertyArtist] = artist
                map[MPMediaItemPropertyAlbumTitle] = album
                map[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(playbackTime)
                map[MPNowPlayingInfoPropertyPlaybackRate] = Double(playbackRate)
                map[MPMediaItemPropertyPlaybackDuration] = Double(duration)
                #if os(iOS) || os(visionOS) || os(macOS)
                    if let image = artwork {
                        map[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    }
                #endif
                return map
            })
        }

        func play(elapsedPlayback: Float) {
            playbackTime = elapsedPlayback
            playbackRate = 1
            update()
        }

        func pause(elapsedPlayback: Float) {
            playbackTime = elapsedPlayback
            playbackRate = 0
            update()
        }

        func image(with url: String?) {
            guard let u = url, let r = URL(string: u) else { return }
            _coverTask?.cancel()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                let request = URLRequest(url: r, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
                if let d = URLCache.shared.cachedResponse(for: request)?.data, let image = APlayImage(data: d) {
                    self._queue.sync { self.artwork = image }
                    self.update()
                    return
                }
                self._config.networkPolicy.requestPermission(for: r, handler: { [weak self] success in
                    guard success, let self = self else { return }
                    self.doRequest(request)
                })
            }
        }

        func update() {
            #if os(iOS) || os(visionOS)
                DispatchQueue.main.async {
                    let nowPlayingInfo = self.info
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                }
            #elseif os(macOS)
                DispatchQueue.main.async {
                    let center = MPNowPlayingInfoCenter.default()
                    center.nowPlayingInfo = self.info
                    // macOS only routes headset and media-key events to the Now
                    // Playing app; an app claims the slot by announcing state.
                    center.playbackState = self.playbackRate > 0 ? .playing : .paused
                }
            #endif
        }

        func remove() {
            // A barrier *sync* so the clear has already happened when this
            // returns. The caller (`_play`) writes the next track's metadata
            // straight after; with an async barrier that clear could still be
            // queued and would wipe the write. `remove` is only ever called
            // from `resetFlag` on the caller's thread, never from inside
            // `_queue`, so this cannot deadlock.
            _queue.sync(flags: .barrier) {
                self.name = ""
                self.artist = ""
                self.album = ""
                self.artwork = self._config.defaultCoverImage
                self.duration = 0
                self.playbackRate = 0
                self.playbackTime = 0
            }
            #if os(iOS) || os(visionOS)
                DispatchQueue.main.async {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                }
            #elseif os(macOS)
                DispatchQueue.main.async {
                    let center = MPNowPlayingInfoCenter.default()
                    center.nowPlayingInfo = nil
                    center.playbackState = .stopped
                }
            #endif
        }

        /// Writes a track's metadata in one go, in place of the scattered
        /// `metadataUpdate` setters. Call this after `remove()` has cleared the
        /// previous track and before `play()`/`update()` publishes, so a track
        /// change never leaves the Now Playing card describing the old track or
        /// an empty one. The artwork URL (if any) is fetched asynchronously
        /// through `image(with:)`, which publishes on its own when it lands.
        func apply(_ metadata: APlay.NowPlayingMetadata) {
            if let title = metadata.title { name = title }
            if let artist = metadata.artist { self.artist = artist }
            if let album = metadata.album { self.album = album }
            if let image = metadata.artwork { artwork = image }
            if let artworkURL = metadata.artworkURL { image(with: artworkURL) }
        }

        private func doRequest(_ request: URLRequest) {
            _config.startBackgroundTask(isToDownloadImage: true)
            let task = _config.session.dataTask(with: request, completionHandler: { [weak self] data, resp, _ in
                if let r = resp, let d = data {
                    let cre = CachedURLResponse(response: r, data: d)
                    URLCache.shared.storeCachedResponse(cre, for: request)
                }
                guard let sself = self, let d = data, let image = APlayImage(data: d) else { return }
                sself._queue.sync { sself.artwork = image }
                sself.update()
            })
            task.resume()
            _coverTask = task
        }
    }
}
