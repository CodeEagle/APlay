//
//  StreamConfiguration.swift
//  FreePlayer
//
//  Created by Lincoln Law on 2017/2/19.
//  Copyright © 2017年 Lincoln Law. All rights reserved.
//

import AudioToolbox
import AVFoundation
#if os(iOS)
    import UIKit
#endif

extension APlay {
    /// Configuration for APlay
    public final class Configuration: ConfigurationCompatible, @unchecked Sendable {
        /// 播放器歌曲默认图像
        public var defaultCoverImage: APlayImage?
        /** 缓存目录 */
        public let cacheDirectory: String
        /// 网络 session
        public let session: URLSession
        public let logPolicy: Logger.Policy
        /// 校验下载文件完整性
        public let httpFileCompletionValidator: HttpFileValidationPolicy
        /** 远程 Wave 文件的预缓冲大小(先缓冲到10%再播放) */
        public let preBufferWaveFormatPercentageBeforePlay: Float
        /** 每个解码的大小 */
        public let decodeBufferSize: UInt
        /** 监控播放器，超时没播放则🚔 */
        public let startupWatchdogPeriod: UInt
        /** 磁盘最大缓存数(bytes) */
        public let maxDiskCacheSize: UInt32
        /** 最大解码数(bytes) */
        public let maxDecodedByteCount: UInt32
        /** 自定义 UA */
        public let userAgent: String
        /** 缓存命名策略 */
        public let cacheNaming: CacheFileNamingPolicy
        /** 缓存策略 */
        public let cachePolicy: CachePolicy
        /** 代理策略 */
        public let proxyPolicy: ProxyPolicy
        /** 网络策略 */
        public let networkPolicy: NetworkPolicy
        /** 自定义 http header 字典 */
        public let predefinedHttpHeaderValues: [String: String]
        /** 自动控制 AudioSession */
        public let isEnabledAutomaticAudioSessionHandling: Bool
        /** 远程连接最大重试次数 默认5次*/
        public let maxRemoteStreamOpenRetry: UInt
        /** 自动填充ID3的信息到 NowPlayingCenter */
        public let isAutoFillID3InfoToNowPlayingCenter: Bool
        /** 自动处理中断事件 */
        public let isAutoHandlingInterruptEvent: Bool
        /// 预加载下一曲并在曲终时无缝切换（默认关）。见
        /// `APlay.Configuration.isGaplessPlaybackEnabled`。
        public let isGaplessPlaybackEnabled: Bool
        /// If YES then volume control will be enabled on iOS
        public let isEnabledVolumeMixer: Bool
        /// A pointer to a 0 terminated array of band frequencies (iOS 5.0 and later, OSX 10.9 and later)
        public let equalizerBandFrequencies: [Float]
        /// logger
        public let logger: LoggerCompatible

        /// streamer factory
        public private(set) var streamerBuilder: StreamerBuilder = { Streamer(config: $0) }

        /// audio decoder factory
        public private(set) var audioDecoderBuilder: AudioDecoderBuilder = { DefaultAudioDecoder(config: $0) }

        /// metadata parser factory
        public private(set) var metadataParserBuilder: MetadataParserBuilder = {
            type, config in
            if type == .flac { return FlacParser(config: config) }
            else if type == .mp3 { return ID3Parser(config: config) }
            else { return nil }
        }

        #if os(iOS)
            private lazy var _backgroundTask = UIBackgroundTaskIdentifier.invalid
        #endif

        #if DEBUG
            deinit {
                debug_log("\(self) \(#function)")
            }
        #endif

        public init(defaultCoverImage: APlayImage? = nil,
                    proxyPolicy: ProxyPolicy = .system,
                    logPolicy: Logger.Policy = Logger.Policy.defaultPolicy,
                    httpFileCompletionValidator: HttpFileValidationPolicy = .notValidate,
                    preBufferWaveFormatPercentageBeforePlay: Float = 0.1,
                    decodeBufferSize: UInt = 8192,
                    startupWatchdogPeriod: UInt = 30,
                    maxDiskCacheSize: UInt32 = 256_435_456,
                    maxDecodedByteCount: UInt32 = Configuration.defaultMaxDecodedByteCount,
                    userAgent: String = Configuration.defaultUA,
                    cacheNaming: CacheFileNamingPolicy = CacheFileNamingPolicy.defaultPolicy,
                    cachePolicy: CachePolicy = .enable([]),
                    cacheDirectory: String = Configuration.defaultCachedDirectory,
                    networkPolicy: NetworkPolicy = .noRestrict,
                    predefinedHttpHeaderValues: [String: String] = [:],
                    automaticAudioSessionHandlingEnabled: Bool = true,
                    maxRemoteStreamOpenRetry: UInt = 5,
                    equalizerBandFrequencies: [Float] = [50, 100, 200, 400, 800, 1600, 2600, 16000],
                    autoFillID3InfoToNowPlayingCenter: Bool = true,
                    autoHandlingInterruptEvent: Bool = true,
                    gaplessPlaybackEnabled: Bool = false,
                    enableVolumeMixer: Bool = true,
                    sessionBuilder: SessionBuilder? = nil,
                    sessionDelegateBuilder: SessionDelegateBuilder? = nil,
                    loggerBuilder: LoggerBuilder? = nil,
                    streamerBuilder: StreamerBuilder? = nil,
                    audioDecoderBuilder: AudioDecoderBuilder? = nil,
                    metadataParserBuilder: MetadataParserBuilder? = nil) {
            self.defaultCoverImage = defaultCoverImage
            self.proxyPolicy = proxyPolicy
            self.logPolicy = logPolicy
            self.httpFileCompletionValidator = httpFileCompletionValidator
            self.preBufferWaveFormatPercentageBeforePlay = preBufferWaveFormatPercentageBeforePlay
            self.decodeBufferSize = decodeBufferSize
            self.startupWatchdogPeriod = startupWatchdogPeriod
            self.maxDiskCacheSize = maxDiskCacheSize
            self.maxDecodedByteCount = maxDecodedByteCount
            self.userAgent = userAgent
            self.cacheNaming = cacheNaming
            self.cachePolicy = cachePolicy
            self.cacheDirectory = cacheDirectory
            self.networkPolicy = networkPolicy
            self.predefinedHttpHeaderValues = predefinedHttpHeaderValues
            isEnabledAutomaticAudioSessionHandling = automaticAudioSessionHandlingEnabled
            self.maxRemoteStreamOpenRetry = maxRemoteStreamOpenRetry
            self.equalizerBandFrequencies = equalizerBandFrequencies
            isEnabledVolumeMixer = enableVolumeMixer
            isAutoFillID3InfoToNowPlayingCenter = autoFillID3InfoToNowPlayingCenter
            isAutoHandlingInterruptEvent = autoHandlingInterruptEvent
            isGaplessPlaybackEnabled = gaplessPlaybackEnabled

            logger = loggerBuilder?(logPolicy) ?? APlay.InternalLogger(policy: logPolicy)

            if let builder = streamerBuilder { self.streamerBuilder = builder }
            if let builder = audioDecoderBuilder { self.audioDecoderBuilder = builder }
            if let builder = metadataParserBuilder { self.metadataParserBuilder = builder }

            // config session
            if let builder = sessionBuilder {
                session = builder(proxyPolicy)
            } else if case let Configuration.ProxyPolicy.custom(info) = proxyPolicy {
                let configure = URLSessionConfiguration.default
                let enableKey = kCFNetworkProxiesHTTPEnable as String
                let hostKey = kCFNetworkProxiesHTTPProxy as String
                let portKey = kCFNetworkProxiesHTTPPort as String
                configure.connectionProxyDictionary = [
                    enableKey: 1,
                    hostKey: info.host,
                    portKey: info.port,
                ]
                let delegate = sessionDelegateBuilder?(proxyPolicy) ?? SessionDelegate(policy: proxyPolicy)
                session = URLSession(configuration: configure, delegate: delegate, delegateQueue: .main)
            } else {
                session = URLSession(configuration: URLSessionConfiguration.default)
            }
        }

        /// Start background task
        ///
        /// - Parameter isToDownloadImage: Bool
        ///
        /// - Note: Touches main-actor-isolated APIs (`AVAudioSession`, `UIApplication`); the work
        ///   runs on the main thread, also when a caller (e.g. the gapless preloader) reaches
        ///   it from a background queue.
        public func startBackgroundTask(isToDownloadImage: Bool = false) {
            #if os(iOS)
                guard Thread.isMainThread else {
                    DispatchQueue.main.async { [weak self] in
                        self?.startBackgroundTask(isToDownloadImage: isToDownloadImage)
                    }
                    return
                }
                MainActor.assumeIsolated {
                    if isToDownloadImage {
                        guard _backgroundTask != UIBackgroundTaskIdentifier.invalid else { return }
                    }
                    if isEnabledAutomaticAudioSessionHandling {
                        do {
                            let instance = AVAudioSession.sharedInstance()
                            try instance.setCategory(.playback, mode: .default, policy: AVAudioSession.RouteSharingPolicy.longFormAudio)
                            try instance.setActive(true)
                        } catch {
                            debug_log("error: \(error)")
                        }
                    }
                    endBackgroundTask(isToDownloadImage: isToDownloadImage)
                    _backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: { [weak self] in
                        self?.endBackgroundTask(isToDownloadImage: isToDownloadImage)
                    })
                }
            #elseif os(macOS)
                // No background-task / audio-session concept needed on macOS; playback is foreground.
                _ = isToDownloadImage
            #endif
        }

        /// Stop background task
        ///
        /// - Parameter isToDownloadImage: Bool
        public func endBackgroundTask(isToDownloadImage: Bool) {
            #if os(iOS)
                guard Thread.isMainThread else {
                    DispatchQueue.main.async { [weak self] in
                        self?.endBackgroundTask(isToDownloadImage: isToDownloadImage)
                    }
                    return
                }
                MainActor.assumeIsolated {
                    if isToDownloadImage { return }
                    guard _backgroundTask != UIBackgroundTaskIdentifier.invalid else { return }
                    UIApplication.shared.endBackgroundTask(_backgroundTask)
                    _backgroundTask = UIBackgroundTaskIdentifier.invalid
                }
            #endif
        }
    }
}

// MARK: - Models

extension APlay.Configuration {
    /// Default cache directory for player
    public static var defaultCachedDirectory: String {
        let base = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
        let target = "\(base)/APlay/Tmp"
        let fs = FileManager.default
        guard fs.fileExists(atPath: target) == false else { return target }
        try? fs.createDirectory(atPath: target, withIntermediateDirectories: true, attributes: nil)
        return target
    }

    /// Default User-Agent for network streaming
    public static var defaultUA: String {
        var osStr = ""
        #if os(iOS)
            osStr = "iOS \(MainActor.assumeIsolated { UIDevice.current.systemVersion })"
        #elseif os(OSX)
            // No need to be so concervative with the cache sizes
            osStr = "macOS"
        #endif
        return "APlay/\(APlay.version) \(osStr)"
    }

    /// Default size for decoeded data
    public static var defaultMaxDecodedByteCount: UInt32 {
        let is64Bit = MemoryLayout<Int>.size == MemoryLayout<Int64>.size
        return (is64Bit ? 4 : 2) * 1_048_576
    }

    /// Validate policy for remote file
    ///
    /// - notValidate: not validate
    /// - validateHeader->Bool: validate with header info, validator
    public enum HttpFileValidationPolicy {
        case notValidate
        case validateHeader(keys: [String], validator: ((URL, String, [String: Any]) -> Bool))

        var keys: [String] {
            switch self {
            case .notValidate: return []
            case let .validateHeader(keys: keys, _): return keys
            }
        }
    }

    /// Naming policy for cached file
    ///
    /// - `default`: will use `url.path.replacingOccurrences(of: "/", with: "_")` for naming url
    /// - custom->String: custom policy
    public enum CacheFileNamingPolicy {
        /// default is url.path.hashValue
        case `default`
        case custom((URL) -> String)

        func name(for url: URL) -> String {
            switch self {
            case .default: return url.path.replacingOccurrences(of: "/", with: "_")
            case let .custom(block): return block(url)
            }
        }

        /// A default implementation for custom((URL) -> String)
        public static var defaultPolicy: CacheFileNamingPolicy {
            return .custom({ (url) -> String in
                let raw = url.path
                guard let dat = raw.data(using: .utf8) else { return raw }
                let sub = dat.base64EncodedString()
                return sub
            })
        }
    }

    /// Cache Plolicy
    ///
    /// - enable: enable with extra folders
    /// - disable: disable cache on disk
    public enum CachePolicy {
        case enable([String])
        case disable

        var isEnabled: Bool {
            switch self {
            case .disable: return false
            default: return true
            }
        }

        var cachedFolder: [String]? {
            switch self {
            case let .enable(values): return values
            default: return nil
            }
        }
    }

    /// Network policy for accessing remote resources
    public enum NetworkPolicy {
        public typealias PermissionHandler = (URL, (@escaping (Bool) -> Void)) -> Void
        case noRestrict
        case requiredPermission(PermissionHandler)
        func requestPermission(for url: URL, handler: @escaping (Bool) -> Void) {
            switch self {
            case .noRestrict: handler(true)
            case let .requiredPermission(closure): closure(url, handler)
            }
        }
    }

    /// Proxy Policy
    ///
    /// - system: using system proxy
    /// - custom: using custom proxy with config
    public enum ProxyPolicy: Sendable {
        case system
        case custom(Info)

        /// Custom proxy info
        public struct Info: Sendable {
            /** 使用自定义代理 用户名 */
            public let username: String
            /** 使用自定义代理 密码 */
            public let password: String
            /** 使用自定义代理 Host */
            public let host: String
            /** 使用自定义代理 Port */
            public let port: UInt
            /** 使用自定义代理 authenticationScheme, kCFHTTPAuthenticationSchemeBasic... */
            public let scheme: AuthenticationScheme
            /** 代理 Https */
            public let isProxyingHttps: Bool

            public init(username: String, password: String, host: String, port: UInt, scheme: AuthenticationScheme, proxyingHttps: Bool = false) {
                self.username = username
                self.password = password
                self.host = host
                self.port = port
                self.scheme = scheme
                isProxyingHttps = proxyingHttps
            }

            /// Authentication scheme
            public enum AuthenticationScheme: Sendable {
                case digest, basic
                var name: CFString {
                    switch self {
                    case .digest: return kCFHTTPAuthenticationSchemeDigest
                    case .basic: return kCFHTTPAuthenticationSchemeBasic
                    }
                }
            }
        }
    }
}

// MARK: - SessionDelegate

extension APlay.Configuration {
    private final class SessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
        private let _proxyPolicy: APlay.Configuration.ProxyPolicy

        init(policy: APlay.Configuration.ProxyPolicy) {
            _proxyPolicy = policy
        }

        public func urlSession(_: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            var credential: URLCredential?
            if case let APlay.Configuration.ProxyPolicy.custom(info) = _proxyPolicy {
                credential = URLCredential(user: info.username, password: info.password, persistence: .forSession)
            }
            completionHandler(.useCredential, credential)
        }
    }
}
