//
//  DefaultAudioDecoder.swift
//  APlayer
//
//  Created by lincoln on 2018/4/16.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import AudioToolbox
import AudioUnit

final class DefaultAudioDecoder {
    private weak var _streamProvider: StreamProviderCompatible?
    private lazy var _info = AudioDecoder.Info()
    private lazy var _inputStream = Delegated<AudioDecoder.AudioInput, Void>()
    private lazy var _outputStream = Delegated<AudioDecoder.Event, Void>()

    private lazy var _propertiesQueue = DispatchQueue(concurrentName: "PacketIO")

    private var __packetLinkList: Packet?
    private weak var __packetLinkListTail: Packet?
    
    private var _packetLinkList: Packet? {
        get { return _propertiesQueue.sync { __packetLinkList } }
        set { _propertiesQueue.async(flags: .barrier) { self.__packetLinkList = newValue } }
    }
    private weak var _packetLinkListTail: Packet? {
        get { return _propertiesQueue.sync { __packetLinkListTail } }
        set { _propertiesQueue.async(flags: .barrier) { self.__packetLinkListTail = newValue } }
    }
    
    private lazy var _audioFileStream: AudioFileStreamID? = nil
    private lazy var __audioConverter: AudioConverterRef? = nil
    private var _audioConverter: AudioConverterRef? {
        get { return _propertiesQueue.sync { __audioConverter } }
        set { _propertiesQueue.async(flags: .barrier) { self.__audioConverter = newValue } }
    }

    private var _packetsManager: Uroboros

    private lazy var _decodeTimer: GCDTimer? = nil
    private lazy var _outputBuffer: [UInt8] = []
    private let asbdSize = UInt32(MemoryLayout<AudioStreamPacketDescription>.size)

    private unowned let _config: ConfigurationCompatible
    private lazy var __isRequestClose = false
    private lazy var _isFlacHeaderParsed = false

    fileprivate var _isRequestClose: Bool {
        get { return _propertiesQueue.sync { __isRequestClose } }
        set { _propertiesQueue.async(flags: .barrier) { self.__isRequestClose = newValue } }
    }

    #if DEBUG
        deinit {
            debug_log("\(self) \(#function)")
        }
    #endif

    init(config: ConfigurationCompatible) {
        _config = config
        _packetsManager = Uroboros(capacity: _config.maxDecodedByteCount)
        _outputBuffer = Array(repeating: 0, count: Int(config.decodeBufferSize))
        _inputStream.delegate(to: self) { $0.inputAvailable($1) }
        initDecodeloop()
    }
}

// MARK: - AudioDecoderCompatible

extension DefaultAudioDecoder: AudioDecoderCompatible {
    func seekable() -> Bool {
        return info.seekable()
    }

    func destroy() {
        debug_log("DefaultAudioDecoder request destroy")
        _isRequestClose = true
        _decodeTimer?.invalidate()
        _packetsManager.clear()
    }

    var info: AudioDecoder.Info {
        get { return _propertiesQueue.sync { _info } }
        set { _propertiesQueue.async(flags: .barrier) { self._info = newValue } }
    }

    var outputStream: Delegated<AudioDecoder.Event, Void> { return _outputStream }

    var inputStream: Delegated<AudioDecoder.AudioInput, Void> { return _inputStream }

    func prepare(for provider: StreamProviderCompatible, at position: StreamProvider.Position) throws {
        _streamProvider = provider
        if position == 0 { info.reset() }
        try prepareParser(for: provider)
    }

    func pause() {
        _decodeTimer?.pause()
        _streamProvider?.pause()
    }

    func resume() {
        _decodeTimer?.resume()
        _streamProvider?.resume()
    }
}

// MARK: - Parser

private extension DefaultAudioDecoder {
    func prepareParser(for stream: StreamProviderCompatible) throws {
        let this = UnsafeMutableRawPointer.from(object: self)
        let fileHint = stream.info.fileHint.audioFileTypeID
        let propertyCallback: AudioFileStream_PropertyListenerProc = { userData, inAudioFileStream, propertyId, ioFlags in
            let sself = userData.to(object: DefaultAudioDecoder.self)
            sself.propertyValueCallback(inAudioFileStream: inAudioFileStream, propertyId: propertyId, ioFlags: ioFlags)
        }
        let callback: AudioFileStream_PacketsProc = { userData, inNumberBytes, inNumberPackets, inInputData, inPacketDescriptions in
            let sself = userData.to(object: DefaultAudioDecoder.self)
            sself.handleAudioPackets(bytes: inNumberBytes, packets: inNumberPackets, data: inInputData, packetDescriptions: inPacketDescriptions)
        }
        let result = AudioFileStreamOpen(this, propertyCallback, callback, fileHint, &_audioFileStream)
        if result != noErr {
            throw APlay.Error.parser(result)
        }
    }

    private func inputAvailable(_ data: AudioDecoder.AudioInput) {
        guard let stream = _audioFileStream else { return }
        let isWaveFormat = info.fileHint == .wave
        if isWaveFormat { _decodeTimer?.pause() }
        else { _decodeTimer?.resume() }
        if isWaveFormat {
            parserWaveFile(data)
            return
        }

        // flac seek support
        if info.fileHint == .flac, _isFlacHeaderParsed == false, let headerData = info.flacMetadata?.headerData {
            _isFlacHeaderParsed = true
            let count = UInt32(headerData.count)
            let pointer: [UInt8] = headerData.compactMap({ $0 })
            inputAvailable((UnsafePointer<UInt8>(pointer), count, true))
            inputAvailable(data)
            return
        }

        let flag: AudioFileStreamParseFlags = isWaveFormat ? .continuity : info.parseFlags
        let result = AudioFileStreamParseBytes(stream, data.1, data.0, flag)
        guard result == noErr else {
            #if DEBUG
                result.check()
            #endif
            outputStream.call(.error(.parser(result)))
            return
        }
        info.parseFlags = .continuity
    }

    // MARK: propertyValueCallback

    private func propertyValueCallback(inAudioFileStream: AudioFileStreamID, propertyId: AudioFileStreamPropertyID, ioFlags _: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
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
            let data = Data(bytes: fileFormat.reversed())
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
                    info.srcFormat = pasbd
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

// MARK: - Converter

private extension DefaultAudioDecoder {
    func destoryConverter() {
        guard let converter = _audioConverter else { return }
        AudioConverterDispose(converter)
        _audioConverter = nil
    }

    func createConverter(with source: AudioStreamBasicDescription) {
        var dst = info.dstFormat
        if dst.mFormatID == source.mFormatID,
            dst.mSampleRate == source.mSampleRate,
            dst.mBytesPerPacket == source.mBytesPerPacket,
            dst.mFormatFlags == source.mFormatFlags,
            dst.mBytesPerPacket == source.mBytesPerPacket,
            dst.mBitsPerChannel == source.mBitsPerChannel {
            dst = source
            destoryConverter()
            return
        }
        var source = source
        var status: OSStatus = noErr
        let size = MemoryLayout.size(ofValue: source)

        if memcmp(&source, &info.srcFormat, size) == 0, let converter = _audioConverter {
            AudioConverterReset(converter)
            return
        }
        destoryConverter()
        #if os(iOS)
            func GetHardwareCodecClassDesc(formatId: UInt32, classDesc: UnsafeMutablePointer<AudioClassDescription>) -> Bool {
                var size: UInt32 = 0
                var id = formatId
                let fidSize = UInt32(MemoryLayout.size(ofValue: formatId))
                if AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, fidSize, &id, &size) != noErr {
                    return false
                }
                let decoderCount = Int(size) / MemoryLayout<AudioClassDescription>.size
                var encoderDesc: [AudioClassDescription] = Array(repeating: AudioClassDescription(), count: decoderCount)
                if AudioFormatGetProperty(kAudioFormatProperty_Decoders, fidSize, &id, &size, &encoderDesc) != noErr {
                    return false
                }
                for i in 0 ..< decoderCount {
                    guard let desc = encoderDesc[ap_safe: i], desc.mManufacturer == kAppleHardwareAudioCodecManufacturer else { continue }
                    classDesc.pointee = desc
                    return true
                }
                return false
            }
            var classDesc: AudioClassDescription = AudioClassDescription()
            if GetHardwareCodecClassDesc(formatId: source.mFormatID, classDesc: &classDesc) {
                AudioConverterNewSpecific(&source, &dst, 1, &classDesc, &__audioConverter)
            }
        #endif
        if _audioConverter == nil {
            status = AudioConverterNew(&source, &dst, &_audioConverter)
            if status != noErr {
                _config.logger.log("Error in creating an audio converter, error \(status)", to: .audioDecoder)
                outputStream.call(.error(.parser(status)))
                return
            }
        }
        info.srcFormat = source
        guard let st = _audioFileStream, info.fileHint != .aacADTS else { return }
        var writable: DarwinBoolean = false
        var cookieSize: UInt32 = 0
        status = AudioFileStreamGetPropertyInfo(st, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable)
        guard status == noErr else { return }
        var cookiesData: [UInt8] = Array(repeating: 0, count: Int(cookieSize))
        status = AudioFileStreamGetProperty(st, kAudioConverterDecompressionMagicCookie, &cookieSize, &cookiesData)
        guard status == noErr, let audioConverterRef = _audioConverter else { return }
        status = AudioConverterSetProperty(audioConverterRef, kAudioConverterDecompressionMagicCookie, cookieSize, &cookiesData)
        if status != noErr {
            _config.logger.log("Error in creating an audio converter, error \(status)", to: .audioDecoder)
            outputStream.call(.error(.parser(status)))
        }
    }
}

// MARK: - Decode loop

private extension DefaultAudioDecoder {
    private func initDecodeloop() {
        _decodeTimer = GCDTimer(interval: .milliseconds(30), callback: { [weak self] _ in
            guard let sself = self else {
                debug_log("Decodeloop return at -1")
                return
            }
            if sself._isRequestClose {
                debug_log("Decodeloop return at 0")
                return
            }
            sself.decodeloopHandler()
        })
    }

    private func decodeloopHandler() {
        let _dstFormat = info.dstFormat
        let _outputBufferSize = UInt32(_config.decodeBufferSize)
        let listItem = AudioBuffer(mNumberChannels: info.dstFormat.mChannelsPerFrame, mDataByteSize: _outputBufferSize, mData: &_outputBuffer)
        var outputBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: listItem)
        var ioOutputDataPackets = _outputBufferSize / _dstFormat.mBytesPerPacket

        guard let converter = _audioConverter else { return }

        let bufferConverter = AudioBufferConverter(ring: self)
        let userinfo = UnsafeMutableRawPointer.from(object: bufferConverter)
        guard _isRequestClose == false else {
            debug_log("Decodeloop return at 1")
            return
        }
        let err = AudioConverterFillComplexBuffer(converter, AudioBufferConverter.callback(), userinfo, &ioOutputDataPackets, &outputBufferList, nil)
        if err == .empty {
            outputStream.call(.empty)
            return
        }
        guard err == noErr else {
            err.check()
            outputStream.call(.error(APlay.Error.parser(err)))
            return
        }
        guard _isRequestClose == false else {
            debug_log("Decodeloop return at 2")
            return
        }
        let bytes = outputBufferList.mBuffers.mDataByteSize
        if let inInputData = outputBufferList.mBuffers.mData, bytes > 0 {
            let out: AudioDecoder.AudioOutput = (UnsafeRawPointer(inInputData), bytes)
            outputStream.call(.output(out))
        } else {
            debug_log("wtf decode \(bytes) bytes")
        }
    }
}

// MARK: - Packet io v2

private extension DefaultAudioDecoder {
    final class Packet {
        let desc: AudioStreamPacketDescription
        let data: Data
        var next: Packet?
        init(desc: AudioStreamPacketDescription, value: UnsafeRawPointer, count: Int) {
            self.desc = desc
            data = Data.init(bytes: value, count: count)
        }
    }
    
    func handleAudioPacketsv2(bytes: UInt32, packets: UInt32, data: UnsafeRawPointer, packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        if info.srcFormat.isLinearPCM {
            outputStream.call(.output((data, bytes)))
            return
        }
        let total = Int(packets)
        for i in 0 ..< total {
            guard var desc = packetDescriptions?.advanced(by: i).pointee else { return }
            let offset = Int(desc.mStartOffset)
            // set to zero because decode packet singly, not in a list
            desc.mStartOffset = 0
            let packet = Packet(desc: desc, value: data.advanced(by: offset), count: Int(desc.mDataByteSize))
            if _packetLinkList == nil {
                _packetLinkList = packet
                _packetLinkListTail = packet
            } else {
                _packetLinkListTail?.next = packet
                _packetLinkListTail = packet
            }
            
            if info.calculate(packet: desc) {
                outputStream.call(.bitrate(info.bitrate))
            }
        }
    }
    
    func readPacket() -> Packet? {
        let value = _packetLinkList
        _packetLinkList = _packetLinkList?.next
        return value
    }
    
}

// MARK: - Packet io

private extension DefaultAudioDecoder {
    /*
     Packet Storage Struct

     Total Size = 4 + 16 + N (including [Total Size] block)

     +------------+------------------------------+---------+
     | Total Size | AudioStreamPacketDescription |  Data   |
     +------------+------------------------------+---------+
     | 4 Bytes    | 16 Bytes                     | N Bytes |
     +------------+------------------------------+---------+
     */

    // MARK: handleAudioPackets

    func handleAudioPackets(bytes: UInt32, packets: UInt32, data: UnsafeRawPointer, packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        if info.srcFormat.isLinearPCM {
            outputStream.call(.output((data, bytes)))
            return
        }
        let total = Int(packets)
        for i in 0 ..< total {
            guard var desc = packetDescriptions?.advanced(by: i).pointee else { return }

            let totalSize = asbdSize + desc.mDataByteSize + 4
            var totalSizeBytes = totalSize.asUInt8Array()

            let offset = Int(desc.mStartOffset)
            // set to zero because decode packet singly, not in a list
            desc.mStartOffset = 0
            _packetsManager.write(data: &totalSizeBytes, amount: UInt32(totalSizeBytes.count))
            _packetsManager.write(data: &desc, amount: asbdSize)
            _packetsManager.write(data: data.advanced(by: offset), amount: desc.mDataByteSize)
            if info.calculate(packet: desc) {
                outputStream.call(.bitrate(info.bitrate))
            }
        }
    }

    func readPacket(into handler: inout [UInt8]) -> AudioStreamPacketDescription? {
        var totalSizeBytes: [UInt8] = Array(repeating: 0, count: 4)
        let count = UInt32(totalSizeBytes.count)
        // availableData must larger than [Total Size] block
        guard _packetsManager.availableData > count else { return nil }
        // try to read next packet size without commit, if data not enough, skip and wait for next try.
        guard _packetsManager.read(amount: count, into: &totalSizeBytes, commitRead: false).0 == count else { return nil }
        let nextPacketSize = totalSizeBytes.unpack()

        guard _packetsManager.availableData >= nextPacketSize, _isRequestClose == false else { return nil }
        // commit read bytes of the [Total Size] block
        _packetsManager.commitRead(count: count)
        // read the rest of struct
        var desc = AudioStreamPacketDescription()
        _packetsManager.read(amount: asbdSize, into: UnsafeMutableRawPointer(&desc))
        let expectSize = Int(desc.mDataByteSize)
        guard expectSize > 0 else { return nil }
        handler.reserveCapacity(expectSize)
        let readSize = _packetsManager.read(amount: desc.mDataByteSize, into: &handler).0
        if readSize != expectSize {
            debug_log("Packet size not right, expect:\(expectSize), read:\(readSize)")
            return nil
        }
        return desc
    }
}

// MARK: - Wave Format Header Parser

extension DefaultAudioDecoder {
    func parserWaveFile(_ data: AudioDecoder.AudioInput) {
        guard info.sampleRate == 0, info.audioDataByteCount == 0, info.audioDataPacketCount == 0, info.dataOffset == 0 else {
            outputStream.call(.output((UnsafeRawPointer(data.0), data.1)))
            return
        }
        let raw = data.0
        let headerData = Data(bytes: raw, count: 4)
        guard let header = String(data: headerData, encoding: .ascii), header == "RIFF" else {
            outputStream.call(.error(.open("Not a validate wave format")))
            return
        }

//        let chunkSize: UInt32 = [4, 5, 6, 7].compactMap{ raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)

        let waveData = Data(bytes: raw.advanced(by: 8), count: 4)
        guard let waveHeader = String(data: waveData, encoding: .ascii), waveHeader == "WAVE" else {
            outputStream.call(.error(.open("Not a validate wave format")))
            return
        }

        let formatData = Data(bytes: raw.advanced(by: 12), count: 4)
        guard let formatHeader = String(data: formatData, encoding: .ascii), formatHeader == "fmt " else {
            outputStream.call(.error(.open("Not a validate wave format")))
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
            outputStream.call(.error(.open("Not a validate wave format")))
            return
        }
        let start = 40 + offset
        let subchunk2Size = [start, start + 1, start + 2, start + 3].compactMap { raw.advanced(by: $0).pointee }.unpack(isLittleEndian: true)

        info.srcFormat.mSampleRate = Float64(sampleRate)
        info.srcFormat.mFormatID = kAudioFormatLinearPCM
        info.srcFormat.mFramesPerPacket = 1 // For uncompressed audio, the value is 1. For variable bit-rate formats, the value is a larger fixed number, such as 1024 for AAC
        info.srcFormat.mChannelsPerFrame = numChannels
        info.srcFormat.mBytesPerFrame = info.srcFormat.mChannelsPerFrame * 2
        info.srcFormat.mBytesPerPacket = info.srcFormat.mFramesPerPacket * info.srcFormat.mBytesPerFrame
        // why??
        info.srcFormat.mBitsPerChannel = bitsPerSample
        info.srcFormat.mReserved = 0
        info.srcFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger |
            kAudioFormatFlagsNativeEndian |
            kLinearPCMFormatFlagIsPacked

        info.dstFormat = info.srcFormat
        info.waveSubchunk1Size = subchunk1Size
        info.dataOffset = UInt(totalSize)
        info.audioDataByteCount = UInt(subchunk2Size)
        info.audioDataPacketCount = info.audioDataByteCount / UInt(blockAlign)
        info.sampleRate = Float64(sampleRate)
        info.packetBufferSize = 2048
        info.packetDuration = Double(info.srcFormat.mFramesPerPacket) / info.sampleRate
        // https://sound.stackexchange.com/questions/37424/how-do-you-compute-the-bitrate-of-a-wav-file
        // http://www.theaudioarchive.com/TAA_Resources_File_Size.htm
        // Bits Per Second (bps) = Sample Rate (Hz) * Word Length (bits) * Channel Count
//        let bitrate = UInt32(info.sampleRate) * info.srcFormat.mBitsPerChannel * info.srcFormat.mChannelsPerFrame / 1000
        info.bitrate = byteRate * 8 / 1000
        info.infoUpdated()

        let left = data.1 - totalSize
        let d = UnsafeRawPointer(raw.advanced(by: Int(totalSize)))
        let ret = (d, left)
        outputStream.call(.output(ret))
        outputStream.call(.bitrate(info.bitrate))
    }
}

// MARK: - AudioBufferConverter

extension DefaultAudioDecoder {
    private final class AudioBufferConverter {
        private weak var _ring: DefaultAudioDecoder?
        private var _buffer: [UInt8] = []

        init(ring: DefaultAudioDecoder) { _ring = ring }

        private func audioConverterCallback(packetsCount: UnsafeMutablePointer<UInt32>, ioData: UnsafeMutablePointer<AudioBufferList>, outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
            
            
//            guard let packet = _ring?.readPacket() else {
//                packetsCount.pointee = 0
//                outDataPacketDescription?.pointee = nil
//                return OSStatus.empty
//            }
//            var desc = packet.desc
//            var p: [UInt8] = packet.data.compactMap({$0})
//            ioData.pointee.mNumberBuffers = 1
//            ioData.pointee.mBuffers.mData =
//                UnsafeMutableRawPointer(&p)
//            ioData.pointee.mBuffers.mDataByteSize = packet.desc.mDataByteSize
//
//
//            outDataPacketDescription?.pointee = UnsafeMutablePointer(&desc)
//            packetsCount.pointee = 1
//            return noErr
//
//
            
            guard var desc = _ring?.readPacket(into: &_buffer) else {
                packetsCount.pointee = 0
                outDataPacketDescription?.pointee = nil
                return OSStatus.empty
            }
            let buf = AudioBuffer(mNumberChannels: 2, mDataByteSize: desc.mDataByteSize, mData: &_buffer)
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers = buf
            outDataPacketDescription?.pointee = UnsafeMutablePointer(&desc)
            packetsCount.pointee = 1
            return noErr
        }

        static func callback() -> AudioConverterComplexInputDataProc {
            let closure: AudioConverterComplexInputDataProc = { (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                guard let info = inUserData else { return noErr }
                let convertInfo = info.to(object: AudioBufferConverter.self)
                return convertInfo.audioConverterCallback(packetsCount: ioNumberDataPackets, ioData: ioData, outDataPacketDescription: outDataPacketDescription)
            }
            return closure
        }
    }
}

extension UInt32 {
    func asUInt8Array() -> [UInt8] {
        var bigEndian = self.bigEndian
        let count = MemoryLayout<UInt32>.size
        let bytePtr = withUnsafePointer(to: &bigEndian) {
            $0.withMemoryRebound(to: UInt8.self, capacity: count) {
                UnsafeBufferPointer(start: $0, count: count)
            }
        }
        return Array(bytePtr)
    }
}
