//
//  Streamer.swift
//  APlayer
//
//  Created by lincoln on 2018/4/11.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation

// MARK: - Streamer

final class Streamer: StreamProviderCompatible {
    var outputPipeline = Delegated<StreamProvider.Event, Void>()

    var position: StreamProvider.Position = 0
    var contentLength: UInt = 0
    var info = StreamProvider.URLInfo.none
    var registerHeader: [String: Any] = [:]

    var bufferingProgress: Float {
        guard contentLength > 0 else { return 0 }
        let start = Float(position.value) + Float(_httpInfo.bytesRead)
        return start / Float(contentLength)
    }

    private unowned let _config: ConfigurationCompatible
    private lazy var _readStream: CFReadStream? = nil
    private lazy var _runloop = RunloopQueue(named: "Streamer")
    private lazy var _isRuning = false

    private lazy var _cacheInfo = CacheInfo(config: self._config)
    private lazy var _icyCastInfo = IcyCastInfo()
    private lazy var _watchDogInfo = WatchDogInfo(maxRemoteStreamOpenRetry: UInt(self._config.maxRemoteStreamOpenRetry))
    private lazy var _httpInfo = HttpInfo()

    private lazy var _canOutputData = false
    private lazy var _isFirstPacket = true
    private var _tagParser: MetadataParserCompatible?

    private lazy var _isRequestClose = false
    private lazy var _isLooping = false

    #if DEBUG
        deinit {
            debug_log("\(self) \(#function)")
        }
    #endif

    init(config: ConfigurationCompatible) { _config = config }

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

        parser?.outputStream.delegate(to: self, with: { sself, value in
            switch value {
            case let .metadata(data): sself.outputPipeline.call(.metadata(data))
            case let .tagSize(size): sself.outputPipeline.call(.metadataSize(size))
            case let .flac(value): sself.outputPipeline.call(.flac(value))
            default: break
            }
        })
        return parser
    }
}

// MARK: StreamDataSource

extension Streamer {
    func _open(at position: StreamProvider.Position) {
        do {
            guard _readStream == nil else { return }
            _cacheInfo.disposeIfNeeded(at: position)
            self.position = position
            let stream = try createStream(at: position, httpInfo: _httpInfo)
            try addReadCallBack(for: stream)
            setScheduledInRunLoop(run: true, for: stream)
            _canOutputData = true
            guard CFReadStreamOpen(stream) == true else {
                _canOutputData = false
                CFReadStreamSetClient(stream, 0, nil, nil)
                setScheduledInRunLoop(run: false, for: stream)
                throw APlay.Error.open("CFReadStreamOpen faile: \(position)")
            }
            if position.value == 0 { _tagParser?.parseID3V1Tag(at: info.url) }
            if info.isRemote {
                _watchDogInfo.reopenTimes += 1
                _watchDogInfo.isReadedData = false
            } else {
                outputPipeline.call(.readyForReady)
            }
            _isFirstPacket = true
            _readStream = stream
        } catch {
            guard let e = error as? APlay.Error else {
                outputPipeline.call(.unknown(error))
                return
            }
            outputPipeline.call(.errorOccurred(e))
        }
    }

    func open(url: URL, at position: StreamProvider.Position) {
        guard _readStream == nil else {
            outputPipeline.call(.errorOccurred(.openedAlready("stream already open")))
            return
        }
        reset(url: url)
        guard info.isRemote else {
            _open(at: position)
            return
        }
        _config.networkPolicy.requestPermission(for: info.url, handler: { [weak self] success in
            guard success else {
                let err = APlay.Error.networkPermission("No permission for accessing network")
                self?.outputPipeline.call(.errorOccurred(err))
                return
            }
            self?._open(at: position)
        })
    }

    func destroy() {
        if _isLooping {
            debug_log("Streamer request destroy when looping")
            pause()
            _isRequestClose = true
        } else {
            debug_log("Streamer closed")
            close(resetTimer: true)
        }
    }

    func pause() { setScheduledInRunLoop(run: false, for: _readStream) }

    func resume() { setScheduledInRunLoop(run: true, for: _readStream) }

    private func setScheduledInRunLoop(run: Bool, for stream: CFReadStream?) {
        guard let readStream = stream, _isRuning != run else { return }
        if run == false {
            CFReadStreamUnscheduleFromRunLoop(readStream, CFRunLoopGetCurrent(), .commonModes)
        } else { _runloop.schedule(readStream) }
        _isRuning = run
    }

    private func close(resetTimer: Bool) {
        guard let stream = _readStream else { return }
        pause()
        CFReadStreamSetClient(stream, 0, nil, nil)
        CFReadStreamClose(stream)
        _readStream = nil
        guard info.isRemote else { return }
        if resetTimer { _watchDogInfo.reset() }
    }

    private func reset(url: URL) {
        _canOutputData = false
        close(resetTimer: true)
        _httpInfo.reset()
        _icyCastInfo.reset()
        _watchDogInfo.reset()
        _cacheInfo.reset(url: url)
        info = StreamProvider.URLInfo(url: url)
        position = 0
        if let cachedInfo = asCachedFileInfo() { info = cachedInfo }
        contentLength = info.localContentLength()
        _tagParser = tagParser(for: info)
        _config.logger.log("\(info)", to: .streamProvider)
    }
}

// MARK: - Stream Runloop Stuff

private extension Streamer {

    // MARK: Create Stream

    func createStream(at position: StreamProvider.Position, httpInfo: HttpInfo) throws -> CFReadStream {
        switch info {
        case let .local(url, _): return try createLocalStream(for: url, at: position)
        case let .remote(url, _): return try createRemoteStream(for: url, at: position, httpInfo: httpInfo)
        case let .unknown(url): throw APlay.Error.open("Unknown how to handle url: \(url.absoluteString)")
        }
    }

    func createLocalStream(for url: URL, at position: StreamProvider.Position) throws -> CFReadStream {
        guard let stream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url as CFURL) else {
            throw APlay.Error.open("CFReadStreamCreateWithFile faile: \(url)")
        }
        if position.value > 0 {
            var position = position
            let p = CFNumberCreate(kCFAllocatorDefault, .longLongType, &position)
            CFReadStreamSetProperty(stream, CFStreamPropertyKey.fileCurrentOffset, p)
        }
        return stream
    }

    func createRemoteStream(for url: URL, at position: StreamProvider.Position, httpInfo: HttpInfo) throws -> CFReadStream {
        let config = _config
        let request = CFHTTPMessageCreateRequest(kCFAllocatorDefault, Keys.get.cf, url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()

        CFHTTPMessageSetHeaderFieldValue(request, Keys.userAgent.cf, config.userAgent as CFString)

        CFHTTPMessageSetHeaderFieldValue(request, Keys.icyMetadata.cf, Keys.icyMetaDataValue.cf)

        if position.value > 0 {
            let range = "bytes=\(position.value)-" as CFString
            CFHTTPMessageSetHeaderFieldValue(request, Keys.range.cf, range)
        }

        for (key, value) in config.predefinedHttpHeaderValues {
            debug_log("Setting predefined HTTP header[\(key) : \(value)]")
            CFHTTPMessageSetHeaderFieldValue(request, key as CFString, value as CFString)
        }

        if let authentication = httpInfo.auth, let info = httpInfo.credentials {
            let credentials = info as CFDictionary
            if CFHTTPMessageApplyCredentialDictionary(request, authentication, credentials, nil) == false {
                throw APlay.Error.open("add authentication fail")
            }
            debug_log("Digest authentication add success")
        }
        let s = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request)
        let stream = s.takeRetainedValue()
        CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamNetworkServiceType), kCFStreamNetworkServiceTypeBackground)
        CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPShouldAutoredirect), kCFBooleanTrue)

        if case let APlay.Configuration.ProxyPolicy.custom(info) = config.proxyPolicy {
            var dict: [String: Any] = [:]
            dict[kCFNetworkProxiesHTTPPort as String] = info.port
            dict[kCFNetworkProxiesHTTPProxy as String] = info.host
            let proxy = dict as CFDictionary
            if CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPProxy), proxy) == false {
                debug_log("Setting custom proxy not success")
            }
        } else {
            if let proxy = CFNetworkCopySystemProxySettings()?.takeRetainedValue() {
                let dict = proxy as NSDictionary
                debug_log("System proxy:\(dict)")
                CFReadStreamSetProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPProxy), proxy)
            }
        }
        // SSL Support
        if url.scheme?.lowercased() == "https" {
            let sslSettings: [String: Any] = [
                kCFStreamSocketSecurityLevelNegotiatedSSL as String: false,
                kCFStreamSSLLevel as String: kCFStreamSSLValidatesCertificateChain,
                kCFStreamSSLPeerName as String: NSNull(),
            ]
            let key = CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings)
            CFReadStreamSetProperty(stream, key, sslSettings as CFTypeRef)
        }
        return stream
    }

    // MARK: Add Stream Callback

    func addReadCallBack(for stream: CFReadStream) throws {
        let this = UnsafeMutableRawPointer.from(object: self)

        var ctx = CFStreamClientContext(version: 0, info: this, retain: nil, release: nil, copyDescription: nil)
        let flags: CFStreamEventType = [.hasBytesAvailable, .endEncountered, .errorOccurred]

        let callback: CFReadStreamClientCallBack = { stream, type, userData in
            guard let data = userData else { return }
            let st = data.to(object: Streamer.self)
            st.readCallBack(type: type, stream: stream)
        }
        guard CFReadStreamSetClient(stream, flags.rawValue, callback, &ctx) == false else { return }
        throw APlay.Error.open("CFReadStreamSetClient faile")
    }

    // MARK: Handle Stream CallBack

    func readCallBack(type: CFStreamEventType, stream: CFReadStream?) {
        switch type {
        case CFStreamEventType.hasBytesAvailable: hasBytesAvailable(stream)
        case CFStreamEventType.endEncountered: endEncountered(stream)
        case CFStreamEventType.errorOccurred: handleStreamError(stream)
        default: break
        }
    }

    func hasBytesAvailable(_ targetStream: CFReadStream?) {
        if info.isRemote {
            _watchDogInfo.reset()
            _watchDogInfo.isReadedData = true
        }
        guard let stream = targetStream, _canOutputData else { return }
        let bufferSize = 8192 // balance cpu, slow streaming but low cpu usage
        let buffer = UnsafeMutablePointer.uint8Pointer(of: bufferSize)
        // 50kb/s limit read speed
//        let speed = 50 * 1024 / 1000
//        defer { free(buffer) }
//        var begin: CFAbsoluteTime = 0
//        var end: CFAbsoluteTime = 0
        while CFReadStreamHasBytesAvailable(stream) {
            _isLooping = true
            if _isRequestClose == true {
                defer { _isRequestClose = false }
                close(resetTimer: true)
                debug_log("Streamer real closing stream")
                return
            }
            if _isRuning == false {
                _config.logger.log("read pending", to: .streamProvider)
                _isLooping = false
                return
            }
//            begin = CFAbsoluteTimeGetCurrent()
            // why it is not reading real data, sometime?
            let bytesRead = CFReadStreamRead(stream, buffer, CFIndex(bufferSize))
            // error, reading empty data back
            if _isFirstPacket == true, position.value == 0, buffer.advanced(by: 0).pointee == 0 {
                _watchDogInfo.isReadedData = false
                close(resetTimer: false)
                startReconnectWatchDog()
                debug_log("reading empty data back, try to reopen")
                break
            }
            guard bytesRead > 0 else {
                _isLooping = false
                return
            }

            if info.isRemote {
                if CFReadStreamGetStatus(stream) == CFStreamStatus.error {
                    if contentLength > 0 {
                        let p = StreamProvider.Position(position.value + _httpInfo.bytesRead)
                        _watchDogInfo.reset()
                        _open(at: p)
                        _isLooping = false
                        return
                    }
                    handleStreamError(stream)
                    _isLooping = false
                    return
                }
                _httpInfo.parseHttpHeaders(for: self, buffer: buffer, bufSize: bytesRead)
                if _icyCastInfo.isIcyStream {
                    _icyCastInfo.parseICYStream(streamer: self, buffers: buffer, bufSize: bytesRead)
                } else {
                    _cacheInfo.write(bytes: buffer, count: bytesRead)
                }
            }
            _httpInfo.bytesRead += UInt(bytesRead)
            guard _canOutputData else {
                _isLooping = false
                return
            }
            let count = UInt32(bytesRead)
            if _icyCastInfo.isIcyStream == false, position.value == 0 {
                _tagParser?.acceptInput(data: buffer, count: count)
            }

            let value = _isFirstPacket
            outputPipeline.call(.hasBytesAvailable(buffer, count, value))
            if _isFirstPacket { _isFirstPacket = false }

//            end = CFAbsoluteTimeGetCurrent()
//            let timeCost = end - begin
//            let expectTimeCost = Int(bytesRead) / speed
//            let deltaTime = expectTimeCost - Int(timeCost)
//            if deltaTime > 0 {
//                usleep(useconds_t(deltaTime * 1000))
//            }
        }
    }

    func endEncountered(_ targetStream: CFReadStream?) {
        guard info.isRemote == true else {
            outputPipeline.call(.endEncountered)
            return
        }
        if let stream = targetStream, let resp = CFReadStreamCopyProperty(stream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)) {
            let code = CFHTTPMessageGetResponseStatusCode(resp as! CFHTTPMessage)
            if code == 401 { return }
        }
        let read = _httpInfo.bytesRead + position.value
        if read < contentLength {
            _config.logger.log("HTTP stream end encountered whithout streamimg all content[\(contentLength)] , restart at postion \(read)", to: .streamProvider)
            startReconnectWatchDog()
        } else {
            _watchDogInfo.reset()
            outputPipeline.call(.endEncountered)
            guard _icyCastInfo.isIcyStream == false else { return }
            _cacheInfo.writeFile(targetLength: contentLength, url: info.url, header: registerHeader)
        }
    }

    func handleStreamError(_ targetStream: CFReadStream?) {
        let error: APlay.Error
        if let stream = targetStream, let err = CFReadStreamCopyError(stream), let desc = CFErrorCopyDescription(err) {
            error = APlay.Error.network(desc as String)
        } else {
            error = .none
        }
        guard info.isRemote else { return }
        let read = _httpInfo.bytesRead + position.value
        if read < contentLength {
            _watchDogInfo.startWatchDog(with: 2, at: _runloop) { [weak self] reachMaxRetryTime in
                guard let sself = self else { return }
                if reachMaxRetryTime {
                    sself.reachMaxRetryAndStopWatchDog()
                    return
                }
                let p = StreamProvider.Position(sself.position.value + sself._httpInfo.bytesRead)
                sself.close(resetTimer: false)
                guard p.value < sself.contentLength else {
                    sself._watchDogInfo.invalidateTimer()
                    let error = APlay.Error.streamParse("Start position[\(p.value)] exceeded content length[\(sself.contentLength)]")
                    sself.outputPipeline.call(.errorOccurred(error))
                    return
                }
                sself._open(at: p)
            }
        } else {
            _watchDogInfo.invalidateTimer()
            if case APlay.Error.none = error {}
            else {
                outputPipeline.call(.errorOccurred(error))
            }
        }
    }
}

// MARK: - Http Stuff

private extension Streamer {
    final class HttpInfo {
        lazy var bytesRead: UInt = 0
        lazy var isHeadersParsed = false
        lazy var auth: CFHTTPAuthentication? = nil
        lazy var credentials: [String: String]? = nil
        init() {}

        func reset() {
            bytesRead = 0
            isHeadersParsed = false
            auth = nil
            credentials = nil
        }

        func parseHttpHeaders(for streamer: Streamer, buffer: UnsafeMutablePointer<UInt8>, bufSize: Int) {
            if isHeadersParsed { return }
            guard let readStream = streamer._readStream else { return }
            isHeadersParsed = true

            if bufSize >= 10 {
                var datas = [UInt8]()
                // HTTP/1.x 200 OK
                /* If the response has the "ICY 200 OK" string,
                 * we are dealing with the ShoutCast protocol.
                 * The HTTP headers won't be available.
                 */
                var icy = ""
                for i in 0 ..< 4 {
                    let buf = buffer.advanced(by: i).pointee
                    datas.append(buf)
                }
                var data = Data(bytes: datas)
                icy = String(data: data, encoding: .ascii) ?? ""
                for i in 4 ..< 10 {
                    let buf = buffer.advanced(by: i).pointee
                    datas.append(buf)
                }
                data = Data(bytes: datas)
                icy = String(data: data, encoding: .ascii) ?? ""
                // This is an ICY stream, don't try to parse the HTTP headers
                if icy.lowercased() == "icy 200 ok" { return }
            }

            streamer._config.logger.log("A regular HTTP stream", to: .streamProvider)

            guard let resp = CFReadStreamCopyProperty(readStream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)) else { return }
            let response = resp as! CFHTTPMessage
            var statusCode = 0

            let keys = streamer._config.httpFileCompletionValidator.keys
            for key in keys {
                let cfKey = key as CFString
                guard let cfValue = CFHTTPMessageCopyHeaderFieldValue(response, cfKey)?.takeRetainedValue() else { continue }
                streamer.registerHeader[key] = cfValue as String
            }
            /*
             * If the server responded with the icy-metaint header, the response
             * body will be encoded in the ShoutCast protocol.
             */
            let icyMetaIntString = CFHTTPMessageCopyHeaderFieldValue(response, Keys.icyMetaint.cf)?.takeRetainedValue()
            let icyNotice1String = CFHTTPMessageCopyHeaderFieldValue(response, Keys.icyNotice1.cf)?.takeRetainedValue()
            if let meta = icyMetaIntString {
                streamer._icyCastInfo.isIcyStream = true
                streamer._icyCastInfo.isHeadersParsed = true
                streamer._icyCastInfo.isHeadersRead = true
                let interval = Int(CFStringGetIntValue(meta))
                streamer._icyCastInfo.metaDataInterval = interval
                streamer._config.logger.log("\(Keys.icyMetaint.rawValue): \(interval)", to: .streamProvider)
            } else if let notice = icyNotice1String {
                streamer._icyCastInfo.isIcyStream = true
                streamer._icyCastInfo.isHeadersParsed = true
                streamer._icyCastInfo.isHeadersRead = true
                streamer._config.logger.log("\(Keys.icyNotice1.rawValue): \(notice)", to: .streamProvider)
            }
            statusCode = CFHTTPMessageGetResponseStatusCode(response)
            streamer._config.logger.log("HTTP status code: \(statusCode)", to: .streamProvider)

            let icyNameString = CFHTTPMessageCopyHeaderFieldValue(response, Keys.icyName.cf)?.takeRetainedValue()
            if let name = icyNameString {
                let n = name as String
                streamer._icyCastInfo.name = n
                streamer.outputPipeline.call(.metadata([.title(n)]))
            }
            let ctype = CFHTTPMessageCopyHeaderFieldValue(response, Keys.contentType.cf)?.takeRetainedValue()
            if let contentType = ctype as String? {
                if case let .remote(url, hint) = streamer.info {
                    let newHint = StreamProvider.URLInfo.fileHint(from: contentType)
                    if newHint != .mp3, hint != newHint {
                        streamer.info = .remote(url, newHint)
                        streamer._tagParser = streamer.tagParser(for: streamer.info)
                    }
                }
                streamer._config.logger.log("\(Keys.contentType.rawValue): \(contentType)", to: .streamProvider)
            }

            let status200 = statusCode == 200
            let serverError = 500 ... 599
            let clen = CFHTTPMessageCopyHeaderFieldValue(response, Keys.contentLength.cf)?.takeRetainedValue()
            if let len = clen, status200 {
                streamer.contentLength = UInt(UInt64(CFStringGetIntValue(len)))
                streamer._config.logger.log("Content Length:\(streamer.contentLength)", to: .streamProvider)
            }
            if status200 || statusCode == 206 {
                streamer.outputPipeline.call(.readyForReady)
            } else {
                if [401, 407].contains(statusCode) {
                    let responseHeader = CFReadStreamCopyProperty(readStream, CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)) as! CFHTTPMessage
                    // Get the authentication information from the response.
                    let authentication = CFHTTPAuthenticationCreateFromResponse(nil, responseHeader).takeRetainedValue()
                    if CFHTTPAuthenticationRequiresUserNameAndPassword(authentication) {
                        if case let .custom(info) = streamer._config.proxyPolicy {
                            var credentials: [String: String] = [:]
                            credentials[kCFHTTPAuthenticationUsername as String] = info.username
                            credentials[kCFHTTPAuthenticationPassword as String] = info.password
                            self.credentials = credentials
                            auth = authentication
                        }
                    }
                    streamer._config.logger.log("Did recieve authentication challenge", to: .streamProvider)
                    streamer._watchDogInfo.reset()
                    streamer.startReconnectWatchDog()
                } else if serverError.contains(statusCode) {
                    streamer._config.logger.log("Server error:\(statusCode)", to: .streamProvider)
                    streamer._watchDogInfo.reset()
                    streamer.startReconnectWatchDog()
                } else {
                    let error = APlay.Error.networkStatusCode(statusCode)
                    streamer.outputPipeline.call(.errorOccurred(error))
                }
            }
        }
    }
}

// MARK: - Watch Dog Stuff

private extension Streamer {
    func reachMaxRetryAndStopWatchDog() {
        _watchDogInfo.invalidateTimer()
        outputPipeline.call(.errorOccurred(APlay.Error.reachMaxRetryTime))
    }

    func startReconnectWatchDog() {
        _watchDogInfo.startWatchDog(with: 0.5, at: _runloop) { [weak self] reachMaxRetryTime in
            guard let sself = self else { return }
            if reachMaxRetryTime {
                sself.reachMaxRetryAndStopWatchDog()
                return
            }
            let p: StreamProvider.Position
            sself._watchDogInfo.invalidateTimer()
            if sself._watchDogInfo.isReadedData == false { p = sself.position }
            else if sself.position.value + sself._httpInfo.bytesRead < sself.contentLength, sself.contentLength > 0 {
                p = StreamProvider.Position(sself.position.value + sself._httpInfo.bytesRead)
                sself.destroy()
            } else { p = 0 }
            sself._open(at: p)
        }
    }

    final class WatchDogInfo {
        private lazy var openTimer: CFRunLoopTimer? = nil
        lazy var reopenTimes: UInt = 0
        lazy var isReadedData = false
        private var callback: (Bool) -> Void = { _ in }
        private var _maxRemoteStreamOpenRetry: UInt = 5
        init(maxRemoteStreamOpenRetry: UInt) { _maxRemoteStreamOpenRetry = maxRemoteStreamOpenRetry }

        func invalidateTimer() {
            guard let timer = openTimer else { return }
            CFRunLoopTimerInvalidate(timer)
        }

        func reset() {
            invalidateTimer()
            reopenTimes = 0
            isReadedData = false
        }

        func startWatchDog(with interval: TimeInterval, at queue: RunloopQueue, callback: @escaping (Bool) -> Void) {
            self.callback = callback
            invalidateTimer()
            let this = UnsafeMutableRawPointer.from(object: self)
            var ctx = CFRunLoopTimerContext(version: 0, info: this, retain: nil, release: nil, copyDescription: nil)
            let callback: CFRunLoopTimerCallBack = { _, info in
                guard let raw = info else { return }
                let sself = raw.to(object: WatchDogInfo.self)
                sself.callback(sself.reopenTimes > sself._maxRemoteStreamOpenRetry)
            }
            guard let timer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0, callback, &ctx) else { return }
            queue.addTimer(timer)
            openTimer = timer
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
                streamer.outputPipeline.call(.readyForReady)
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
                if var buffer = buffer, i > 0 {
                    streamer.outputPipeline.call(.hasBytesAvailable(&buffer, UInt32(i), streamer._isFirstPacket))
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

    final class CacheInfo {
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
            guard position.value != _fileWritten else { return }
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
            DispatchQueue.global(qos: .utility).async {
                if case let APlay.Configuration.HttpFileValidationPolicy.validateHeader(keys: _, closure) = self._config.httpFileCompletionValidator {
                    guard closure(url, tmp, header) else { return }
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

// MARK: - CFString Keys

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
        var cf: CFString { return rawValue as CFString }
    }
}
