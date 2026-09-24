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
        // Owned strongly: APlay holds this object for its whole lifetime, and
        // several of the methods below reach `_config` from async blocks whose
        // execution can outlive the APlay that owns the config — an `unowned`
        // reference there reads freed memory once teardown reordered.
        private var _config: ConfigurationCompatible

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
