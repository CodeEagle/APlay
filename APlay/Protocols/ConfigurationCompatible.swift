//
//  ConfigurationCompatible.swift
//  APlay
//
//  Created by lincoln on 2018/6/13.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation
import UIKit
// Using __`unowned let`__ to avoid retain cycle
/// Protocol for APlay Configuration
public protocol ConfigurationCompatible: AnyObject {
    var defaultCoverImage: UIImage? { get set }
    var session: URLSession { get }
    var streamerBuilder: (ConfigurationCompatible) -> StreamProviderCompatible { get }
    var audioDecoderBuilder: (ConfigurationCompatible) -> AudioDecoderCompatible { get }
    var metadataParserBuilder: (AudioFileType, ConfigurationCompatible) -> MetadataParserCompatible? { get }
    var httpFileCompletionValidator: APlay.Configuration.HttpFileValidationPolicy { get }
    var preBufferWaveFormatPercentageBeforePlay: Float { get }
    var decodeBufferSize: UInt { get }
    var startupWatchdogPeriod: UInt { get }
    var maxDiskCacheSize: UInt32 { get }
    var maxDecodedByteCount: UInt32 { get }
    var maxRemoteStreamOpenRetry: UInt { get }
    var userAgent: String { get }
    var cacheDirectory: String { get }
    var cacheNaming: APlay.Configuration.CacheFileNamingPolicy { get }
    var cachePolicy: APlay.Configuration.CachePolicy { get }
    var proxyPolicy: APlay.Configuration.ProxyPolicy { get }
    var networkPolicy: APlay.Configuration.NetworkPolicy { get }
    var predefinedHttpHeaderValues: [String: String] { get }
    var isEnabledAutomaticAudioSessionHandling: Bool { get }
    var isEnabledVolumeMixer: Bool { get }
    var equalizerBandFrequencies: [Float] { get }
    var logger: LoggerCompatible { get }

    func startBackgroundTask(isToDownloadImage: Bool)
    func endBackgroundTask(isToDownloadImage: Bool)
}
