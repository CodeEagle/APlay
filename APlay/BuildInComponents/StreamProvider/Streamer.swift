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
        let start = Float(position) + Float(_bytesRead)
        return start / Float(contentLength)
    }

    private unowned let _config: ConfigurationCompatible

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

    #if DEBUG
        deinit {
            _urlSession.finishTasksAndInvalidate()
            debug_log("\(self) \(#function)")
        }
    #endif

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
        guard _task == nil, _fileHandle == nil else {
            outputPipeline.call(.errorOccurred(.openedAlready("stream already open")))
            return
        }
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
        guard info.isRemote else { return }
        if resetTimer { _watchDogInfo.reset() }
    }

    private func reset(url: URL) {
        _stateQueue.sync { self.close(resetTimer: true) }
        _icyCastInfo.reset()
        _watchDogInfo.reset()
        _cacheInfo.reset(url: url)
        _bytesRead = 0
        info = StreamProvider.URLInfo(url: url)
        position = 0
        if let cachedInfo = asCachedFileInfo() { info = cachedInfo }
        contentLength = info.localContentLength()
        _tagParser = tagParser(for: info)
        _config.logger.log("\(info)", to: .streamProvider)
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
        var request = URLRequest(url: url)
        request.httpMethod = Keys.get.rawValue
        request.setValue(_config.userAgent, forHTTPHeaderField: Keys.userAgent.rawValue)
        request.setValue(Keys.icyMetaDataValue.rawValue, forHTTPHeaderField: Keys.icyMetadata.rawValue)
        if position > 0 {
            request.setValue("bytes=\(position)-", forHTTPHeaderField: Keys.range.rawValue)
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
        _config.logger.log("open at \(position)", to: .streamProvider)
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
            guard let chunk = try? handle.read(upToCount: 8192), chunk.isEmpty == false else { break }
            deliverLocalData(chunk)
        }
        // EOF (not pause/destroy) is the only path that posts `.endEncountered`.
        _localLock.lock()
        let reachedEOF = _isRunningLocal
        if reachedEOF { _isRunningLocal = false }
        _localLock.unlock()
        guard reachedEOF else { return }
        outputPipeline.call(.endEncountered)
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
        _stateQueue.async { [weak self] in
            guard let self = self else { return }
            block(self)
        }
    }
}

// MARK: - URLSession callbacks (run on _stateQueue)

private extension Streamer {
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
            _icyCastInfo.isHeadersParsed = true
            _icyCastInfo.isHeadersRead = true
            _icyCastInfo.metaDataInterval = Int(metaint) ?? 0
            _config.logger.log("\(Keys.icyMetaint.rawValue): \(_icyCastInfo.metaDataInterval)", to: .streamProvider)
        } else if let notice = http.value(forHTTPHeaderField: Keys.icyNotice1.rawValue) {
            _icyCastInfo.isIcyStream = true
            _icyCastInfo.isHeadersParsed = true
            _icyCastInfo.isHeadersRead = true
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
            if let len = http.value(forHTTPHeaderField: Keys.contentLength.rawValue).flatMap({ UInt($0) }) {
                if statusCode == 206 {
                    contentLength = len + position
                } else {
                    contentLength = len
                }
                _config.logger.log("\(statusCode) Content Length:\(contentLength)", to: .streamProvider)
            }
            outputPipeline.call(.readyForRead)
        case 401, 407:
            // The challenge is answered in the session delegate; if the server
            // still answers with 401/407 the reconnect watchdog takes over.
            _config.logger.log("Did receive authentication challenge (\(statusCode))", to: .streamProvider)
            _watchDogInfo.reset()
            startReconnectWatchDog()
        case 500 ... 599:
            _config.logger.log("Server error:\(statusCode)", to: .streamProvider)
            _watchDogInfo.reset()
            startReconnectWatchDog()
        default:
            outputPipeline.call(.errorOccurred(.networkStatusCode(statusCode)))
        }
        completionHandler(.allow)
    }

    func handle(data: Data) {
        if info.isRemote {
            _watchDogInfo.reset()
            _watchDogInfo.isReadedData = true
        }
        let count = UInt32(data.count)
        if _icyCastInfo.isIcyStream {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                _icyCastInfo.parseICYStream(streamer: self, buffers: UnsafeMutablePointer(mutating: base), bufSize: Int(count))
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
        guard info.isRemote == true else { return }
        let statusCode = (_task?.response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode == 401 { return }
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
        guard info.isRemote, nsError.domain == NSURLErrorDomain, nsError.code != NSURLErrorCancelled else { return }
        let read = _bytesRead + position
        if read < contentLength, contentLength > 0 {
            _watchDogInfo.startWatchDog(with: 2) { [weak self] reachMaxRetryTime in
                guard let sself = self else { return }
                if reachMaxRetryTime {
                    sself.reachMaxRetryAndStopWatchDog()
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
                sself._open(at: p)
            }
        } else {
            _watchDogInfo.invalidateTimer()
            outputPipeline.call(.errorOccurred(.network(error.localizedDescription)))
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
        lazy var name: String? = nil
        lazy var isIcyStream = false
        private lazy var isHeaderCR = false
        lazy var isHeadersRead = false
        lazy var isHeadersParsed = false
        private lazy var headerLines: [String] = []
        lazy var metaDataInterval = 0
        lazy var dataByteReadCount = 0
        lazy var metaDataBytesRemaining = 0
        lazy var metadata: [UInt8] = []
        lazy var buffer: [UInt8]? = nil
        init() {}

        func reset() {
            name = nil
            isIcyStream = false
            isHeaderCR = false
            isHeadersRead = false
            isHeadersParsed = false
            headerLines = []
            metaDataInterval = 0
            dataByteReadCount = 0
            metaDataBytesRemaining = 0
            metadata = []
            buffer = nil
        }

        func parseICYStream(streamer: Streamer, buffers pointer: UnsafeMutablePointer<UInt8>, bufSize: Int) {
            streamer._config.logger.log("Parsing an IceCast stream, received \(bufSize) bytes", to: .streamProvider)
            var offset = 0
            var bytesFound = 0
            let buffers = UnsafeMutablePointer.uint8Pointer(of: bufSize)
            defer { free(buffers) }
            memcpy(buffers, pointer, bufSize)
            func readICYHeader() {
                streamer._config.logger.log("ICY headers not read, reading", to: .streamProvider)
                while offset < bufSize {
                    let buffer = buffers.advanced(by: offset).pointee
                    let bufferString = String(Character(UnicodeScalar(buffer)))
                    if bufferString == "", isHeaderCR {
                        if bytesFound > 0 {
                            var bytes: [UInt8] = []
                            let total = offset - bytesFound
                            for i in 0 ..< total {
                                bytes.append(buffers.advanced(by: i).pointee)
                            }
                            if let line = createMetaData(from: &bytes, numBytes: total) {
                                headerLines.append(line)
                                streamer._config.logger.log("icyHeaderLines:\(line)", to: .streamProvider)
                            }
                            bytesFound = 0
                            offset += 1
                            continue
                        }
                        isHeadersRead = true
                        break
                    }
                    if bufferString == "\r" {
                        isHeaderCR = true
                        offset += 1
                        continue
                    } else {
                        isHeaderCR = false
                    }
                    bytesFound += 1
                    offset += 1
                }
            }

            func parseICYHeader() {
                let icyContentTypeHeader = Keys.contentType.rawValue + ":"
                let icyMetaDataHeader = Keys.icyMetaint.rawValue + ":"
                let icyNameHeader = Keys.icyName.rawValue + ":"
                for line in headerLines {
                    if line.isEmpty { continue }
                    let l = line.lowercased()
                    if l.hasPrefix(icyContentTypeHeader) {
                        let contentType = line.replacingOccurrences(of: icyContentTypeHeader, with: "")
                        if case let .remote(url, hint) = streamer.info {
                            let newHint = StreamProvider.URLInfo.fileHint(from: contentType)
                            if newHint != hint {
                                streamer.info = .remote(url, newHint)
                                streamer._tagParser = streamer.tagParser(for: streamer.info)
                            }
                        }
                        streamer._config.logger.log("\(Keys.contentType.rawValue): \(contentType)", to: .streamProvider)
                    }
                    if l.hasPrefix(icyMetaDataHeader) {
                        let raw = l.replacingOccurrences(of: icyMetaDataHeader, with: "")
                        if let interval = Int(raw) {
                            metaDataInterval = interval
                        } else { metaDataInterval = 0 }
                    }
                    if l.hasPrefix(icyNameHeader) {
                        name = l.replacingOccurrences(of: icyNameHeader, with: "")
                    }
                }
                isHeadersParsed = true
                offset += 1
                streamer.outputPipeline.call(.readyForRead)
            }

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
                                    if let range = token.range(of: "='") {
                                        let keyRange = Range(uncheckedBounds: (token.startIndex, range.lowerBound))
                                        let key = String(token[keyRange])
                                        let distance = token.distance(from: token.startIndex, to: keyRange.upperBound)
                                        let valueStart = token.index(token.startIndex, offsetBy: distance)
                                        let valueRange = Range(uncheckedBounds: (valueStart, token.endIndex))
                                        let value = String(token[valueRange])
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
                    if i < count {
                        buffer?[i] = buf
                    }
                    offset += 1
                }
                if let buffer = buffer, i > 0 {
                    buffer.withUnsafeBufferPointer { bufferPtr in
                        streamer.outputPipeline.call(.hasBytesAvailable(bufferPtr.baseAddress!, UInt32(i), streamer._isFirstPacket))
                    }
                    if streamer._isFirstPacket { streamer._isFirstPacket = false }
                }
            }
            if isHeadersRead == false { readICYHeader() }
            else if isHeadersParsed == false { parseICYHeader() }
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
    }
}
