//
//  AudioDecoderCompatible.swift
//  APlayer
//
//  Created by lincoln on 2018/4/16.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation

// MARK: - AudioDecoderCompatible

/// Protocol for Audio Decoder
public protocol AudioDecoderCompatible: AnyObject {
    func prepare(for provider: StreamProviderCompatible, at: StreamProvider.Position) throws
    func pause()
    func resume()
    func destroy()
    func seekable() -> Bool

    var info: AudioDecoder.Info { get }
    var outputStream: Delegated<AudioDecoder.Event, Void> { get }
    var inputStream: Delegated<AudioDecoder.AudioInput, Void> { get }

    init(config: ConfigurationCompatible)
}

// MARK: - AudioDecoder

public struct AudioDecoder {
    /// AudioDecoder Event
    ///
    /// - error: error
    /// - output: output data
    /// - bitrate: bitrate available
    /// - seekable: seekable value available
    /// - empty: empty data encounted
    public enum Event {
        case error(APlay.Error)
        case output(AudioOutput)
        case bitrate(UInt32)
        case seekable(Bool)
        case empty
    }

    // MARK: - AudioInput

    /// (UnsafePointer<UInt8>, UInt32, Bool)
    public typealias AudioInput = (UnsafePointer<UInt8>, UInt32, Bool)

    // MARK: - AudioOutput

    /// (UnsafePointer<UInt8>, UInt32, Bool)
    public typealias AudioOutput = (UnsafeRawPointer, UInt32)

    // MARK: - Decoder Info

    /// Decoder Info
    public final class Info {
        private static let maxBitrateSample = 50
        public lazy var srcFormat = AudioStreamBasicDescription()
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
            srcFormat = AudioStreamBasicDescription()
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

    // MARK: - AudioFileType

    /// A wrap for AudioFileTypeID
    public struct AudioFileType: RawRepresentable, Hashable {
        public typealias RawValue = String
        public var rawValue: String

        public init(rawValue: RawValue) { self.rawValue = rawValue }

        public init(_ value: RawValue) { rawValue = value }

        public init?(value: AudioFileTypeID) {
            guard let result = String(from: value) else { return nil }
            self.init(rawValue: result)
        }
        // https://developer.apple.com/documentation/audiotoolbox/1576497-anonymous?language=objc
        public static let aiff = AudioFileType("AIFF")
        public static let aifc = AudioFileType("AIFC")
        public static let wave = AudioFileType("WAVE")
        public static let rf64 = AudioFileType("RF64")
        public static let soundDesigner2 = AudioFileType("Sd2f")
        public static let next = AudioFileType("NeXT")
        public static let mp3 = AudioFileType("MPG3")
        public static let mp2 = AudioFileType("MPG2")
        public static let mp1 = AudioFileType("MPG1")
        public static let ac3 = AudioFileType("ac-3")
        public static let aacADTS = AudioFileType("adts")
        public static let mp4 = AudioFileType("mp4f")
        public static let m4a = AudioFileType("m4af")
        public static let m4b = AudioFileType("m4bf")
        public static let caf = AudioFileType("caff")
        public static let k3gp = AudioFileType("3gpp")
        public static let k3gp2 = AudioFileType("3gp2")
        public static let amr = AudioFileType("amrf")
        public static let flac = AudioFileType("flac")
        public static let opus = AudioFileType("opus")

        private static var map: [AudioFileType: AudioFileTypeID] = [:]

        public var audioFileTypeID: AudioFileTypeID {
            let value: AudioFileTypeID
            if let result = AudioFileType.map[self] {
                value = result
            } else {
                value = rawValue.audioFileTypeID()
                AudioFileType.map[self] = value
            }
            return value
        }
    }
}

extension String {
    init?(from value: UInt32) {
        var bigEndian = value.bigEndian
        let count = MemoryLayout<UInt32>.size
        let bytePtr = withUnsafePointer(to: &bigEndian) {
            $0.withMemoryRebound(to: UInt8.self, capacity: count) {
                UnsafeBufferPointer(start: $0, count: count)
            }
        }
        self.init(data: Data(buffer: bytePtr), encoding: .utf8)
    }

    fileprivate func audioFileTypeID() -> AudioFileTypeID {
        let offsetSize = 8
        let array: [UInt8] = Array(utf8)
        let total = array.count
        var totalSize: UInt32 = 0
        for i in 0 ..< total {
            totalSize += UInt32(array[i]) << (offsetSize * ((total - 1) - i))
        }
        return totalSize
    }
}
