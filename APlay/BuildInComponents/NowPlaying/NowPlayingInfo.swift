//
//  FreePlayer+MPPlayingCenter.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/3/1.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//
#if os(iOS)
    import MediaPlayer
#endif
extension APlay {
    final class NowPlayingInfo {
        var name = ""
        var artist = ""
        var album = ""
        var artwork: UIImage?
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
                map[MPMediaItemPropertyPlaybackDuration] = duration
                #if os(iOS)
                    if let image = artwork {
                        map[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: image)
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
            DispatchQueue.global(qos: .utility).async {
                let request = URLRequest(url: r, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
                if let d = URLCache.shared.cachedResponse(for: request)?.data, let image = UIImage(data: d) {
                    self._queue.sync { self.artwork = image }
                    self.update()
                    return
                }
                self._config.networkPolicy.requestPermission(for: r, handler: { [unowned self] success in
                    guard success else { return }
                    self.doRequest(request)
                })
            }
        }

        func update() {
            #if os(iOS)
                DispatchQueue.main.async {
                    let nowPlayingInfo = self.info
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                }
            #endif
        }

        func remove() {
            _queue.async(flags: .barrier) {
                self.name = ""
                self.artist = ""
                self.album = ""
                self.artwork = self._config.defaultCoverImage
                self.duration = 0
                self.playbackRate = 0
                self.playbackTime = 0
            }
            #if os(iOS)
                DispatchQueue.main.async {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
                guard let sself = self, let d = data, let image = UIImage(data: d) else { return }
                sself._queue.sync { sself.artwork = image }
                sself.update()
            })
            task.resume()
            _coverTask = task
        }
    }
}
