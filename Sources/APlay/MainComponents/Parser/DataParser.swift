import AudioToolbox
import AudioUnit
import AVFoundation

public final class DataParser {
    private unowned let _configuration: ConfigurationCompatible
    private var _audioFileStream: AudioFileStreamID?
    private var _audioConverter: AudioConverterRef?
    private var _queue: DispatchQueue = DispatchQueue(concurrentName: "DataParser")
    private let _bufferSize: Int
    private(set) var info = Info()

    @Published private var _event: Event = .idle
    
    public var eventPipeline: AnyPublisher<Event, Never> { $_event.eraseToAnyPublisher() }

    init(configuration: ConfigurationCompatible, info: Info?) {
        _configuration = configuration
        _bufferSize = Int(configuration.decodeBufferSize)
        if let i = info {
            self.info.update(from: i)
        }
        let this = UnsafeMutableRawPointer.from(object: self)
        let propertyCallback: AudioFileStream_PropertyListenerProc = { userData, inAudioFileStream, propertyId, ioFlags in
            let sself = userData.to(object: DataParser.self)
            sself.propertyValueCallback(inAudioFileStream: inAudioFileStream, propertyId: propertyId, ioFlags: ioFlags)
        }
        let callback: AudioFileStream_PacketsProc = { userData, inNumberBytes, inNumberPackets, inInputData, inPacketDescriptions in
            let sself = userData.to(object: DataParser.self)
            sself.handleAudioPackets(bytes: inNumberBytes, packets: inNumberPackets, data: inInputData, packetDescriptions: inPacketDescriptions)
        }
        let result = AudioFileStreamOpen(this, propertyCallback, callback, kAudioFileMP3Type, &_audioFileStream)
        if result != noErr {
            _queue.asyncWrite { self._event = .openFailure(result) }
        }
    }

    func onData(_ data: Data) {
        // new queue to parser data
        _queue.asyncWrite { [weak self] in
            guard let self = self else { return }
            guard let streamID = self._audioFileStream else {
                return
            }
            let count = data.count
            let ptr = data.withUnsafeBytes { (raw) -> UnsafePointer<UInt8> in
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            }
            let result = AudioFileStreamParseBytes(streamID, UInt32(count), ptr, [])
            if result != noErr {
                // 1869640813
                self._event = .parseFailure(result)
            }
        }
    }
}

extension DataParser {
    public enum Event {
        case idle
        case openFailure(OSStatus)
        case parseFailure(OSStatus)
        case bitrate(UInt32)
        case createConverter(Info)
        case packet((Data, AudioStreamPacketDescription?))
    }
}

extension DataParser {
    private func propertyValueCallback(inAudioFileStream: AudioFileStreamID, propertyId: AudioFileStreamPropertyID, ioFlags _: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
        if info.isUpdated {
            _event = .createConverter(info)
            return
        }

        func bitrate() {
            guard info.bitrate == 0 else { return }
            let bitrate = info.bitrate
            let sizeReceivedForFirstTime = bitrate == 0
            var bitRateSize = UInt32(MemoryLayout.size(ofValue: bitrate))
            let err = AudioFileStreamGetProperty(inAudioFileStream,
                                                 kAudioFileStreamProperty_BitRate,
                                                 &bitRateSize, &info.bitrate)
            if err != noErr { info.bitrate = 0 }
            else if sizeReceivedForFirstTime { _event = .bitrate(info.bitrate) }
        }
        func dataOffset() {
            guard info.dataOffset == 0 else { return }
            var offset = UInt()
            var offsetSize = UInt32(MemoryLayout<UInt>.size)
            let result = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset)
            guard result == noErr else {
                _configuration.logger.log("reading kAudioFileStreamProperty_DataOffset property failed", to: .audioDecoder)
                return
            }
            info.dataOffset = offset
        }

        func audioDataByteCount() {
            guard info.audioDataByteCount == 0 else { return }
            var byteCountSize = UInt32(MemoryLayout.size(ofValue: info.audioDataByteCount))
            let err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &info.audioDataByteCount)
            if err != noErr { info.audioDataByteCount = 0 }
        }
        func audioDataPacketCount() {
            guard info.audioDataPacketCount == 0 else { return }
            var packetCountSize = UInt32(MemoryLayout.size(ofValue: info.audioDataPacketCount))
            let err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataPacketCount, &packetCountSize, &info.audioDataPacketCount)
            if err != noErr { info.audioDataPacketCount = 0 }
        }

        func fileFormatChanged() {
            guard let stream = _audioFileStream else { return }
            var fileFormat: [UInt8] = Array(repeating: 0, count: 4)
            var fileFormatSize = UInt32(4)
            AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FileFormat, &fileFormatSize, &fileFormat)
            let data = Data(fileFormat.reversed())
            guard let type = String(data: data, encoding: .utf8) else { return }
            info.fileHint = StreamProvider.URLInfo.fileHint(from: type)
        }

        func dataFormatChanged() {
            guard let stream = _audioFileStream else { return }
            var newASBD: AudioStreamBasicDescription = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &newASBD)
            info.sampleRate = newASBD.mSampleRate
            info.packetDuration = Double(newASBD.mFramesPerPacket) / info.sampleRate
            var packetBufferSize: UInt32 = 0
            var sizeOfPacketBufferSize: UInt32 = UInt32(MemoryLayout.size(ofValue: packetBufferSize))
            let result = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfPacketBufferSize, &packetBufferSize)
            if result != noErr || packetBufferSize == 0 {
                let error = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfPacketBufferSize, &packetBufferSize)
                if error != noErr || packetBufferSize == 0 {
                    info.packetBufferSize = 2048
                } else {
                    info.packetBufferSize = packetBufferSize
                }
            } else {
                info.packetBufferSize = packetBufferSize
            }
            guard newASBD.mFormatID != kAudioFormatLinearPCM else {
                info.srcFormat = AVAudioFormat(streamDescription: &newASBD)!
                info.dstFormat = newASBD
                return
            }
            info.srcFormat = AVAudioFormat(streamDescription: &newASBD)!
            _event = .createConverter(info)
        }

        func formatListChanged() {
            guard let stream = _audioFileStream else { return }
            var outWriteable: DarwinBoolean = false
            var formatListSize: UInt32 = 0
            guard AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable) == noErr else { return }
            var formatList: [AudioFormatListItem] = Array(repeating: AudioFormatListItem(), count: Int(formatListSize))
            guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FormatList, &formatListSize, &formatList) == noErr else { return }
            let increaseMent = MemoryLayout<AudioFormatListItem>.size
            let end = Int(formatListSize)
            var i = 0
            while i * increaseMent < end {
                var pasbd = formatList[i].mASBD
                if pasbd.mFormatID == kAudioFormatMPEG4AAC_HE || pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2 {
                    #if !targetEnvironment(simulator)
                        info.srcFormat = AVAudioFormat(streamDescription: &pasbd)!
                    #endif
                    break
                }
                i += increaseMent
            }
        }

        func readyToProducePackets() {
            info.infoUpdated()
        }

        switch propertyId {
        case kAudioFileStreamProperty_BitRate: bitrate()
        case kAudioFileStreamProperty_DataOffset: dataOffset()
        case kAudioFileStreamProperty_FileFormat: fileFormatChanged()
        case kAudioFileStreamProperty_DataFormat: dataFormatChanged()
        case kAudioFileStreamProperty_AudioDataByteCount: audioDataByteCount()
        case kAudioFileStreamProperty_AudioDataPacketCount: audioDataPacketCount()
        case kAudioFileStreamProperty_FormatList: formatListChanged()
        case kAudioFileStreamProperty_ReadyToProducePackets: readyToProducePackets()
        default: break
        }
    }
}

extension DataParser {
    func handleAudioPackets(bytes _: UInt32, packets packetCount: UInt32, data: UnsafeRawPointer, packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>) {
        let packetDescriptionsOrNil: UnsafeMutablePointer<AudioStreamPacketDescription>? = packetDescriptions
        let isCompressed = packetDescriptionsOrNil != nil
//        os_log("%@ - %d [bytes: %i, packets: %i, compressed: %@]", log: Parser.loggerPacketCallback, type: .debug, #function, #line, byteCount, packetCount, "\(isCompressed)")

        /// At this point we should definitely have a data format
        let dataFormat = info.srcFormat

//        /// Iterate through the packets and store the data appropriately
        if isCompressed {
            for i in 0 ..< Int(packetCount) {
                let packetDescription = packetDescriptions[i]
                let packetStart = Int(packetDescription.mStartOffset)
                let packetSize = Int(packetDescription.mDataByteSize)
                let packetData = Data(bytes: data.advanced(by: packetStart), count: packetSize)
                _queue.asyncWrite { self._event = .packet((packetData, packetDescription)) }
            }
        } else {
            let format = dataFormat.streamDescription.pointee
            let bytesPerPacket = Int(format.mBytesPerPacket)
            for i in 0 ..< Int(packetCount) {
                let packetStart = i * bytesPerPacket
                let packetSize = bytesPerPacket
                let packetData = Data(bytes: data.advanced(by: packetStart), count: packetSize)
                _queue.asyncWrite { self._event = .packet((packetData, nil)) }
            }
        }
    }

    /// Decoder Info
    public final class Info {
        private static let maxBitrateSample = 50
        public lazy var srcFormat: AVAudioFormat = {
            var asbd = AudioStreamBasicDescription()
            return AVAudioFormat(streamDescription: &asbd)!
        }()

        public lazy var dstFormat = Player.canonical
        public lazy var audioDataByteCount: UInt = 0
        public lazy var dataOffset: UInt = 0
        public lazy var sampleRate: Float64 = 0
        public lazy var packetDuration: Double = 0
        public lazy var packetBufferSize: UInt32 = 0
        public lazy var fileHint: AudioFileType = .mp3
        public lazy var bitrate: UInt32 = 0
        public lazy var audioDataPacketCount: UInt = 0
        public lazy var parseFlags: AudioFileStreamParseFlags = .discontinuity
        public lazy var metadataSize: UInt = 0
        public lazy var waveSubchunk1Size: UInt32 = 0
        public var flacMetadata: FlacMetadata?
        var isUpdated = false
        private lazy var bitrateIndexArray: [Double] = []
        private var isUpdatedOnce = false

        public init() {}

        func infoUpdated() { isUpdatedOnce = true }

        func reset() {
            var asbd = AudioStreamBasicDescription()
            srcFormat = AVAudioFormat(streamDescription: &asbd)!
            audioDataByteCount = 0
            dataOffset = 0
            sampleRate = 0
            packetDuration = 0
            packetBufferSize = 0
            fileHint = .mp3
            bitrate = 0
            audioDataPacketCount = 0
            parseFlags = .discontinuity
            metadataSize = 0
            waveSubchunk1Size = 0
            isUpdated = false
            bitrateIndexArray = []
            flacMetadata = nil
        }

        func update(from info: Info) {
            isUpdated = true
            srcFormat = info.srcFormat
            dstFormat = info.dstFormat
            audioDataByteCount = info.audioDataByteCount
            dataOffset = info.dataOffset
            sampleRate = info.sampleRate
            packetDuration = info.packetDuration
            packetBufferSize = info.packetBufferSize
            fileHint = info.fileHint
            bitrate = info.bitrate
            audioDataPacketCount = info.audioDataPacketCount
            parseFlags = .discontinuity
            metadataSize = info.metadataSize
            bitrateIndexArray = info.bitrateIndexArray
            waveSubchunk1Size = info.waveSubchunk1Size
            flacMetadata = info.flacMetadata
            infoUpdated()
        }

        func calculate(packet: AudioStreamPacketDescription) -> Bool {
            if bitrate == 0, packetDuration > 0, bitrateIndexArray.count < Info.maxBitrateSample {
                let value = Double(8 * packet.mDataByteSize) / packetDuration
                bitrateIndexArray.append(value)
                if bitrateIndexArray.count >= Info.maxBitrateSample {
                    bitrate = UInt32(bitrateIndexArray.reduce(0, +)) / UInt32(Info.maxBitrateSample)
                    return true
                }
            }
            return false
        }

        func seekable() -> Bool {
            guard isUpdatedOnce else { return false }
            if fileHint == .flac {
                guard let count = flacMetadata?.seekTable?.points.count else { return false }
                return count > 0
            }
            return true
        }
    }
}
