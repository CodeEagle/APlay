import Foundation

public final class Composer {
    @Published public private(set) var state: State = .idle
    public let configuration: ConfigurationCompatible
    public private(set) var urlInfo: StreamProvider.URLInfo = .default

    // MARK: Player

    private var readFormat: AVAudioFormat { return AVAudioFormat(streamDescription: &Player.canonical)! }

    private var volumeRampTimer: GCDTimer?
    private var volumeRampTargetValue: Float?

    private var _readerTimer: GCDTimer?
    private var _playerTimer: GCDTimer?

    private var _duration: TimeInterval = 0
    private var _currentTime: TimeInterval = 0

    // MARK: Event

    private var _eventSubject: CurrentValueSubject<Event, Never> = .init(.state(.idle))
    public var eventPublisher: AnyPublisher<Event, Never> { _eventSubject.eraseToAnyPublisher() }

    // MARK: Downloader

    private var _downloader: Downloader
    private var _urlReponse: URLResponse?
    private lazy var _retryCount: UInt = 0

    // MARK: Parser

    @LateInit fileprivate var _dataParser: DataParser
    var dataParserInfo: DataParser.Info { return _dataParser.info }
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

    private let _player: APlayer

    private let _ringBuffer = Uroboros(capacity: 2 << 21) // 2 MB
    
    deinit { _cancellableBag.forEach { $0.cancel() } }

    public init(configuration: ConfigurationCompatible) {
        _player = .init(config: configuration)
        _resourceManager = .init(configuration: configuration)
        _downloader = .init(configuration: configuration)
        _packetManager = .init(policy: configuration.seekPolicy)
        self.configuration = configuration
        addDownloadEventHandler()

        _player.readClosure = { [weak self] size, pointer in
            guard let sself = self else { return 0 }
            let r = sself._ringBuffer.read(amount: size, into: pointer)
            let readSize = r.0
            if readSize == 0 {
//                sself._eventSubject.send(.waitForStreaming)
            }
            return readSize
        }
        var lastDuraion = -1
        _player.eventPipeline.sink { [weak self] e in
            guard let sself = self else { return }
            if case let Event.playback(val) = e {
                let d = Int(ceil(sself.duration))
                let targetPos = Int(ceil(val))
                if lastDuraion != d {
                    lastDuraion = d
                    sself._eventSubject.send(.duration(d))
                } else if targetPos >= d, d != 0 {
                    sself._eventSubject.send(.playEnded)
                }
            }
            sself._eventSubject.send(e)
        }.store(in: &_cancellableBag)
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
                if case ReaderError.reachedEndOfFile = error {
                    if sself.isFileSchedulingComplete == false {
                        sself.isFileSchedulingComplete = true
                        sself._eventSubject.send(.streamerEndEncountered)
                    }
                } else if let e = error as? APlay.Error {
                    sself._eventSubject.send(.error(e))
                } else {
                    sself._eventSubject.send(.unknown(error))
                }
            }
        })
        _playerTimer?.pause()
    }
    
    private func resetConverter() {
        currentTimeOffset = 0
        isFileSchedulingComplete = false
        _duration = 0
        _currentTime = 0
        _downloader.cancel()
        if let c = converter {
            AudioConverterDispose(c)
            converter = nil
        }
    }

    func play(_ url: URL, at position: StreamProvider.Position = 0, time: Float = 0, dataParserInfo: DataParser.Info? = nil) {
        do {
            resetConverter()
            urlInfo = try _resourceManager.updateResource(for: url, at: position)
            _dataParser = .init(configuration: configuration, info: dataParserInfo)
            if dataParserInfo == nil {
                _dataParser.info.fileHint = urlInfo.fileHint
            }
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
            _player.startTime = time

            state = .playing
        } catch {
            state = .unknown(error)
            _eventSubject.send(.state(state))
        }
    }
}

private extension Composer {
    func swellVolume(to newVolume: Float, duration: TimeInterval = 0.8, delayMS _: Int = 0) {}

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
                    if info.srcFormat.streamDescription.pointee.mFormatID != kAudioFormatLinearPCM {
                        let result = AudioConverterNew(info.srcFormat.streamDescription, sself.readFormat.streamDescription, &sself.converter)
                        if result != noErr {
                            print(String(describing: result.check()))
                        }
                    } else {
                        sself._player.update(info.srcFormat.streamDescription.pointee)
                        sself._playerTimer?.pause()
                    }
                }
            case let .parseFailure(state): if let str = state.check() { print(str) }

            case let .packet(val):
                if sself._dataParser.info.srcFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM {
                    for item in val {
                        var d: Data = item.0
                        sself._ringBuffer.write(data: &d, amount: UInt32(d.count))
                    }
                } else {
                    sself._packetManager.createPacket(val)
                }
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
                sself._eventSubject.send(.buffering(info))

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
            parseWaveFile(data)
            var targetD = data
            if _player.startTime != 0,
                _dataParser.info.srcFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
                _dataParser.info.waveHeader.isEmpty == false,
                _dataParser.info.isApplyWaveHeaderOnce == false {
                _dataParser.info.isApplyWaveHeaderOnce = true
                var d = _dataParser.info.waveHeader.advanced(by: 0)
                d.append(targetD)
                targetD = d
            }
            _dataParser.onData(targetD)
            _tagParser?.acceptInput(data: targetD)
        }
    }
    
    func position(for time: inout TimeInterval) -> StreamProvider.Position {
        let d = duration
        guard d > 0 else { return 0 }
        var finalTime = time
        if time > TimeInterval(d) { finalTime = TimeInterval(d) - 1 }
        let percentage = Float(finalTime) / d
        // more accuracy using `_decoder.streamInfo.metadataSize` then `streamerinfo.dataOffset`, may id3v2 and id3v1 tag both exist.
        var dataOffset = percentage * Float(urlInfo.contentLength - UInt64(_dataParser.info.metadataSize))

        let fileHint = urlInfo.fileHint
        if fileHint == .wave {
            let blockSize = Float(_dataParser.info.waveSubchunk1Size)
            let min = Int(dataOffset / blockSize)
            dataOffset = Float(min) * blockSize
        } else if fileHint == .flac, let flac = _dataParser.info.flacMetadata {
            // https://github.com/xiph/flac/blob/01eb19708c11f6aae1013e7c9c29c83efda33bfb/src/libFLAC/stream_decoder.c#L2990-L3198
            // consider no seektable condition
            if let (targetTime, offset) = flac.nearestOffset(for: time) {
                dataOffset = Float(offset)
                debug_log("flac seek: support to \(time), real time:\(targetTime)")
                time = targetTime
            }
        }
        let seekByteOffset = Float(_dataParser.info.dataOffset) + dataOffset
        return StreamProvider.Position(UInt(seekByteOffset))
    }
    
    func parseWaveFile(_ data: Data) {
        guard _dataParser.info.waveSubchunk1Size == 0,
            _dataParser.info.sampleRate == 0,
            _dataParser.info.audioDataByteCount == 0,
            _dataParser.info.audioDataPacketCount == 0,
            _dataParser.info.dataOffset == 0 else {
            return
        }
        let raw8: [UInt8] = data.map { $0 }
        let raw: UnsafePointer<UInt8> = raw8.withUnsafeBytes { (p) -> UnsafePointer<UInt8> in
            return p.bindMemory(to: UInt8.self).baseAddress!
        }
        let headerData = Data(bytes: raw, count: 4)
        guard let header = String(data: headerData, encoding: .ascii), header == "RIFF" else {
            return
        }

//        let chunkSize: UInt32 = [4, 5, 6, 7].compactMap{ raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)
        let waveData = Data(bytes: raw.advanced(by: 8), count: 4)
        guard let waveHeader = String(data: waveData, encoding: .ascii), waveHeader == "WAVE" else {
            return
        }

        let formatData = Data(bytes: raw.advanced(by: 12), count: 4)
        guard let formatHeader = String(data: formatData, encoding: .ascii), formatHeader == "fmt " else {
            return
        }

        let subchunk1Size = [16, 17, 18, 19].compactMap { raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)
        
    //        let audioFormat = [20, 21].compactMap{ raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)
            let numChannels = [22, 23].compactMap { raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)

            let sampleRate = [24, 25, 26, 27].compactMap { raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)

            let byteRate = [28, 29, 30, 31].compactMap { raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)

            let blockAlign = [32, 33].compactMap { raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)

            let bitsPerSample = [34, 35].compactMap { raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)

            let totalSize: UInt32
            let dataData: Data
            // https://stackoverflow.com/questions/19991405/how-can-i-detect-whether-a-wav-file-has-a-44-or-46-byte-header
            let offset: Int
            if subchunk1Size == 18 {
                totalSize = 46
                offset = 2
                dataData = Data(bytes: raw.advanced(by: 38), count: 4)
            } else {
                totalSize = 44
                offset = 0
                dataData = Data(bytes: raw.advanced(by: 36), count: 4)
            }
            guard let dataHeader = String(data: dataData, encoding: .ascii), dataHeader == "data" else {
                return
            }
        let info = _dataParser.info
        var srcFormat = AudioStreamBasicDescription()
            let start = 40 + offset
            let subchunk2Size = [start, start + 1, start + 2, start + 3].compactMap { raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)

            srcFormat.mSampleRate = Float64(sampleRate)
            srcFormat.mFormatID = kAudioFormatLinearPCM
            srcFormat.mFramesPerPacket = 1 // For uncompressed audio, the value is 1. For variable bit-rate formats, the value is a larger fixed number, such as 1024 for AAC
            srcFormat.mChannelsPerFrame = numChannels
            srcFormat.mBytesPerFrame = srcFormat.mChannelsPerFrame * 2
            srcFormat.mBytesPerPacket = srcFormat.mFramesPerPacket * srcFormat.mBytesPerFrame
            // why??
            srcFormat.mBitsPerChannel = bitsPerSample
            srcFormat.mReserved = 0
            srcFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger |
                kAudioFormatFlagsNativeEndian |
                kLinearPCMFormatFlagIsPacked

            info.dstFormat = srcFormat
            info.waveSubchunk1Size = subchunk1Size
            info.dataOffset = UInt(totalSize)
            info.audioDataByteCount = UInt(subchunk2Size)
            info.audioDataPacketCount = info.audioDataByteCount / UInt(blockAlign)
            info.sampleRate = Float64(sampleRate)
            info.packetBufferSize = 2048
            info.packetDuration = Double(srcFormat.mFramesPerPacket) / info.sampleRate
//            // https://sound.stackexchange.com/questions/37424/how-do-you-compute-the-bitrate-of-a-wav-file
//            // http://www.theaudioarchive.com/TAA_Resources_File_Size.htm
//            // Bits Per Second (bps) = Sample Rate (Hz) * Word Length (bits) * Channel Count
//    //        let bitrate = UInt32(info.sampleRate) * info.srcFormat.mBitsPerChannel * info.srcFormat.mChannelsPerFrame / 1000
            info.bitrate = byteRate * 8 / 1000
            _dataParser.info.srcFormat = AVAudioFormat(streamDescription: &srcFormat)!
        _dataParser.info.waveHeader = Data(bytes: raw, count: Int(totalSize))
        _dataParser.info.isApplyWaveHeaderOnce = false
        _dataParser.info.infoUpdated()
//            let left = data.1 - totalSize
//            let d = UnsafeRawPointer(raw.advanced(by: Int(totalSize)))
//            let ret = (d, left)
//            outputStream.call(.output(ret))
//            outputStream.call(.bitrate(info.bitrate))
        
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
