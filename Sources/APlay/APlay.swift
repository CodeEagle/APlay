import AudioToolbox
import AVFoundation
import Combine

public final class APlay {
    @Published public private(set) var state: State = .idle
    public let configuration: ConfigurationCompatible
    public private(set) var urlInfo: StreamProvider.URLInfo = .default

    // MARK: Player

    private let _engine = AVAudioEngine()
    private let _playerNode = AVAudioPlayerNode()
    public var pluginNodes: [AVAudioNode] = [] {
        didSet {
            oldValue.forEach { _engine.detach($0) }
            reattachNodes()
            reconnectNodes()
        }
    }

    private var readFormat: AVAudioFormat {
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
    }

    public var volume: Float {
        get { return _engine.mainMixerNode.outputVolume }
        set { _engine.mainMixerNode.outputVolume = newValue }
    }

    var volumeRampTimer: Timer?
    var volumeRampTargetValue: Float?

    private var _playerTimer: GCDTimer?
    private var _currentTime: TimeInterval = 0
    private var _duration: TimeInterval = 0

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

    public var duration: TimeInterval? {
        guard _dataParser.info.isUpdated else {
            return nil
        }
        let sampleRate = _dataParser.info.srcFormat.sampleRate

        guard let totalFrameCount = totalFrameCount else {
            return nil
        }

        return TimeInterval(totalFrameCount) / TimeInterval(sampleRate)
    }

    public var totalFrameCount: AVAudioFrameCount? {
        let framesPerPacket =
            _dataParser.info.srcFormat.streamDescription.pointee.mFramesPerPacket

        guard let totalPacketCount = _totalPacketCount else {
            return nil
        }

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

    public init(configuration: ConfigurationCompatible) {
        _resourceManager = .init(configuration: configuration)
        _downloader = .init(configuration: configuration)
        _packetManager = .init(policy: configuration.seekPolicy)
        self.configuration = configuration
        addDownloadEventHandler()
        setupAudioEngine()
    }
}

// MARK: - Public API

public extension APlay {
    func play(_ url: URL) {
        do {
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
            if let c = converter { AudioConverterReset(c) }
            // start parse and convert
            _playerTimer?.resume()
            if !_engine.isRunning {
                do {
                    try _engine.start()
                } catch {
                    print(error)
                    //                    os_log("Failed to start engine: %@", log: Streamer.logger, type: .error, error.localizedDescription)
                }
            }
            let lastVolume = volumeRampTargetValue ?? volume
            volume = 0
            _playerNode.play()
            swellVolume(to: lastVolume)
            state = .playing
        } catch {
            state = .unknown(error)
            print(error)
        }
    }

    func seek(at time: TimeInterval = 0) {
        guard configuration.seekPolicy == .enable else { return }
        // Get the proper time and packet offset for the seek operation
        guard let frameOffset = frameOffset(forTime: time),
            let packetOffset = packetOffset(forFrame: frameOffset) else {
            return
        }
        currentTimeOffset = time
        isFileSchedulingComplete = false

        // We need to store whether or not the player node is currently playing to properly resume playback after
        let isPlaying = _playerNode.isPlaying
        let lastVolume = volumeRampTargetValue ?? volume

        // Stop the player node to reset the time offset to 0
        _playerNode.stop()
        volume = 0

        // Perform the seek to the proper packet offset
        _packetManager.changeNextSchedulePacketId(to: Int(packetOffset))

        // If the player node was previous playing then resume playback
        if isPlaying {
            _playerNode.play()
        }
        state = .playing
        // Update the current time
//               delegate?.streamer(self, updatedCurrentTime: time)
        // After 250ms we restore the volume back to where it was
        swellVolume(to: lastVolume)
    }

    func swellVolume(to newVolume: Float, duration: TimeInterval = 0.5, delayMS: Int = 0) {
        volumeRampTargetValue = newVolume
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMS + Int(duration * 1000 / 2))) { [weak self] in
            guard let sself = self else { return }
            sself.volumeRampTimer?.invalidate()
            let timer = Timer(timeInterval: Double(Float(duration / 2.0) / (newVolume * 10)), repeats: true) { [weak self] timer in
                guard let sself = self else { return }
                if sself.volume != newVolume {
                    sself.volume = min(newVolume, sself.volume + 0.1)
                } else {
                    sself.volumeRampTimer = nil
                    sself.volumeRampTargetValue = nil
                    timer.invalidate()
                }
            }
            RunLoop.current.add(timer, forMode: .common)
            sself.volumeRampTimer = timer
        }
    }

    func frameOffset(forTime time: TimeInterval) -> AVAudioFramePosition? {
        guard _dataParser.info.isUpdated,
            let frameCount = totalFrameCount,
            let duration = duration else {
            return nil
        }

        let ratio = time / duration
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
            let duration = duration else {
            return nil
        }

        return TimeInterval(frame) / TimeInterval(frameCount) * duration
    }
}

// MARK: - EventHandlers

private extension APlay {
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

extension APlay {
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

private extension APlay {
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
        let status = AudioConverterFillComplexBuffer(converter!, ReaderConverterCallback, context, &packets, buffer.mutableAudioBufferList, nil)
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
//        }
        return buffer
    }
}

func ReaderConverterCallback(_: AudioConverterRef,
                             _ packetCount: UnsafeMutablePointer<UInt32>,
                             _ ioData: UnsafeMutablePointer<AudioBufferList>,
                             _ outPacketDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                             _ context: UnsafeMutableRawPointer?) -> OSStatus {
    let reader = Unmanaged<APlay>.fromOpaque(context!).takeUnretainedValue()

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

// MARK: - Player

private extension APlay {
    func setupAudioEngine() {
        _engine.attach(_playerNode)
        reattachNodes()
        reconnectNodes()
        _engine.prepare()

        let interval = 1 / (readFormat.sampleRate / Double(_readBufferSize))
        _playerTimer = GCDTimer(interval: DispatchTimeInterval.milliseconds(Int(interval * 1000 / 2)), callback: { [weak self] _ in
            guard let sself = self else { return }
            sself.readLoop()
            sself.scheduleNextBuffer()
//            self.handleTimeUpdate()
//            self.notifyTimeUpdated()
            let delta = sself._duration - sself._currentTime
            if delta <= 0.01, sself._duration != 0 {
                print("play complete, delta:\(delta)")
                sself._playerTimer?.pause()
                sself._packetManager.reset()
                return
            }

            let t = floor(sself.currentTime)
            if t != floor(sself._currentTime) {
                sself._currentTime = sself.currentTime
                if sself._currentTime > sself._duration, sself._duration != 0 {
                    sself._currentTime = sself._duration
                }
                print(sself._currentTime)
            }
            if let d = sself.duration, d != sself._duration {
                sself._duration = d
                print("duration: \(d)")
            }
        })
        _playerTimer?.pause()
    }

    func reattachNodes() {
        for node in pluginNodes {
            _engine.attach(node)
        }
    }

    func reconnectNodes() {
        let startNode: AVAudioNode?
        let endNode: AVAudioNode?

        startNode = pluginNodes.first
        endNode = pluginNodes.last

        if let start = startNode {
            _engine.connect(_playerNode, to: start, format: readFormat)
            for i in stride(from: 0, to: pluginNodes.count, by: 2) {
                if let first = pluginNodes[safe: i],
                    let next = pluginNodes[safe: i + 1] {
                    _engine.connect(first, to: next, format: readFormat)
                }
            }
            if let end = endNode {
                _engine.connect(end, to: _engine.mainMixerNode, format: readFormat)
            }
        } else {
            _engine.connect(_playerNode, to: _engine.mainMixerNode, format: readFormat)
        }
    }

    var currentTime: TimeInterval {
        guard let nodeTime = _playerNode.lastRenderTime,
            let playerTime = _playerNode.playerTime(forNodeTime: nodeTime) else {
            return currentTimeOffset
        }
        let currentTime = TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
        return currentTime + currentTimeOffset
    }

    // MARK: - Scheduling Buffers

    func scheduleNextBuffer() {
//        guard let reader = reader else {
//            os_log("No reader yet...", log: Streamer.logger, type: .debug)
//            return
//        }

        guard isFileSchedulingComplete == false else { return }

        do {
            let nextScheduledBuffer = try read(_readBufferSize)
            _playerNode.scheduleBuffer(nextScheduledBuffer)
        } catch ReaderError.reachedEndOfFile {
//            os_log("Scheduler reached end of file", log: Streamer.logger, type: .debug)
            isFileSchedulingComplete = true
            print("isFileSchedulingComplete: true")
        } catch {
            print(error)
//            os_log("Cannot schedule buffer: %@", log: Streamer.logger, type: .debug, error.localizedDescription)
        }
    }
}



let ReaderReachedEndOfDataError: OSStatus = 932_332_581
let ReaderNotEnoughDataError: OSStatus = 932_332_582
let ReaderMissingSourceFormatError: OSStatus = 932_332_583
let ReaderNOPlayHEAD: OSStatus = 932_332_584

// MARK: - ReaderError

public enum ReaderError: LocalizedError {
    case cannotLockQueue
    case converterFailed(OSStatus)
    case waitForConverter
    case failedToCreateDestinationFormat
    case failedToCreatePCMBuffer
    case notEnoughData
    case parserMissingDataFormat
    case reachedEndOfFile
    case unableToCreateConverter(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .cannotLockQueue:
            return "Failed to lock queue"
        case let .converterFailed(status):
            return localizedDescriptionFromConverterError(status)
        case .failedToCreateDestinationFormat:
            return "Failed to create a destination (processing) format"
        case .failedToCreatePCMBuffer:
            return "Failed to create PCM buffer for reading data"
        case .notEnoughData:
            return "Not enough data for read-conversion operation"
        case .parserMissingDataFormat:
            return "Parser is missing a valid data format"
        case .reachedEndOfFile:
            return "Reached the end of the file"
        case let .unableToCreateConverter(status):
            return localizedDescriptionFromConverterError(status)
        case .waitForConverter:
            return "Wait for converter"
        }
    }

    func localizedDescriptionFromConverterError(_ status: OSStatus) -> String {
        switch status {
        case kAudioConverterErr_FormatNotSupported:
            return "Format not supported"
        case kAudioConverterErr_OperationNotSupported:
            return "Operation not supported"
        case kAudioConverterErr_PropertyNotSupported:
            return "Property not supported"
        case kAudioConverterErr_InvalidInputSize:
            return "Invalid input size"
        case kAudioConverterErr_InvalidOutputSize:
            return "Invalid output size"
        case kAudioConverterErr_BadPropertySizeError:
            return "Bad property size error"
        case kAudioConverterErr_RequiresPacketDescriptionsError:
            return "Requires packet descriptions"
        case kAudioConverterErr_InputSampleRateOutOfRange:
            return "Input sample rate out of range"
        case kAudioConverterErr_OutputSampleRateOutOfRange:
            return "Output sample rate out of range"
        #if os(iOS)
            case kAudioConverterErr_HardwareInUse:
                return "Hardware is in use"
            case kAudioConverterErr_NoHardwarePermission:
                return "No hardware permission"
        #endif
        default:
            return "Unspecified error"
        }
    }
}

extension Array {
    public subscript(safe idx: Int) -> Element? {
        return indices ~= idx ? self[idx] : nil
    }
}
