import Foundation

public final class Composer {
    @Published public private(set) var state: State = .idle
        public let configuration: ConfigurationCompatible
        public private(set) var urlInfo: StreamProvider.URLInfo = .default

        // MARK: Player

        private var readFormat: AVAudioFormat {
            return AVAudioFormat(streamDescription: &Player.canonical)!
        }


        private var volumeRampTimer: GCDTimer?
        private var volumeRampTargetValue: Float?

        private var _readerTimer: GCDTimer?
        private var _playerTimer: GCDTimer?
        private lazy var _renderProgress: Float = 0
        private var renderProgress: Float {
            get { return _queue.sync { self._renderProgress } }
            set { _queue.asyncWrite { self._renderProgress = newValue } }
        }

        private var _duration: TimeInterval = 0
        private var _currentTime: TimeInterval = 0
        public private(set) var playlist: PlayList = .init()

        // MARK: Event

        private var _eventSubject: CurrentValueSubject<Event, Never> = .init(.state(.idle))
        public var eventPublisher: AnyPublisher<Event, Never> { _eventSubject.eraseToAnyPublisher() }

        // MARK: Progress

        public var progressPublisher: AnyPublisher<URLSessionDelegator.Info, Never> { _progressSubject.eraseToAnyPublisher() }
        public var progress: URLSessionDelegator.Info { _progressSubject.value }
        private var _progressSubject: CurrentValueSubject<URLSessionDelegator.Info, Never> = .init(.default)

        // MARK: Downloader

        private var _downloader: Downloader
        private var _urlReponse: URLResponse?
        private lazy var _retryCount: UInt = 0

        // MARK: Parser

        @LateInit fileprivate var _dataParser: DataParser
        private var _dataParserSubscriber: AnyCancellable?

        private var _tagParser: MetadataParserCompatible?
        private var _tagParserSubscriber: AnyCancellable?

        fileprivate var _packetManager: PacketManager

        private var _readBufferSize: AVAudioFrameCount { return AVAudioFrameCount(configuration.decodeBufferSize) }

        private var _totalPacketCount: AVAudioPacketCount? {
            guard _dataParser.info.isUpdated else {
                return nil
            }
            var packetCount = UInt64(_dataParser.info.audioDataPacketCount)
            if _dataParser.info.metadataSize != 0 {
                // TODO: reduce packetCount if needed

                // remove haeder padding for flac to get precis packet count
                if _dataParser.info.fileHint == .flac, let paddings = _dataParser.info.flacMetadata?.paddings {
                    let totalPaddingSize = paddings.reduce(0) { $0 + $1.length }
                    packetCount -= UInt64(ceil(Float(totalPaddingSize) / Float(_dataParser.info.packetBufferSize)))
                }
            }
            return max(AVAudioPacketCount(packetCount), AVAudioPacketCount(_packetManager.packetCount))
        }

        fileprivate var _isParsingComplete: Bool {
            guard let totalPacketCount = _totalPacketCount else { return false }

            return _packetManager.packetCount == totalPacketCount
        }

        var duration: Float {
            let _srcFormat = _dataParser.info.srcFormat.streamDescription.pointee
            let framesPerPacket = _srcFormat.mFramesPerPacket
            let rate = _srcFormat.mSampleRate
            if _dataParser.info.audioDataPacketCount > 0, framesPerPacket > 0 {
                return Float(_dataParser.info.audioDataPacketCount) * Float(framesPerPacket) / Float(rate)
            }
            // Not enough data provided by the format, use bit rate based estimation
            var audioFileLength: UInt64 = 0
            let _audioDataByteCount = UInt64(_dataParser.info.audioDataByteCount)
            let _metaDataSizeInBytes = UInt64(_dataParser.info.metadataSize)
            let contentLength = urlInfo.contentLength
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
                let bitrate = Float(_dataParser.info.bitrate)
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

    //    public var duration: TimeInterval? {
    //        guard _dataParser.info.isUpdated else { return nil }
    //        let sampleRate = _dataParser.info.srcFormat.sampleRate
    //
    //        guard let totalFrameCount = totalFrameCount else { return nil }
    //
    //        return TimeInterval(totalFrameCount) / TimeInterval(sampleRate)
    //    }

        public var totalFrameCount: AVAudioFrameCount? {
            let framesPerPacket = _dataParser.info.srcFormat.streamDescription.pointee.mFramesPerPacket

            guard let totalPacketCount = _totalPacketCount else { return nil }

            return AVAudioFrameCount(totalPacketCount) * AVAudioFrameCount(framesPerPacket)
        }

        // MARK: Converter

        private var _converter: AudioConverterRef?
        private var converter: AudioConverterRef? {
            get { return _queue.sync { self._converter } }
            set { _queue.asyncWrite { self._converter = newValue } }
        }

        // MARK: Others

        /// A `TimeInterval` used to calculate the current play time relative to a seek operation.
        var currentTimeOffset: TimeInterval = 0

        /// A `Bool` indicating whether the file has been completely scheduled into the player node.
        var isFileSchedulingComplete = false

        /// ThreadSafe Queue
        private var _queue: DispatchQueue = DispatchQueue(concurrentName: "APlay")
        /// Subscribers Bag
        private lazy var _cancellableBag: Set<AnyCancellable> = []

        /// Read & Write Resource
        private var _resourceManager: ResourcesManager

        deinit {
            _cancellableBag.forEach { $0.cancel() }
        }
    
    private let _player: APlayer
    
    private let _ringBuffer = Uroboros(capacity: 2 << 21) // 2 MB
    
    public init(configuration: ConfigurationCompatible) {
        _player = .init(config: configuration)
        _resourceManager = .init(configuration: configuration)
        _downloader = .init(configuration: configuration)
        _packetManager = .init(policy: configuration.seekPolicy)
        self.configuration = configuration
        addDownloadEventHandler()
        
        _player.readClosure = { [weak self] size, pointer in
            guard let sself = self else { return (0, false) }
            let r = sself._ringBuffer.read(amount: size, into: pointer)
//            let (readSize, isFirstData) = sself._ringBuffer.read(amount: size, into: pointer)
//            if sself._decoder.info.srcFormat.isLinearPCM, readSize == 0 {
//                sself._decoder.outputStream.call(.empty)
//            }
            return r
        }
        setupAudioEngine()
    }
    
    func setupAudioEngine() {

        let interval = 1 / (readFormat.sampleRate / Double(_readBufferSize))
        _readerTimer = GCDTimer(interval: DispatchTimeInterval.milliseconds(Int(interval * 1000 / 2)), callback: { [weak self] _ in
            guard let sself = self else { return }
            sself.readLoop()
        })
        _readerTimer?.pause()

        _playerTimer = GCDTimer(interval: DispatchTimeInterval.milliseconds(Int(interval * 1000)), callback: { [weak self] _ in
            guard let sself = self else { return }
            do {
                let nextScheduledBuffer = try sself.read(sself._readBufferSize)
                if let d = nextScheduledBuffer.mutableAudioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: UInt8.self) {
                    let bytes = nextScheduledBuffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize
                    sself._ringBuffer.write(data: d, amount: bytes)
                }
            } catch {
                if let e = error as? APlay.Error {
                    sself._eventSubject.send(.error(e))
                } else {
                    sself._eventSubject.send(.unknown(error))
                }
            }
        })
        _playerTimer?.pause()
    }
}

// MARK: - Public API

 public extension Composer {
    /// play with a autoclosure
    ///
    /// - Parameter url: a autoclosure to produce URL
    func play(_ url: @autoclosure () -> URL) {
        let u = url()
        let urls = [u]
        changeList(to: urls, at: 0)
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
        changeList(to: urls, at: index)
        guard let url = playlist.currentList[safe: index] else {
            let msg = "Can not found item at \(index) in list \(urls)"
            _eventSubject.send(.error(.playItemNotFound(msg)))
            return
        }
        _play(url)
    }

    func play(at index: Int) {
        guard let url = playlist.play(at: index) else {
            let msg = "Can not found item at \(index) in list \(playlist.list)"
            _eventSubject.send(.error(.playItemNotFound(msg)))
            return
        }
        _play(url)
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

    private func indexChanged() {
        let index = playlist.playingIndex
        _eventSubject.send(.playingIndexChanged(index))
    }

    private func resetConverter() {
        currentTimeOffset = 0
        isFileSchedulingComplete = false
        _duration = 0
        renderProgress = 0
        _currentTime = 0
        _downloader.cancel()
        if let c = converter {
            AudioConverterDispose(c)
            converter = nil
        }
    }

    private func _play(_ url: URL) {
        do {
            resetConverter()
            urlInfo = try _resourceManager.updateResource(for: url, at: 0)
            _dataParser = .init(configuration: configuration, info: nil)
            _dataParser.info.fileHint = urlInfo.fileHint
            _tagParser = urlInfo.tagParser(with: configuration)
            addTagParserEventHandler()
            addDataParserEventHandler()

            if urlInfo.hasLocalCached == false {
                _downloader.download(urlInfo)
            } else {
                let total = UInt64(urlInfo.localContentLength())
                _resourceManager.readWritePipeline.targetFileLength = total
            }
            // start parse and convert
            _readerTimer?.resume()
            _playerTimer?.resume()
            _player.resume()
            
            state = .playing
        } catch {
            state = .unknown(error)
            _eventSubject.send(.state(state))
        }
    }

    func changeList(to value: [URL], at index: Int) {
        playlist.changeList(to: value, at: index)
        let list = playlist.list
        _eventSubject.send(.playlistChanged(list))
        _eventSubject.send(.playingIndexChanged(.some(UInt(index))))
    }

    func seek(at time: TimeInterval = 0) {
    }
}

private extension Composer {
    func swellVolume(to newVolume: Float, duration: TimeInterval = 0.8, delayMS _: Int = 0) {
    }

    func frameOffset(forTime time: TimeInterval) -> AVAudioFramePosition? {
        guard _dataParser.info.isUpdated,
            let frameCount = totalFrameCount,
            duration > 0 else {
            return nil
        }

        let ratio = time / TimeInterval(duration)
        return AVAudioFramePosition(Double(frameCount) * ratio)
    }

    func packetOffset(forFrame frame: AVAudioFramePosition) -> AVAudioPacketCount? {
        guard _dataParser.info.isUpdated else { return nil }
        let framesPerPacket = _dataParser.info.srcFormat.streamDescription.pointee.mFramesPerPacket

        return AVAudioPacketCount(frame) / AVAudioPacketCount(framesPerPacket)
    }

    func timeOffset(forFrame frame: AVAudioFrameCount) -> TimeInterval? {
        guard _dataParser.info.isUpdated,
            let frameCount = totalFrameCount,
            duration > 0 else {
            return nil
        }
        return TimeInterval(frame) / TimeInterval(frameCount) * TimeInterval(duration)
    }
}
// MARK: - EventHandlers

private extension Composer {
    func addTagParserEventHandler() {
        _tagParserSubscriber?.cancel()
        _tagParserSubscriber = _tagParser?.eventPipeline.sink { [weak self] e in
            guard let sself = self else { return }
            print(e)
            switch e {
            case let .tagSize(size): sself._dataParser.info.metadataSize = UInt(size)
            case let .flac(value): sself._dataParser.info.flacMetadata = value
            default: break
            }
        }
    }

    func addDataParserEventHandler() {
        _dataParserSubscriber?.cancel()
        _dataParserSubscriber = _dataParser.eventPipeline.sink(receiveValue: { [weak self] event in
            guard let sself = self else { return }
            switch event {
            case let .createConverter(info):
                if sself.converter == nil {
                    let result = AudioConverterNew(info.srcFormat.streamDescription, sself.readFormat.streamDescription, &sself.converter)
                    if result != noErr {
                        print(String(describing: result.check()))
                    }
                }
            case let .parseFailure(state): if let str = state.check() { print(str) }

            case let .packet(val): sself._packetManager.createPacket(val)

            default: break
            }
        })
    }

    func addDownloadEventHandler() {
        _downloader.eventPipeline.sink { [weak self] event in
            guard let sself = self else { return }
            switch event {
            case let .onResponse(resp):
                sself._urlReponse = resp

            case let .onTotalByte(len):
                sself.urlInfo.remoteContentLength = len
                sself._resourceManager.readWritePipeline.targetFileLength = len - sself.urlInfo.startPosition

            case let .onData(data, info):
                if sself.urlInfo.hasLocalCached == false {
                    sself._resourceManager.write(data: data)
                }
                sself._progressSubject.send(info)

            case let .completed(result):
                switch result {
                case let .failure(e):
                    let r = sself.configuration.retryPolicy.canRetry(with: e, count: sself._retryCount)
                    if r.0 == true {
                        DispatchQueue.main.asyncAfter(deadline: .now() + r.1) { [weak self] in
                            guard let sself = self else { return }
                            sself._downloader.download(sself.urlInfo, preivous: sself._urlReponse)
                            sself._retryCount = sself._retryCount.addingReportingOverflow(1).partialValue
                        }
                    }

                case let .success(data):
                    guard sself.urlInfo != .default,
                        let resp = sself._urlReponse,
                        sself.configuration.remoteDataVerifyPolicy.verify(response: resp, data: data) else { return }
                    FileManager.copyItemByStripingTmpSuffix(at: sself._resourceManager.storePath)
                }
            default: break
            }
        }.store(in: &_cancellableBag)
    }
}

// MARK: - Parse Data

extension Composer {
    private func readLoop() {
        // already on queue.sync
        let sizeToReadOnce: Int = {
            let ret = Int(_readBufferSize)
            if _dataParser.info.fileHint == .flac || _dataParser.info.fileHint == .wave {
                // at least 10 to avoid lag(not enough data)
                return ret * 10
            }
            return ret
        }()
        let result = _resourceManager.read(count: sizeToReadOnce)
        switch result {
        case .targetFileLenNotSet: break
        case .lengthCanNotBeNegative: break
        case .waitingForData: print("waiting")
        case .complete: break
        case let .available(data):
            _dataParser.onData(data)
            _tagParser?.acceptInput(data: data)
        }
    }
}

// MARK: - Converter

private extension Composer {
    func read(_ frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard converter != nil else {
            throw ReaderError.waitForConverter
        }
        
        let framesPerPacket = readFormat.streamDescription.pointee.mFramesPerPacket
        var packets = frames / framesPerPacket

        /// Allocate a buffer to hold the target audio data in the Read format
        guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: frames) else {
            throw ReaderError.failedToCreatePCMBuffer
        }
        buffer.frameLength = frames

        // Try to read the frames from the parser
//        try _queue.sync {
        let context = unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
        let status = AudioConverterFillComplexBuffer(converter!, ReaderConverterCallback2, context, &packets, buffer.mutableAudioBufferList, nil)
        guard status == noErr else {
            switch status {
            case ReaderMissingSourceFormatError:
                throw ReaderError.parserMissingDataFormat
            case ReaderReachedEndOfDataError:
                throw ReaderError.reachedEndOfFile
            case ReaderNotEnoughDataError:
                throw ReaderError.notEnoughData
            default:
                throw ReaderError.converterFailed(status)
            }
        }
        renderProgress += Float(frames)
//        }
        return buffer
    }
}

func ReaderConverterCallback2(_: AudioConverterRef,
                             _ packetCount: UnsafeMutablePointer<UInt32>,
                             _ ioData: UnsafeMutablePointer<AudioBufferList>,
                             _ outPacketDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                             _ context: UnsafeMutableRawPointer?) -> OSStatus {
    let reader = Unmanaged<Composer>.fromOpaque(context!).takeUnretainedValue()

    //
    // Make sure we have a valid source format so we know the data format of the parser's audio packets
    //
    let sourceFormat = reader._dataParser.info.srcFormat

    //
    // Check if we've reached the end of the packets. We have two scenarios:
    //     1. We've reached the end of the packet data and the file has been completely parsed
    //     2. We've reached the end of the data we currently have downloaded, but not the file
    //
    let packetIndex = reader._packetManager.toSchedulePacketId
    let packetsCreatedCount = reader._packetManager.packetCount
    let isEndOfData = packetIndex >= packetsCreatedCount
    if isEndOfData {
        if reader._isParsingComplete {
            packetCount.pointee = 0
            return ReaderReachedEndOfDataError
        } else {
            return ReaderNotEnoughDataError
        }
    }

    //
    // Copy data over (note we've only processing a single packet of data at a time)
    //

    guard let packet = reader._packetManager.nextPacket() else {
        return ReaderNOPlayHEAD
    }
    let data = packet.data
    let dataCount = data.count
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer.allocate(byteCount: dataCount, alignment: 0)

//    _ = data.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) in
//        memcpy((ioData.pointee.mBuffers.mData?.assumingMemoryBound(to: UInt8.self))!, bytes, dataCount)
//    }
    var ptr: [UInt8] = data.compactMap { $0 }
    memcpy((ioData.pointee.mBuffers.mData?.assumingMemoryBound(to: UInt8.self))!, &ptr, dataCount)
    ioData.pointee.mBuffers.mDataByteSize = UInt32(dataCount)

    //
    // Handle packet descriptions for compressed formats (MP3, AAC, etc)
    //
    let sourceFormatDescription = sourceFormat.streamDescription.pointee
    if sourceFormatDescription.mFormatID != kAudioFormatLinearPCM {
        if outPacketDescriptions?.pointee == nil {
            outPacketDescriptions?.pointee = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        }
        outPacketDescriptions?.pointee?.pointee.mDataByteSize = UInt32(dataCount)
        outPacketDescriptions?.pointee?.pointee.mStartOffset = 0
        outPacketDescriptions?.pointee?.pointee.mVariableFramesInPacket = 0
    }
    packetCount.pointee = 1
    reader._packetManager.increaseScheduledPacketId()
    return noErr
}
