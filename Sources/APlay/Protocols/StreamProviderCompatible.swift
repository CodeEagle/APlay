public protocol DataReader: AnyObject {
    func read(count: Int) -> ReadWritePipe.ReadResult
}

/// Protocol for stream provider
public protocol StreamProviderCompatible: AnyObject {
    var outputPipeline: AnyPublisher<StreamProvider.Event, Never> { get }

    func startStream(with handler: (UInt) -> Data)
    func destroy()
    func pause()
    func resume()
    init(config: ConfigurationCompatible)
}

public struct StreamProvider {
    public enum Event {
        case readyForRead
        case hasBytesAvailable(UnsafePointer<UInt8>, UInt32, Bool)
        case endEncountered
        case errorOccurred(Error)
        case metadata([MetadataParser.Item])
        case metadataSize(UInt32)
        case flac(FlacMetadata)
        case unknown(Error)
    }

    public typealias Position = UInt64

    public struct URLInfo: Equatable {
        public let startPosition: Position
        public let originalURL: URL
        public let cachedURL: URL
        public let fileHint: AudioFileType
        public let resourceLocation: ResourceLocation
        public var remoteContentLength: UInt64 = 0

        public enum ResourceLocation { case remote, local, unknown }

        public static let `default` = URLInfo()
        public var hasLocalCached: Bool { return cachedURL.isLocalCachedURL }
        public var isRemote: Bool { resourceLocation == .remote }
        public var isLocal: Bool { resourceLocation == .local }
        public var isWave: Bool { fileHint == .wave }
        public var isRemoteWave: Bool { resourceLocation == .remote && fileHint == .wave }
        public var isLocalWave: Bool { resourceLocation == .local && fileHint == .wave }

        public var fileName: String {
            var coms = originalURL.lastPathComponent.split(separator: ".")
            coms.removeLast()
            return coms.joined(separator: ".")
        }

        private init() {
            startPosition = 0
            originalURL = .URLInfoNone
            cachedURL = .URLInfoNone
            fileHint = .mp3
            resourceLocation = .unknown
        }

        public init(url: URL, cachedURL cURL: URL = .URLInfoNone, position: Position = 0) {
            startPosition = position
            originalURL = url
            cachedURL = cURL
            guard let scheme = url.scheme?.lowercased() else {
                resourceLocation = .unknown
                fileHint = .mp3
                return
            }
            // https://www.audiocheck.net/download.php?filename=Audio/audiocheck.net_hdsweep_1Hz_44000Hz_-3dBFS_30s.wav
            var pathExtensionHint = AudioFileType.mp3
            if let ext = url.absoluteString.split(separator: ".").last {
                pathExtensionHint = URLInfo.fileHint(from: String(ext))
            }
            if scheme == "file" {
                let localFileHint = URLInfo.localFileHit(from: url)
                if localFileHint != .mp3 {
                    fileHint = localFileHint
                } else if pathExtensionHint != .mp3 {
                    fileHint = pathExtensionHint
                } else {
                    fileHint = .mp3
                }
                resourceLocation = .local
            } else {
                resourceLocation = .remote
                fileHint = pathExtensionHint
            }
        }

        static func isWave(for url: URL) -> Bool {
            return fileHint(from: url.pathExtension) == .wave
        }

        func localData() -> Data? {
            guard cachedURL.canReuseLocalData else { return nil }
            return try? Data(contentsOf: cachedURL)
        }

        func localContentLength() -> UInt {
            guard resourceLocation == .local else { return 0 }
            let name = originalURL.asCFunctionString()
            var buff = stat()
            if stat(name, &buff) != 0 { return 0 }
            let size = buff.st_size
            return UInt(size)
        }

        func tagParser(with config: ConfigurationCompatible) -> MetadataParserCompatible? {
            var parser = config.metadataParserBuilder(fileHint, config)
            if parser == nil {
                if fileHint == .mp3 {
                    parser = ID3Parser(config: config)
                } else if fileHint == .flac {
                    parser = FlacParser(config: config)
                } else {
                    return nil
                }
            }
            return parser
        }

        private static func localFileHit(from url: URL) -> AudioFileType {
            let name = url.asCFunctionString()
            let tagSize = 4
            guard let fd = fopen(name, "r") else { return .mp3 }
            defer { fclose(fd) }
            var buffer = UnsafeMutablePointer.uint8Pointer(of: tagSize)
            defer { free(buffer) }
            fseek(fd, 8, SEEK_SET)
            fread(buffer, 1, tagSize, fd)
            var d = Data(bytes: buffer, count: tagSize)
            var value = String(data: d, encoding: .utf8)
            if value?.lowercased() == "wave" { return .wave }
            fseek(fd, 0, SEEK_SET)
            fread(buffer, 1, tagSize, fd)
            d = Data(bytes: buffer, count: tagSize)
            value = String(data: d, encoding: .utf8)
            if value?.lowercased() == "flac" { return .flac }
            return .mp3
        }

        /// Get fileHint from fileformat, file extension or content type,
        ///
        /// - Parameter value: fileformat, file extension or content type
        /// - Returns: AudioFileTypeID, default value is `kAudioFileMP3Type`
        static func fileHint(from value: String) -> AudioFileType {
            switch value.lowercased() {
            case "flac": return .flac
            case "mp3", "mpg3", "audio/mpeg", "audio/mp3": return .mp3
            case "wav", "wave", "audio/x-wav": return .wave
            case "aifc", "audio/x-aifc": return .aifc
            case "aiff", "audio/x-aiff": return .aiff
            case "m4a", "audio/x-m4a": return .m4a
            case "mp4", "mp4f", "mpg4", "audio/mp4", "video/mp4": return .mp4
            case "caf", "caff", "audio/x-caf": return .caf
            case "aac", "adts", "aacp", "audio/aac", "audio/aacp": return .aacADTS
            case "opus", "audio/opus": return .opus
            default: return .mp3
            }
        }
    }
}

extension URL {
    public static var URLInfoNone: URL = URL(string: "https://URLInfo.none")!
    var isTmp: Bool { return pathExtension == "tmp" }
    var isInComplete: Bool { return pathExtension == "incomplete" }
    var isLocalCachedURL: Bool {
        return self != .URLInfoNone && isTmp == false && isInComplete == false
    }

    var canReuseLocalData: Bool {
        return self != .URLInfoNone && isInComplete == false
    }
}
