//
//  Streamer.swift
//  APlayer
//
//  Created by lincoln on 2018/4/11.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation

// MARK: - Streamer

final class Streamer: StreamProviderCompatible, @unchecked Sendable {
    var outputPipeline = Delegated<StreamProvider.Event, Void>()

    var position: StreamProvider.Position = 0
    var contentLength: UInt = 0
    var info = StreamProvider.URLInfo.none
    var registerHeader: [String: Any] = [:]

    var bufferingProgress: Float {
        guard contentLength > 0 else { return 0 }
        // A resumed stream buffers ahead of the playhead: the table's byte count
        // is how far playback can reach, not how far it has gone.
        if let resume = resumeCache() {
            return Float(resume.downloadedBytes) / Float(contentLength)
        }
        let start = Float(position) + Float(_bytesRead)
        return start / Float(contentLength)
    }

    private unowned let _config: ConfigurationCompatible

    private let _openLock = NSLock()
    private var _isOpened = false

    /// Owns the Streamer as its `URLSessionDataDelegate` through a weak bridge, so
    /// that `Streamer.deinit` still runs (a session strongly retains its delegate).
    private let _urlSession: URLSession
    private var _task: URLSessionDataTask?
    private var _isSuspended = false

    /// Backing storage for local files. URLSession offers no seek for `file://`
    /// URLs, so local playback reads through `FileHandle` instead.
    private var _fileHandle: FileHandle?
    private let _localLock = NSLock()
    private var _isRunningLocal = false

    /// Serializes every remote state mutation: URLSession delegate callbacks,
    /// reconnect watchdog timers and task lifecycle (open/pause/resume/destroy).
    private let _stateQueue = DispatchQueue(label: "com.SelfStudio.APlay.Streamer.state")
    /// Runs the blocking local-file read loop.
    private let _readQueue = DispatchQueue(label: "com.SelfStudio.APlay.Streamer.read", qos: .userInitiated)

    private lazy var _cacheInfo = CacheInfo(config: self._config)
    private lazy var _icyCastInfo = IcyCastInfo()
    private lazy var _watchDogInfo = WatchDogInfo(maxRemoteStreamOpenRetry: UInt(self._config.maxRemoteStreamOpenRetry), queue: self._stateQueue)
    private var _bytesRead: UInt = 0
    private var _tagParser: MetadataParserCompatible?
    private var _isFirstPacket = true

    /// Resume-cache state for a remote stream whose bytes are laid out in a
    /// preallocated `.part` container: either a partial container the URL
    /// already has, or one the response's content length let us preallocate.
    private let _resumeLock = NSLock()
    private var _resume: ResumeCache?
    /// The offset the active download asked the server to start at, so a 206's
    /// `Content-Range` can be checked against it.
    private var _resumeDownloadStart: UInt64 = 0

    /// Reads the resume cache under its lock: the network callbacks and the
    /// local read loop reach it from different queues.
    @inline(__always)
    private func resumeCache() -> ResumeCache? {
        _resumeLock.lock()
        defer { _resumeLock.unlock() }
        return _resume
    }

    private func setResume(_ cache: ResumeCache?) {
        _resumeLock.lock()
        _resume = cache
        _resumeLock.unlock()
    }

    /// A sweep of the cache directory, once per process, before the cache is
    /// first written into. Running it here keeps the write path free of bookkeeping
    /// and guarantees the evicted entries are not the ones being opened.
    private static var _hasSweptDiskCache = false
    private static let _sweepLock = NSLock()

    deinit {
        // URLSession retains its delegate until invalidated, even after all
        // data tasks end. This must run in Release too: dropping the Streamer
        // alone otherwise leaves a session + weak delegate bridge per track.
        _urlSession.invalidateAndCancel()
        debug_log("\(self) \(#function)")
    }

    init(config: ConfigurationCompatible) {
        _config = config
        let bridge = SessionDataDelegate(proxyPolicy: config.proxyPolicy)
        // Inherit the caller's configuration (proxy dictionary, TLS policy, …)
        // while keeping the data delegate to ourselves. The weak back-reference
        // is wired after `self` is fully initialized.
        _urlSession = URLSession(configuration: config.session.configuration, delegate: bridge, delegateQueue: nil)
        bridge.streamer = self
    }

    private func tagParser(for urlInfo: StreamProvider.URLInfo) -> MetadataParserCompatible? {
        var parser = _config.metadataParserBuilder(urlInfo.fileHint, _config)
        if parser == nil {
            if info.fileHint == .mp3 {
                parser = ID3Parser(config: _config)
            } else if info.fileHint == .flac {
                parser = FlacParser(config: _config)
            } else {
                outputPipeline.call(.metadata([]))
                return nil
            }
        }

        parser?.outputStream.delegate(to: self) { sself, value in
            switch value {
            case let .metadata(data): sself.outputPipeline.call(.metadata(data))
            case let .tagSize(size): sself.outputPipeline.call(.metadataSize(size))
            case let .flac(value): sself.outputPipeline.call(.flac(value))
            default: break
            }
        }
        return parser
    }
}

// MARK: - StreamDataSource

extension Streamer {
    func open(url: URL, at position: StreamProvider.Position) {
        _openLock.lock()
        guard _isOpened == false else {
            _openLock.unlock()
            outputPipeline.call(.errorOccurred(.openedAlready("stream already open")))
            return
        }
        _isOpened = true
        _openLock.unlock()
        reset(url: url)
        guard info.isRemote else {
            _stateQueue.async { self._open(at: position) }
            return
        }
        _config.networkPolicy.requestPermission(for: info.url, handler: { [weak self] success in
            guard let self = self else { return }
            guard success else {
                let err = APlay.Error.networkPermission("No permission for accessing network")
                self.outputPipeline.call(.errorOccurred(err))
                return
            }
            self._stateQueue.async { self._open(at: position) }
        })
    }

    func destroy() {
        // Cleared synchronously so an open() that follows immediately is not
        // rejected by the single-open guard; the teardown itself is queued.
        _openLock.lock()
        _isOpened = false
        _openLock.unlock()
        _stateQueue.async { self.close(resetTimer: true) }
    }

    func pause() {
        _stateQueue.async {
            self.setLocalRunning(false)
            guard self._isSuspended == false else { return }
            self._isSuspended = true
            self._task?.suspend()
        }
    }

    func resume() {
        _stateQueue.async {
            if self._isSuspended {
                self._isSuspended = false
                self._task?.resume()
            }
            self.startLocalReadLoopIfNeeded()
        }
    }

    /// Cancels the current task (if any) and closes the local file handle.
    /// Must run on `_stateQueue`.
    private func close(resetTimer: Bool) {
        if let task = _task {
            _task = nil
            _isSuspended = false
            // Cancel before clearing the reference is racy the other way: the
            // completion callback would find `task === _task` still true. Drop the
            // reference first so the callback is ignored by identity.
            task.cancel()
        }
        setLocalRunning(false)
        if let handle = _fileHandle {
            _fileHandle = nil
            try? handle.close()
        }
        if let resume = resumeCache() {
            resume.close()
            setResume(nil)
            _resumeDownloadStart = 0
        }
        guard info.isRemote else { return }
        if resetTimer { _watchDogInfo.reset() }
    }

    /// Cancels the in-flight download but leaves the container and the local
    /// reader running, so a reconnect writes into the same `.part` and the read
    /// loop bridges the gap by waiting on the next block. Must run on
    /// `_stateQueue`.
    private func cancelDownload() {
        if let task = _task {
            _task = nil
            _isSuspended = false
            task.cancel()
        }
        resumeCache()?.flushMeta()
    }

    private func reset(url: URL) {
        _stateQueue.sync { self.close(resetTimer: true) }
        _icyCastInfo.reset()
        _watchDogInfo.reset()
        _cacheInfo.reset(url: url)
        _bytesRead = 0
        info = StreamProvider.URLInfo(url: url)
        position = 0
        if info.isRemote {
            // The sweep belongs ahead of any cache write, and the name it must
            // spare is this track's — the oldest entry on a full disk could
            // otherwise be the one about to play.
            sweepDiskCacheOnce(protecting: url)
        }
        if let cachedInfo = asCachedFileInfo() {
            info = cachedInfo
        } else if let resume = openResumeCache(for: url) {
            // A partial container replays its cached blocks locally while the
            // network tops it up, so the stream reads through the same file
            // handle as a finished cache hit.
            setResume(resume)
            info = .local(resume.containerURL, info.fileHint)
        }
        contentLength = info.localContentLength()
        if let resume = resumeCache() { contentLength = UInt(resume.contentLength) }
        _tagParser = tagParser(for: info)
        _config.logger.log("\(info)", to: .streamProvider)
    }

    /// Scans the cache directory once per process, evicting the oldest entries
    /// until the allocated bytes fit `maxDiskCacheSize`.
    private func sweepDiskCacheOnce(protecting url: URL) {
        guard _config.cachePolicy.isEnabled else { return }
        Self._sweepLock.lock()
        let alreadySwept = Self._hasSweptDiskCache
        Self._hasSweptDiskCache = true
        Self._sweepLock.unlock()
        guard alreadySwept == false else { return }
        DiskCacheCleaner().sweepIfNeeded(cacheDirectory: _config.cacheDirectory,
                                          maxSize: UInt64(_config.maxDiskCacheSize),
                                          excluding: [_config.cacheNaming.name(for: url)],
                                          log: { [weak self] message in
                                            self?._config.logger.log(message, to: .streamProvider)
                                          })
    }

    /// Looks for a container a previous session left partly filled for this URL,
    /// so its cached blocks can be replayed and only the remainder fetched.
    private func openResumeCache(for url: URL) -> ResumeCache? {
        guard _config.cachePolicy.isEnabled, let name = _cacheInfo.cacheName else { return nil }
        return ResumeCache.open(name: name, cacheDirectory: _config.cacheDirectory, expectedOriginURL: url)
    }

    private func setLocalRunning(_ value: Bool) {
        _localLock.lock()
        _isRunningLocal = value
        _localLock.unlock()
    }

    /// Resumes the local read loop if a file handle is still open.
    /// Must run on `_stateQueue`.
    @discardableResult
    private func startLocalReadLoopIfNeeded() -> Bool {
        _localLock.lock()
        let handle = _fileHandle
        if handle != nil { _isRunningLocal = true }
        _localLock.unlock()
        guard handle != nil else { return false }
        _readQueue.async { [weak self] in
            self?.localReadLoop()
        }
        return true
    }
}

// MARK: - Open

private extension Streamer {
    /// Entrypoint for both local and remote sources. Runs on `_stateQueue`.
    func _open(at position: StreamProvider.Position) {
        self.position = position
        switch info {
        case .local:
            do {
                try openLocal(at: position)
            } catch {
                let e = error as? APlay.Error ?? APlay.Error.open("open local failed: \(error)")
                outputPipeline.call(.errorOccurred(e))
            }
            // A reopened partial container is read locally and filled by a
            // download that starts alongside it.
            if resumeCache() != nil {
                startResumeDownload(at: UInt64(position))
            }
        case .remote:
            openRemote(at: position)
        case .unknown:
            outputPipeline.call(.errorOccurred(.open("Unknown how to handle url: \(info.url.absoluteString)")))
        }
    }

    func openLocal(at position: StreamProvider.Position) throws {
        guard case let .local(url, _) = info else {
            throw APlay.Error.open("not a local url")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw APlay.Error.open("file not exists: \(url)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        if position > 0 {
            try handle.seek(toOffset: UInt64(position))
        }
        _localLock.lock()
        _fileHandle = handle
        _isRunningLocal = true
        _localLock.unlock()
        if position == 0 { _tagParser?.parseID3V1Tag(at: info.url) }
        _isFirstPacket = true
        _readQueue.async { [weak self] in
            self?.localReadLoop()
        }
    }

    func openRemote(at position: StreamProvider.Position) {
        guard case let .remote(url, _) = info else {
            outputPipeline.call(.errorOccurred(.open("not a remote url")))
            return
        }
        // A partial container already holds the track's opening, so ask only for
        // what the table says is missing; the play position is the floor.
        let start = resumeDownloadStart(for: UInt64(position))
        _resumeDownloadStart = start
        var request = URLRequest(url: url)
        request.httpMethod = Keys.get.rawValue
        request.setValue(_config.userAgent, forHTTPHeaderField: Keys.userAgent.rawValue)
        request.setValue(Keys.icyMetaDataValue.rawValue, forHTTPHeaderField: Keys.icyMetadata.rawValue)
        if start > 0 {
            request.setValue("bytes=\(start)-", forHTTPHeaderField: Keys.range.rawValue)
        }
        // Let the server judge whether the content moved: a 206 keeps the cached
        // bytes, a 200 discards them.
        if let ifRange = resumeCache()?.ifRangeValue {
            request.setValue(ifRange, forHTTPHeaderField: Keys.ifRange.rawValue)
        }
        for (key, value) in _config.predefinedHttpHeaderValues {
            debug_log("Setting predefined HTTP header[\(key) : \(value)]")
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = _urlSession.dataTask(with: request)
        _task = task
        // A pause may have been queued before the task existed; carry it over.
        if _isSuspended { task.suspend() }
        if position == 0 { _tagParser?.parseID3V1Tag(at: info.url) }
        _watchDogInfo.reopenTimes += 1
        _watchDogInfo.isReadedData = false
        _isFirstPacket = true
        _config.logger.log("open at \(position) (downloading from \(start))", to: .streamProvider)
        task.resume()
    }

    /// Where a download should ask the server to start: the play position, or —
    /// when a partial container already covers its opening — the first block the
    /// table does not vouch for, so the cached bytes are not re-fetched.
    private func resumeDownloadStart(for position: UInt64) -> UInt64 {
        guard let resume = resumeCache() else { return position }
        return max(position, resume.firstMissingOffset())
    }

    /// Starts the download that fills an already-open container. Mirrors
    /// `openRemote(at:)` against the container's origin URL, which `info` no
    /// longer carries once the stream reads locally. Must run on `_stateQueue`.
    private func startResumeDownload(at position: UInt64) {
        guard let resume = resumeCache() else { return }
        let start = max(position, resume.firstMissingOffset())
        _resumeDownloadStart = start
        resume.setWriteOffset(start)

        var request = URLRequest(url: resume.originURL)
        request.httpMethod = Keys.get.rawValue
        request.setValue(_config.userAgent, forHTTPHeaderField: Keys.userAgent.rawValue)
        request.setValue(Keys.icyMetaDataValue.rawValue, forHTTPHeaderField: Keys.icyMetadata.rawValue)
        if start > 0 {
            request.setValue("bytes=\(start)-", forHTTPHeaderField: Keys.range.rawValue)
        }
        if let ifRange = resume.ifRangeValue {
            request.setValue(ifRange, forHTTPHeaderField: Keys.ifRange.rawValue)
        }
        for (key, value) in _config.predefinedHttpHeaderValues {
            debug_log("Setting predefined HTTP header[\(key) : \(value)]")
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = _urlSession.dataTask(with: request)
        _task = task
        if _isSuspended { task.suspend() }
        _watchDogInfo.reopenTimes += 1
        _watchDogInfo.isReadedData = false
        _isFirstPacket = true
        _config.logger.log("resume download from \(start) of \(resume.contentLength)", to: .streamProvider)
        task.resume()
    }
}

// MARK: - Local file reading

private extension Streamer {
    /// Blocking read loop on `_readQueue`. `readyForRead` is posted first so the
    /// downstream parser exists before the first chunk arrives — mirroring the
    /// old CFReadStream ordering where local files became readable instantly.
    func localReadLoop() {
        outputPipeline.call(.readyForRead)
        while true {
            _localLock.lock()
            let running = _isRunningLocal
            let handle = _fileHandle
            _localLock.unlock()
            guard running, let handle else { return }

            // A resumed stream may be read faster than it is filled: the block
            // ahead can still be a sparse hole. Wait for the writer to close it
            // rather than serve the hole's zeros — a pause or a teardown breaks
            // this wait through `_isRunningLocal`.
            if resumeReaderShouldWait(at: handle.offsetInFile) {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            // FileHandle returns autoreleased NSData backing its Swift Data.
            // This dispatch block may run for an entire track (and block on
            // decoder backpressure), so its outer pool is not drained per read.
            // Keep the pool around BOTH reading and synchronous delivery: the
            // raw pointer must remain valid through parser/decoder callbacks.
            let delivered = autoreleasepool { () -> Bool in
                guard let chunk = try? handle.read(upToCount: 8192), !chunk.isEmpty else { return false }
                deliverLocalData(chunk)
                return true
            }
            guard delivered else { break }
        }
        // EOF (not pause/destroy) is the only path that posts `.endEncountered`.
        _localLock.lock()
        let reachedEOF = _isRunningLocal
        if reachedEOF { _isRunningLocal = false }
        _localLock.unlock()
        guard reachedEOF else { return }
        outputPipeline.call(.endEncountered)
    }

    /// Whether the next pull would enter a block the resume table has not marked
    /// whole. Always false for a plain local file, which has no holes.
    private func resumeReaderShouldWait(at offset: UInt64) -> Bool {
        guard let resume = resumeCache() else { return false }
        return resume.bitmapContains(offset: offset) == false
    }

    private func deliverLocalData(_ data: Data) {
        let count = UInt32(data.count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let pointer = UnsafeMutablePointer(mutating: base)
            if position == 0 { _tagParser?.acceptInput(data: pointer, count: count) }
            outputPipeline.call(.hasBytesAvailable(pointer, count, _isFirstPacket))
        }
        if _isFirstPacket { _isFirstPacket = false }
        _bytesRead += UInt(count)
    }
}

// MARK: - URLSession delegate bridging

private extension Streamer {
    /// Weak bridge so the session never outlives-captures the Streamer.
    final class SessionDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var streamer: Streamer?
        let proxyPolicy: APlay.Configuration.ProxyPolicy

        init(proxyPolicy: APlay.Configuration.ProxyPolicy) {
            self.proxyPolicy = proxyPolicy
        }

        func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            streamer?._enqueue { $0.handle(response: response, completionHandler: completionHandler) }
        }

        func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
            streamer?._enqueue { $0.handle(data: data) }
        }

        func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            streamer?._enqueue { $0.handle(task: task, error: error) }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Mirrors `Configuration.SessionDelegate`: custom proxy credentials,
            // otherwise let the system handle trust and keychain challenges.
            if case let APlay.Configuration.ProxyPolicy.custom(info) = proxyPolicy {
                completionHandler(.useCredential, URLCredential(user: info.username, password: info.password, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func urlSession(_: URLSession, didBecomeInvalidWithError _: Error?) {
            streamer?._enqueue { streamer in
                streamer._task = nil
                streamer._isSuspended = false
            }
        }
    }

    func _enqueue(_ block: @escaping (Streamer) -> Void) {
        // The URLSession completion handlers we forward are not Sendable on every
        // SDK; the block is queued onto a serial queue and invoked exactly once.
        nonisolated(unsafe) let captured = block
        _stateQueue.async { [weak self] in
            guard let self = self else { return }
            captured(self)
        }
    }
}

// MARK: - URLSession callbacks (run on _stateQueue)

private extension Streamer {
    /// Status codes that arm the reconnect watchdog rather than failing at
    /// once: the server may recover (5xx) or the session delegate may answer
    /// the authentication challenge (401/407).
    static func isRetryableStatus(_ statusCode: Int) -> Bool {
        return statusCode == 401 || statusCode == 407 || (500 ... 599).contains(statusCode)
    }

    /// Status code of the response the current task is handling, if any.
    private var currentResponseStatus: Int {
        return (_task?.response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func handle(response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            // Not HTTP: nothing to parse, the caller may still stream bytes.
            contentLength = max(contentLength, UInt(max(response.expectedContentLength, 0)))
            outputPipeline.call(.readyForRead)
            completionHandler(.allow)
            return
        }
        let statusCode = http.statusCode
        for key in _config.httpFileCompletionValidator.keys {
            if let value = http.value(forHTTPHeaderField: key) {
                registerHeader[key] = value
            }
        }
        /*
         * If the server responded with the icy-metaint header, the response
         * body will be encoded in the ShoutCast protocol.
         */
        if let metaint = http.value(forHTTPHeaderField: Keys.icyMetaint.rawValue) {
            _icyCastInfo.isIcyStream = true
            _icyCastInfo.metaDataInterval = Int(metaint) ?? 0
            _config.logger.log("\(Keys.icyMetaint.rawValue): \(_icyCastInfo.metaDataInterval)", to: .streamProvider)
        } else if let notice = http.value(forHTTPHeaderField: Keys.icyNotice1.rawValue) {
            _icyCastInfo.isIcyStream = true
            _config.logger.log("\(Keys.icyNotice1.rawValue): \(notice)", to: .streamProvider)
        }
        if let name = http.value(forHTTPHeaderField: Keys.icyName.rawValue) {
            _icyCastInfo.name = name
            outputPipeline.call(.metadata([.title(name)]))
        }
        if let contentType = http.value(forHTTPHeaderField: Keys.contentType.rawValue) {
            if case let .remote(url, hint) = info {
                let newHint = StreamProvider.URLInfo.fileHint(from: contentType)
                if newHint != .mp3, hint != newHint {
                    info = .remote(url, newHint)
                    _tagParser = tagParser(for: info)
                }
            }
            _config.logger.log("\(Keys.contentType.rawValue): \(contentType)", to: .streamProvider)
        }

        switch statusCode {
        case 200, 206:
            if resumeCache() != nil {
                // Already reading the container: the range we got must be the one
                // we asked for, and the length the one we cached.
                handleResumeResponse(http, statusCode: statusCode)
            } else if let length = responseContentLength(http, statusCode: statusCode) {
                // A known length means the body can be laid out in a container,
                // which makes this stream resumable from here on. The read loop
                // posts `.readyForRead` once the container is open.
                beginResumeDownload(http: http, contentLength: length)
            } else {
                if let len = http.value(forHTTPHeaderField: Keys.contentLength.rawValue).flatMap({ UInt($0) }) {
                    if statusCode == 206 {
                        contentLength = len + position
                    } else {
                        contentLength = len
                    }
                    _config.logger.log("\(statusCode) Content Length:\(contentLength)", to: .streamProvider)
                }
                outputPipeline.call(.readyForRead)
            }
        case 401, 407:
            // The challenge is answered in the session delegate; if the server
            // still answers with 401/407 the reconnect watchdog takes over.
            _config.logger.log("Did receive authentication challenge (\(statusCode))", to: .streamProvider)
            _watchDogInfo.prepareForRetry()
            startReconnectWatchDog()
        case 500 ... 599:
            _config.logger.log("Server error:\(statusCode)", to: .streamProvider)
            _watchDogInfo.prepareForRetry()
            startReconnectWatchDog()
        default:
            outputPipeline.call(.errorOccurred(.networkStatusCode(statusCode)))
        }
        completionHandler(.allow)
    }

    func handle(data: Data) {
        if info.isRemote || resumeCache() != nil {
            if Self.isRetryableStatus(currentResponseStatus) {
                // An error page is not audio: keep the watchdog armed (see
                // `handleEndEncountered`) and keep the bytes out of the
                // decoder and the cache.
                return
            }
            _watchDogInfo.reset()
            _watchDogInfo.isReadedData = true
        }
        let count = UInt32(data.count)
        if _icyCastInfo.isIcyStream {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                _icyCastInfo.parseICYStream(streamer: self, buffers: UnsafeMutablePointer(mutating: base), bufSize: Int(count))
            }
        } else if let resume = resumeCache() {
            // The container is the buffer: the read loop hands these bytes to
            // the decoder once the block closes, so nothing is posted here —
            // posting would feed the parser twice.
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                _ = resume.write(bytes: UnsafeMutablePointer(mutating: base), count: Int(count))
            }
        } else {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let pointer = UnsafeMutablePointer(mutating: base)
                _cacheInfo.write(bytes: pointer, count: Int(count))
                if position == 0 { _tagParser?.acceptInput(data: pointer, count: count) }
                outputPipeline.call(.hasBytesAvailable(pointer, count, _isFirstPacket))
            }
            if _isFirstPacket { _isFirstPacket = false }
        }
        _bytesRead += UInt(count)
    }

    func handle(task: URLSessionTask, error: Error?) {
        // Ignore callbacks from tasks that were already replaced or cancelled.
        guard task === _task else { return }
        if let error {
            handleStreamError(error)
        } else {
            handleEndEncountered()
        }
    }

    private func handleEndEncountered() {
        guard info.isRemote || resumeCache() != nil else { return }
        let statusCode = currentResponseStatus
        if Self.isRetryableStatus(statusCode) { return }

        if let resume = resumeCache() {
            // The read loop owns end-of-stream for the container; the network
            // side only tops it up when the download stopped short of the end.
            let frontier = resume.writeOffset
            if frontier < UInt64(contentLength), contentLength > 0 {
                _config.logger.log("Resume stream ended at \(frontier) of \(contentLength), restarting the download", to: .streamProvider)
                cancelDownload()
                startReconnectWatchDog(notStreamingEnd: true)
            } else if resume.isComplete == false,
                      resume.firstMissingOffset() < UInt64(contentLength) {
                // A seek past the gap left a hole behind the play point: the
                // tail is whole but the middle is not, so promote() would refuse
                // it. Refill from the first missing block; the next
                // end-of-download promotes the now-complete container.
                let hole = resume.firstMissingOffset()
                _config.logger.log("Resume download reached the end with a hole at \(hole) of \(contentLength); refilling", to: .streamProvider)
                _watchDogInfo.reset()
                startResumeDownload(at: hole)
            } else {
                _watchDogInfo.reset()
                promoteResumeCache()
            }
            return
        }

        let read = _bytesRead + position
        if read < contentLength, contentLength > 0 {
            _config.logger.log("HTTP stream end encountered whithout streamimg all content[\(contentLength)] , restart at postion \(read)", to: .streamProvider)
            close(resetTimer: true)
            startReconnectWatchDog(notStreamingEnd: true)
        } else {
            _watchDogInfo.reset()
            outputPipeline.call(.endEncountered)
            guard _icyCastInfo.isIcyStream == false else { return }
            _cacheInfo.writeFile(targetLength: contentLength, url: info.url, header: registerHeader)
        }
    }

    private func handleStreamError(_ error: Error) {
        let nsError = error as NSError
        guard (info.isRemote || resumeCache() != nil),
              nsError.domain == NSURLErrorDomain,
              nsError.code != NSURLErrorCancelled else { return }
        let read = _bytesRead + position
        if read < contentLength, contentLength > 0 {
            _watchDogInfo.startWatchDog(with: 2) { [weak self] reachMaxRetryTime in
                guard let sself = self else { return }
                if reachMaxRetryTime {
                    sself.reachMaxRetryAndStopWatchDog()
                    return
                }
                // A resumed download picks up inside the container it already
                // filled; the local reader stays open across the reconnect.
                if sself.resumeCache() != nil {
                    sself.cancelDownload()
                    guard sself.reconnectResumeDownload() else {
                        sself._watchDogInfo.invalidateTimer()
                        let error = APlay.Error.streamParse("Resume position exceeded content length[\(sself.contentLength)]")
                        sself.outputPipeline.call(.errorOccurred(error))
                        return
                    }
                    return
                }
                let p = StreamProvider.Position(sself.position + sself._bytesRead)
                sself.close(resetTimer: false)
                guard p < sself.contentLength else {
                    sself._watchDogInfo.invalidateTimer()
                    let error = APlay.Error.streamParse("Start position[\(p)] exceeded content length[\(sself.contentLength)]")
                    sself.outputPipeline.call(.errorOccurred(error))
                    return
                }
                sself._bytesRead = 0
                sself._open(at: p)
            }
        } else {
            _watchDogInfo.invalidateTimer()
            outputPipeline.call(.errorOccurred(.network(error.localizedDescription)))
        }
    }
}

// MARK: - Resume cache plumbing

private extension Streamer {
    /// Total body length a response carries: a 206 announces it in
    /// `Content-Range`, any status in `Content-Length`.
    func responseContentLength(_ http: HTTPURLResponse, statusCode: Int) -> UInt64? {
        if statusCode == 206 {
            // A conformant 206 names the whole resource in `Content-Range`.
            // Without it `Content-Length` is only the slice that was requested,
            // so the slice's start has to be added back to recover the total.
            if let total = contentRange(http)?.split(separator: "/").last,
               let value = UInt64(total) {
                return value
            }
            if let len = http.value(forHTTPHeaderField: Keys.contentLength.rawValue).flatMap({ UInt64($0) }) {
                return len + _resumeDownloadStart
            }
            return nil
        }
        if let len = http.value(forHTTPHeaderField: Keys.contentLength.rawValue).flatMap({ UInt64($0) }) { return len }
        return nil
    }

    /// The `Content-Range` header's start, or `nil` when the server reports an
    /// unsatisfiable range (`bytes */total`) — not a range to resume from.
    func contentRangeStart(_ http: HTTPURLResponse) -> UInt64? {
        guard let range = contentRange(http) else { return nil }
        guard let span = range.split(separator: "/").first,
              let start = span.split(separator: "-").first else { return nil }
        return UInt64(start)
    }

    private func contentRange(_ http: HTTPURLResponse) -> String? {
        guard var value = http.value(forHTTPHeaderField: Keys.contentRange.rawValue) else { return nil }
        if value.hasPrefix("bytes ") { value = String(value.dropFirst(6)) }
        guard value.contains("/") else { return nil }
        return value
    }

    /// Lays out a freshly known body in a preallocated container and switches
    /// the stream to reading it locally, which is what makes the download
    /// resumable. Runs on `_stateQueue`.
    func beginResumeDownload(http: HTTPURLResponse, contentLength length: UInt64) {
        guard _icyCastInfo.isIcyStream == false else { return }
        guard let name = _cacheInfo.cacheName else { return }
        guard let resume = ResumeCache.create(name: name,
                                              cacheDirectory: _config.cacheDirectory,
                                              originURL: info.url,
                                              contentLength: length,
                                              etag: http.value(forHTTPHeaderField: Keys.etag.rawValue),
                                              lastModified: http.value(forHTTPHeaderField: Keys.lastModified.rawValue)) else {
            // No container, no resume: the sequential path takes the body.
            outputPipeline.call(.readyForRead)
            return
        }
        setResume(resume)
        resume.setWriteOffset(_resumeDownloadStart)
        contentLength = UInt(length)
        info = .local(resume.containerURL, info.fileHint)
        do {
            try openResumeReader(at: UInt64(position))
        } catch {
            let e = error as? APlay.Error ?? APlay.Error.open("open resume container failed: \(error)")
            outputPipeline.call(.errorOccurred(e))
        }
    }

    /// Checks a response that arrived for an already-open container: the range
    /// must be the one asked for and the length the cached one, else the
    /// container restarts. Runs on `_stateQueue`.
    func handleResumeResponse(_ http: HTTPURLResponse, statusCode: Int) {
        guard _icyCastInfo.isIcyStream == false else {
            fallBackToSequential()
            return
        }
        guard let resume = resumeCache() else { return }
        let etag = http.value(forHTTPHeaderField: Keys.etag.rawValue)
        let lastModified = http.value(forHTTPHeaderField: Keys.lastModified.rawValue)

        if statusCode == 206 {
            // A conformant server repeats the slice in `Content-Range`; one that
            // omits the header is still answering the range that was requested.
            let start = contentRangeStart(http) ?? _resumeDownloadStart
            guard start == _resumeDownloadStart else {
                // The server answered with a slice other than the one requested,
                // so the container's layout no longer matches the stream.
                fallBackToSequential()
                return
            }
            if let total = responseContentLength(http, statusCode: statusCode), total != resume.contentLength {
                // The validators matched but the length moved: the cached bytes
                // belong to another rendition, so the table starts over.
                resume.restart(contentLength: total, etag: etag, lastModified: lastModified)
                contentLength = UInt(total)
                return
            }
            resume.setWriteOffset(start)
            resume.setValidators(etag: etag, lastModified: lastModified)
        } else {
            // A 200 means the server ignored `If-Range` or replaced the content:
            // the whole body comes back and the container starts over at zero.
            guard let total = responseContentLength(http, statusCode: statusCode), total > 0 else {
                fallBackToSequential()
                return
            }
            resume.restart(contentLength: total, etag: etag, lastModified: lastModified)
            contentLength = UInt(total)
        }
    }

    /// Opens the container for reading and starts draining it. Mirrors
    /// `openLocal(at:)` without the ID3 probe, which the opening path already ran
    /// against the origin URL. Must run on `_stateQueue`.
    func openResumeReader(at offset: UInt64) throws {
        guard case let .local(url, _) = info else {
            throw APlay.Error.open("not a local url")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw APlay.Error.open("file not exists: \(url)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        if offset > 0 { try handle.seek(toOffset: offset) }
        _localLock.lock()
        _fileHandle = handle
        _isRunningLocal = true
        _localLock.unlock()
        _isFirstPacket = true
        _readQueue.async { [weak self] in
            self?.localReadLoop()
        }
    }

    /// Restarts the download into the container from where it stopped, leaving
    /// the local reader untouched — it bridges the gap by waiting on the next
    /// block. Returns false when nothing is left to fetch. Must run on
    /// `_stateQueue`.
    @discardableResult
    func reconnectResumeDownload() -> Bool {
        guard let resume = resumeCache() else { return false }
        _watchDogInfo.invalidateTimer()
        let frontier = resume.writeOffset
        guard frontier < UInt64(contentLength), contentLength > 0 else { return false }
        _bytesRead = 0
        startResumeDownload(at: frontier)
        return true
    }

    /// Gives up on the container and writes to the sequential tmp file — what a
    /// stream without a usable length, or a ShoutCast body, has always done. The
    /// partial stays on disk for a later, better-behaved request.
    func fallBackToSequential() {
        guard let resume = resumeCache() else { return }
        setLocalRunning(false)
        if let handle = _fileHandle {
            _fileHandle = nil
            try? handle.close()
        }
        resume.flushMeta()
        info = .remote(resume.originURL, info.fileHint)
        setResume(nil)
        _resumeDownloadStart = 0
        _bytesRead = 0
        outputPipeline.call(.readyForRead)
        _config.logger.log("resume cache unusable for this response; falling back to sequential", to: .streamProvider)
    }

    /// Every block of the container holds real bytes, so it is indistinguishable
    /// from a completed download: move it to the plain cache path and the next
    /// open finds a full hit.
    func promoteResumeCache() {
        guard let resume = resumeCache(), _config.cachePolicy.isEnabled else { return }
        // Match the sequential path and let the caller's validator clear the
        // file before it becomes a cache hit.
        let headerSnapshot = registerHeader.compactMapValues { $0 as? String }
        let originURL = resume.originURL
        DispatchQueue.global(qos: .utility).async {
            if case let APlay.Configuration.HttpFileValidationPolicy.validateHeader(keys: _, closure) = self._config.httpFileCompletionValidator {
                guard closure(originURL, resume.containerURL.path, headerSnapshot) else { return }
            }
            _ = resume.promote()
        }
    }
}

// MARK: - Watch Dog Stuff

private extension Streamer {
    func reachMaxRetryAndStopWatchDog() {
        _watchDogInfo.invalidateTimer()
        outputPipeline.call(.errorOccurred(APlay.Error.reachMaxRetryTime))
    }

    func startReconnectWatchDog(notStreamingEnd: Bool = false) {
        _config.logger.log("startReconnectWatchDog", to: Logger.Channel.streamProvider)
        _watchDogInfo.startWatchDog(with: 0.5) { [weak self] reachMaxRetryTime in
            guard let sself = self else { return }
            if reachMaxRetryTime {
                sself.reachMaxRetryAndStopWatchDog()
                return
            }
            let p: StreamProvider.Position
            sself._watchDogInfo.invalidateTimer()
            if sself._watchDogInfo.isReadedData == false, notStreamingEnd == false { p = sself.position }
            else {
                let totalReadLength = sself.position + sself._bytesRead
                sself._config.logger.log("totalReadLength:\(totalReadLength) < contentLength:\(sself.contentLength): \(totalReadLength < sself.contentLength)", to: Logger.Channel.streamProvider)
                if totalReadLength < sself.contentLength,
                   sself.contentLength > 0 {
                    p = StreamProvider.Position(totalReadLength)
                } else { p = 0 }
            }
            if sself.resumeCache() != nil {
                // The container is the reconnect target: the local reader stays
                // open and the download picks up at its write cursor.
                sself.cancelDownload()
                _ = sself.reconnectResumeDownload()
                return
            }
            sself._bytesRead = 0
            sself._open(at: p)
        }
    }

    final class WatchDogInfo {
        private var timer: DispatchSourceTimer?
        var reopenTimes: UInt = 0
        var isReadedData = false
        private var callback: (Bool) -> Void = { _ in }
        private var _maxRemoteStreamOpenRetry: UInt = 5
        private let _queue: DispatchQueue

        init(maxRemoteStreamOpenRetry: UInt, queue: DispatchQueue) {
            _maxRemoteStreamOpenRetry = maxRemoteStreamOpenRetry
            _queue = queue
        }

        func invalidateTimer() {
            timer?.cancel()
            timer = nil
        }

        func reset() {
            invalidateTimer()
            reopenTimes = 0
            isReadedData = false
        }

        /// Stops the timer and clears the read flag without spending the retry
        /// budget, so a persistent error still terminates at `reopenTimes`.
        func prepareForRetry() {
            invalidateTimer()
            isReadedData = false
        }

        func startWatchDog(with interval: TimeInterval, callback: @escaping (Bool) -> Void) {
            self.callback = callback
            invalidateTimer()
            let timer = DispatchSource.makeTimerSource(queue: _queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let sself = self else { return }
                sself.callback(sself.reopenTimes > sself._maxRemoteStreamOpenRetry)
            }
            timer.activate()
            self.timer = timer
        }
    }
}

// MARK: - Icy cast Stuff

private extension Streamer {
    final class IcyCastInfo {
        var name: String? = nil
        var isIcyStream = false
        var metaDataInterval = 0
        var dataByteReadCount = 0
        var metaDataBytesRemaining = 0
        var metadata: [UInt8] = []
        var buffer: [UInt8]? = nil
        init() {}

        func reset() {
            name = nil
            isIcyStream = false
            metaDataInterval = 0
            dataByteReadCount = 0
            metaDataBytesRemaining = 0
            metadata = []
            buffer = nil
        }

        func parseICYStream(streamer: Streamer, buffers pointer: UnsafeMutablePointer<UInt8>, bufSize: Int) {
            streamer._config.logger.log("Parsing an IceCast stream, received \(bufSize) bytes", to: .streamProvider)
            var offset = 0
            let buffers = UnsafeMutablePointer.uint8Pointer(of: bufSize)
            defer { free(buffers) }
            memcpy(buffers, pointer, bufSize)
            func readICY() {
                if buffer == nil {
                    buffer = Array(repeating: 0, count: 8192)
                }
                streamer._config.logger.log("Reading ICY stream for playback", to: .streamProvider)
                var i = 0
                while offset < bufSize {
                    let buf = buffers.advanced(by: offset).pointee
                    // is this a metadata byte?
                    if metaDataBytesRemaining > 0 {
                        metaDataBytesRemaining -= 1
                        if metaDataBytesRemaining == 0 {
                            dataByteReadCount = 0
                            if metadata.count > 0 {
                                guard let metaData = createMetaData(from: &metadata, numBytes: metadata.count) else {
                                    // Metadata encoding failed, cannot parse.
                                    offset += 1
                                    metadata.removeAll()
                                    continue
                                }
                                var metadataMap: [MetadataParser.Item] = []
                                let tokens = metaData.components(separatedBy: ";")
                                for token in tokens {
                                    // The delimiter is the whole `='` pair: the key
                                    // sits before it, the quoted value after it.
                                    // Starting the value range at the `=` would keep
                                    // both the delimiter prefix and the closing quote.
                                    if let range = token.range(of: "='") {
                                        let keyRange = Range(uncheckedBounds: (token.startIndex, range.lowerBound))
                                        let key = String(token[keyRange])
                                        var value = String(token[range.upperBound..<token.endIndex])
                                        if value.hasSuffix("'") { value.removeLast() }
                                        metadataMap.append(.other([key: value]))
                                    }
                                }
                                if let value = name { metadataMap.append(.title(value)) }
                                streamer.outputPipeline.call(.metadata(metadataMap))
                            } // _icyMetaData.count > 0
                            metadata.removeAll()
                            offset += 1
                            continue
                        } // _metaDataBytesRemaining == 0
                        metadata.append(buf)
                        offset += 1
                        continue
                    } // _metaDataBytesRemaining > 0

                    // is this the interval byte?
                    if metaDataInterval > 0 && dataByteReadCount == metaDataInterval {
                        metaDataBytesRemaining = Int(buf) * 16

                        if metaDataBytesRemaining == 0 {
                            dataByteReadCount = 0
                        }
                        offset += 1
                        continue
                    }
                    // a data byte
                    i += 1
                    dataByteReadCount += 1
                    let count = buffer?.count ?? 0
                    // `i` counts data bytes seen so far; the byte at position i
                    // is the i-th one, so it belongs at index i - 1. Writing it
                    // at `i` instead shifts the whole slice: the delivered chunk
                    // starts with the buffer's zero fill and drops its last
                    // byte.
                    if i <= count {
                        buffer?[i - 1] = buf
                    }
                    offset += 1
                }
                if let buffer = buffer, i > 0 {
                    // Bytes beyond the fixed-size buffer were dropped above;
                    // report only the ones actually stored.
                    let stored = min(i, buffer.count)
                    buffer.withUnsafeBufferPointer { bufferPtr in
                        streamer.outputPipeline.call(.hasBytesAvailable(bufferPtr.baseAddress!, UInt32(stored), streamer._isFirstPacket))
                    }
                    if streamer._isFirstPacket { streamer._isFirstPacket = false }
                }
            }
            readICY()
        }

        func createMetaData(from bytes: UnsafeMutablePointer<UInt8>, numBytes: Int) -> String? {
            let builtIns: [CFStringBuiltInEncodings] = [.UTF8, .isoLatin1, .windowsLatin1, .nextStepLatin]
            let encodings: [CFStringEncodings] = [.isoLatin2, .isoLatin3, .isoLatin4, .isoLatinCyrillic, .isoLatinGreek, .isoLatinHebrew, .isoLatin5, .isoLatin6, .isoLatinThai, .isoLatin7, .isoLatin8, .isoLatin9, .windowsLatin2, .windowsCyrillic, .windowsArabic, .KOI8_R, .big5]
            #if swift(>=4.1)
                var total = builtIns.compactMap { $0.rawValue }
                total += encodings.compactMap { CFStringEncoding($0.rawValue) }
            #else
                var total = builtIns.flatMap { $0.rawValue }
                total += encodings.flatMap { CFStringEncoding($0.rawValue) }
            #endif
            total += [CFStringBuiltInEncodings.ASCII.rawValue]
            for enc in total {
                guard let meta = CFStringCreateWithBytes(kCFAllocatorDefault, bytes, numBytes, enc, false) as String? else { continue }
                return meta
            }
            return nil
        }
    }
}

// MARK: - Cache Stuff

private extension Streamer {
    func asCachedFileInfo() -> StreamProvider.URLInfo? {
        var total = _config.cachePolicy.cachedFolder ?? []
        total.append(_config.cacheDirectory)
        return total.compactMap({ (dir) -> StreamProvider.URLInfo? in
            guard let path = self._cacheInfo.cachedFilePath(for: dir), FileManager.default.fileExists(atPath: path) else { return nil }
            return StreamProvider.URLInfo(url: URL(fileURLWithPath: path))
        }).first
    }

    final class CacheInfo: @unchecked Sendable {
        private var _cacheName: String?
        private var _cacheWritePath: String?
        private var _cacheWriteTmpPath: String?
        private var _filehandle: UnsafeMutablePointer<FILE>?
        private var _fileWritten: UInt = 0
        private unowned let _config: ConfigurationCompatible

        init(config: ConfigurationCompatible) { _config = config }

        /// Cache file name for the current URL, `nil` when caching is off or
        /// no URL has been reset into yet.
        var cacheName: String? { _cacheName }

        func cachedFilePath(for dir: String) -> String? {
            guard let name = _cacheName else { return nil }
            return "\(dir)/\(name)"
        }

        func disposeIfNeeded(at position: StreamProvider.Position) {
            guard position != _fileWritten else { return }
            if let h = _filehandle { fclose(h) }
            _filehandle = nil
        }

        func reset(url: URL) {
            _cacheName = nil
            _cacheWritePath = nil
            _cacheWriteTmpPath = nil
            _filehandle = nil
            _fileWritten = 0
            guard _config.cachePolicy.isEnabled else { return }
            _cacheName = _config.cacheNaming.name(for: url)
            guard let name = _cacheName else { return }
            _cacheWritePath = "\(_config.cacheDirectory)/\(name)"
            guard let path = _cacheWritePath else { return }
            let tmp = "\(path).tmp"
            _cacheWriteTmpPath = tmp
            _filehandle = fopen(tmp, "w+")
        }

        func write(bytes: UnsafeRawPointer, count: Int) {
            guard let handle = _filehandle, count > 0 else { return }
            let written = fwrite(bytes, 1, count, handle)
            guard written > 0 else { return }
            _fileWritten += UInt(written)
        }

        func writeFile(targetLength: UInt, url: URL, header: [String: Any]) {
            guard _fileWritten == targetLength, let tmp = _cacheWriteTmpPath, let target = _cacheWritePath else { return }
            // Snapshot the header as a Sendable dictionary before crossing the
            // async boundary; `Any` itself is not Sendable.
            let headerSnapshot = header.compactMapValues { $0 as? String }
            DispatchQueue.global(qos: .utility).async {
                if case let APlay.Configuration.HttpFileValidationPolicy.validateHeader(keys: _, closure) = self._config.httpFileCompletionValidator {
                    guard closure(url, tmp, headerSnapshot) else { return }
                }
                self.saveFile(tmp: tmp, target: target)
            }
        }

        func saveFile(tmp: String, target: String) {
            let fs = FileManager.default
            do {
                try fs.moveItem(atPath: tmp, toPath: target)
                _config.logger.log("moveItem from \n\(tmp) \nto\n \(target)", to: .streamProvider)
            } catch {
                _config.logger.log("\(#function):\(error)", to: .streamProvider)
            }
        }
    }
}

// MARK: - HTTP header keys

private extension Streamer {
    enum Keys: String {
        case get = "GET"
        case userAgent = "User-Agent"
        case range = "Range"
        case icyMetadata = "Icy-MetaData"
        case icyMetaDataValue = "1"
        case icyMetaint = "icy-metaint"
        case icyName = "icy-name"
        case icyBr = "icy-br"
        case icySr = "icy-sr"
        case icyGenre = "icy-genre"
        case icyNotice1 = "icy-notice1"
        case icyNotice2 = "icy-notice2"
        case icyUrl = "icy-url"
        case icecastStationName = "IcecastStationName"
        case contentType = "Content-Type"
        case contentLength = "Content-Length"
        case ifRange = "If-Range"
        case contentRange = "Content-Range"
        case etag = "ETag"
        case lastModified = "Last-Modified"
    }
}
