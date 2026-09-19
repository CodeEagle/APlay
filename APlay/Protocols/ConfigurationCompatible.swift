//
//  ConfigurationCompatible.swift
//  APlay
//
//  Created by lincoln on 2018/6/13.
//  Copyright © 2018年 SelfStudio. All rights reserved.
//

import Foundation
#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif
// Using __`unowned let`__ to avoid retain cycle
/// Protocol for APlay Configuration
public protocol ConfigurationCompatible: AnyObject {
    var defaultCoverImage: APlayImage? { get set }
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
    /// Whether the lock screen / Control Center / AirPlay 2 remote commands are
    /// wired to the player. On by default.
    var isEnabledRemoteCommandHandling: Bool { get }
    var equalizerBandFrequencies: [Float] { get }
    var logger: LoggerCompatible { get }
    var isAutoFillID3InfoToNowPlayingCenter: Bool { get }
    var isAutoHandlingInterruptEvent: Bool { get }

    /// Whether the following track is preloaded and handed over without stopping
    /// the output audio unit (gapless playback). Off by default.
    ///
    /// When enabled, the playlist's next track is buffered as soon as the current
    /// track's stream has been fully received; at the end of the current track the
    /// player switches its read source to the buffered one and keeps rendering, so
    /// there is no pause, no reopen and no rebuild delay. Two tracks sharing a
    /// sample format are truly seamless; a change of sample format still has to
    /// re-initialise the audio unit, so the handoff is quick but not seamless
    /// there. A preloaded track is dropped if the user skips, seeks away, plays
    /// another URL, or if the playlist no longer points at it.
    var isGaplessPlaybackEnabled: Bool { get }

    func startBackgroundTask(isToDownloadImage: Bool)
    func endBackgroundTask(isToDownloadImage: Bool)
}
