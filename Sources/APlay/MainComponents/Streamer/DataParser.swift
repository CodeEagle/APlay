import AudioToolbox
import AudioUnit

final class DataParser {
    private var _audioFileStream: AudioFileStreamID?
    private var _audioConverter: AudioConverterRef?
    private var _queue: DispatchQueue = DispatchQueue(concurrentName: "DataParser")
    @Published private var _event: Event = .idle

    init() {
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
            _event = .openFailure(result)
        }
    }

    func onData(_ data: Data) {
        // new queue to parser data
        _queue.asyncWrite { [weak self] in
            guard let self = self else { return }
            guard let streamID = self._audioFileStream else { return }
            let count = data.count
            let ptr = data.withUnsafeBytes { (raw) -> UnsafePointer<UInt8> in
                return raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            }
            let result = AudioFileStreamParseBytes(streamID, UInt32(count), ptr, [])
            if result != noErr {
                self._event = .parseFailure(result)
            }
        }
    }
}

extension DataParser {
    enum Event {
        case idle
        case openFailure(OSStatus)
        case parseFailure(OSStatus)
    }
}

extension DataParser {
    private func propertyValueCallback(inAudioFileStream: AudioFileStreamID, propertyId: AudioFileStreamPropertyID, ioFlags _: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
        /*
         if info.isUpdated {
             createConverter(with: info.srcFormat)
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
             else if sizeReceivedForFirstTime {
                 outputStream.call(.bitrate(info.bitrate))
             }
         }
         func dataOffset() {
             guard info.dataOffset == 0 else { return }
             var offset = UInt()
             var offsetSize = UInt32(MemoryLayout<UInt>.size)
             let result = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset)
             guard result == noErr else {
                 _config.logger.log("reading kAudioFileStreamProperty_DataOffset property failed", to: .audioDecoder)
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
                 info.srcFormat = newASBD
                 info.dstFormat = newASBD
                 return
             }
             createConverter(with: newASBD)
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
                 let pasbd = formatList[i].mASBD
                 if pasbd.mFormatID == kAudioFormatMPEG4AAC_HE || pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2 {
                     #if !targetEnvironment(simulator)
                     info.srcFormat = pasbd
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
         */
    }
}
extension DataParser {
    func handleAudioPackets(bytes byteCount: UInt32, packets packetCount: UInt32, data: UnsafeRawPointer, packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>) {
        let packetDescriptionsOrNil: UnsafeMutablePointer<AudioStreamPacketDescription>? = packetDescriptions
        let isCompressed = packetDescriptionsOrNil != nil
//        os_log("%@ - %d [bytes: %i, packets: %i, compressed: %@]", log: Parser.loggerPacketCallback, type: .debug, #function, #line, byteCount, packetCount, "\(isCompressed)")
        
        /// At this point we should definitely have a data format
//        guard let dataFormat = parser.dataFormat else {
//            return
//        }
//
//        /// Iterate through the packets and store the data appropriately
//        if isCompressed {
//            for i in 0 ..< Int(packetCount) {
//                let packetDescription = packetDescriptions[i]
//                let packetStart = Int(packetDescription.mStartOffset)
//                let packetSize = Int(packetDescription.mDataByteSize)
//                let packetData = Data(bytes: data.advanced(by: packetStart), count: packetSize)
//                parser.packets.append((packetData, packetDescription))
//            }
//        } else {
//            let format = dataFormat.streamDescription.pointee
//            let bytesPerPacket = Int(format.mBytesPerPacket)
//            for i in 0 ..< Int(packetCount) {
//                let packetStart = i * bytesPerPacket
//                let packetSize = bytesPerPacket
//                let packetData = Data(bytes: data.advanced(by: packetStart), count: packetSize)
//                parser.packets.append((packetData, nil))
//            }
//        }
    }

}
