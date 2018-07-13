//
//  Typealias.swift
//  APlayer
//
//  Created by lincoln on 2018/4/3.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// AVFoundation.AudioFileTypeID
public typealias AudioFileTypeID = AVFoundation.AudioFileTypeID

/// AVFoundation.AVAudioSession
public typealias AVAudioSession = AVFoundation.AVAudioSession

/// AVFoundation.AVAudioEngine
public typealias AVAudioEngine = AVFoundation.AVAudioEngine

/// CoreAudio.AudioStreamPacketDescription
public typealias AudioStreamPacketDescription = CoreAudio.AudioStreamPacketDescription

/// CoreAudio.AudioStreamBasicDescription
public typealias AudioStreamBasicDescription = CoreAudio.AudioStreamBasicDescription

/// AudioToolbox.AudioFileStreamParseFlags
public typealias AudioFileStreamParseFlags = AudioToolbox.AudioFileStreamParseFlags

/// AudioToolbox.AudioBuffer
public typealias AudioBuffer = AudioToolbox.AudioBuffer

/// AudioToolbox.AudioConverterRef
public typealias AudioConverterRef = AudioToolbox.AudioConverterRef

/// AudioToolbox.AudioBufferList
public typealias AudioBufferList = AudioToolbox.AudioBufferList

/// AudioToolbox.AudioConverterComplexInputDataProc
public typealias AudioConverterComplexInputDataProc = AudioToolbox.AudioConverterComplexInputDataProc

/// CoreAudio.kAudioFormatFLAC
public let kAudioFormatFLAC = CoreAudio.kAudioFormatFLAC

/// CoreAudio.kAudioFormatLinearPCM
public let kAudioFormatLinearPCM = CoreAudio.kAudioFormatLinearPCM

/// CoreAudio.kAudioFormatFlagIsSignedInteger
public let kAudioFormatFlagIsSignedInteger = CoreAudio.kAudioFormatFlagIsSignedInteger

/// CoreAudio.kAudioFormatFlagsNativeEndian
public let kAudioFormatFlagsNativeEndian = CoreAudio.kAudioFormatFlagsNativeEndian

/// CoreAudio.kAudioFormatFlagIsPacked
public let kAudioFormatFlagIsPacked = CoreAudio.kAudioFormatFlagIsPacked

/// AudioDecoder.AudioFileType
public typealias AudioFileType = AudioDecoder.AudioFileType

/// (ConfigurationCompatible) -> StreamProviderCompatible
public typealias StreamerBuilder = (ConfigurationCompatible) -> StreamProviderCompatible

/// (ConfigurationCompatible) -> AudioDecoderCompatible
public typealias AudioDecoderBuilder = (ConfigurationCompatible) -> AudioDecoderCompatible

/// (Logger.Policy) -> LoggerCompatible
public typealias LoggerBuilder = (Logger.Policy) -> LoggerCompatible

/// (AudioFileType, ConfigurationCompatible) -> MetadataParserCompatible?
public typealias MetadataParserBuilder = (AudioFileType, ConfigurationCompatible) -> MetadataParserCompatible?

/// (APlay.Configuration.ProxyPolicy) -> URLSessionDelegate
public typealias SessionDelegateBuilder = (APlay.Configuration.ProxyPolicy) -> URLSessionDelegate

/// (APlay.Configuration.ProxyPolicy) -> URLSession
public typealias SessionBuilder = (APlay.Configuration.ProxyPolicy) -> URLSession
