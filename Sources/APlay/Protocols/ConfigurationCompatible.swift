
public protocol ConfigurationCompatible: AnyObject {
    var defaultCoverImage: APlayImage? { get set }
    var session: URLSession { get }
//    var streamerBuilder: (ConfigurationCompatible) -> StreamProviderCompatible { get }
//    var audioDecoderBuilder: (ConfigurationCompatible) -> AudioDecoderCompatible { get }
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
    var retryPolicy: APlay.Configuration.RetryPolicy { get }
    var remoteDataVerifyPolicy: APlay.Configuration.RemoteDataVerifyPolicy { get }
    var predefinedHttpHeaderValues: [String: String] { get }
    var isEnabledAutomaticAudioSessionHandling: Bool { get }
    var isEnabledVolumeMixer: Bool { get }
    var equalizerBandFrequencies: [Float] { get }
    var logger: LoggerCompatible { get }
    var isAutoFillID3InfoToNowPlayingCenter: Bool { get }
    var isAutoHandlingInterruptEvent: Bool { get }
    
    func startBackgroundTask(isToDownloadImage: Bool)
    func endBackgroundTask(isToDownloadImage: Bool)
}
