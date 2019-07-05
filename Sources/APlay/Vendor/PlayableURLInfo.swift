public enum PlayableURLInfo {
    case remote(URL, AudioFileType)
    case local(URL, AudioFileType)
    case unknown(URL)
    
    public static let none = PlayableURLInfo.unknown(URL(string: "APlay.PlayableURLInfo.unknown")!)
    
    public var isRemote: Bool { if case .remote = self { return true }; return false }
    
    public var url: URL {
        switch self {
        case let .remote(url, _): return url
        case let .local(url, _): return url
        case let .unknown(url): return url
        }
    }
    
    public init(url: URL) {
        guard let scheme = url.scheme?.lowercased() else {
            self = .unknown(url)
            return
        }
        if scheme == "file" {
            let localFileHint = PlayableURLInfo.localFileHit(from: url)
            let pathExtensionHint = PlayableURLInfo.fileHintFromFileTypeOrContentType(url.pathExtension)
            if localFileHint != .mp3 {
                self = .local(url, localFileHint)
            } else if pathExtensionHint != .mp3 {
                self = .local(url, pathExtensionHint)
            } else {
                self = .local(url, .mp3)
            }
        } else {
            self = .remote(url, PlayableURLInfo.fileHintFromFileTypeOrContentType(url.pathExtension))
        }
    }
}
// MARK: - FileHint Stuff
public extension PlayableURLInfo {
    /**
     read format for local file
     
     WaveFormat: http://soundfile.sapp.org/doc/WaveFormat/
     
     FlacFormat: https://xiph.org/flac/format.html
     - Parameter url: local file url
     - Returns: AudioFileTypeID, default value is `.mp3`
     */
    static func localFileHit(from url: URL) -> AudioFileType {
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
    /// - Returns: AudioFileTypeID, default value is `.mp3`
    static func fileHintFromFileTypeOrContentType(_ value: String) -> AudioFileType {
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
// MARK: - Info From Url
public extension PlayableURLInfo {
    func localContentLength() -> UInt {
        guard case let PlayableURLInfo.local(url, _) = self else { return 0 }
        let name = url.asCFunctionString()
        var buff = stat()
        if stat(name, &buff) != 0 { return 0 }
        let size = buff.st_size
        return UInt(size)
    }
    
    var fileHint: AudioFileType {
        switch self {
        case let .remote(_, hint): return hint
        case let .local(_, hint): return hint
        default: return .mp3
        }
    }
    
    var fileName: String {
        var coms = url.lastPathComponent.split(separator: ".")
        coms.removeLast()
        return coms.joined(separator: ".")
    }
}

// MARK: - Wave Stuff
public extension PlayableURLInfo {
    var isWave: Bool {
        switch self {
        case let .remote(_, hint): return hint == .wave
        case let .local(_, hint): return hint == .wave
        default: return false
        }
    }
    
    var isRemoteWave: Bool {
        switch self {
        case let .remote(_, hint): return hint == .wave
        default: return false
        }
    }
    
    var isLocalWave: Bool {
        switch self {
        case let .local(_, hint): return hint == .wave
        default: return false
        }
    }
    
    static func isWave(for url: URL) -> Bool {
        return fileHintFromFileTypeOrContentType(url.pathExtension) == .wave
    }
}
