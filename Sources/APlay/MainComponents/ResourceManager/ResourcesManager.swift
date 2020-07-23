public final class ResourcesManager {
    private unowned let _configuration: ConfigurationCompatible
    @LateInit public private(set) var readWritePipeline: ReadWritePipe

    var storePath: String { readWritePipeline.storePath }

    public init(configuration: ConfigurationCompatible) {
        _configuration = configuration
    }

    public func write(data: Data) {
        readWritePipeline.write(data)
    }

    public func remoteResourceName(for url: URL, at position: StreamProvider.Position) -> String {
        let suffix = position == 0 ? ".tmp" : ".incomplete"
        let name = _configuration.cacheNaming.name(for: url).replacingOccurrences(of: "/", with: "")
        return name + suffix
    }

    public func updateResource(for url: URL, at position: StreamProvider.Position) throws -> StreamProvider.URLInfo {
        /// File url, return and use it
        guard url.isFileURL == false else {
            readWritePipeline = try .init(localPath: url.absoluteString, position: position)
            return .init(url: url, cachedURL: url, position: position)
        }

        var total = _configuration.cachePolicy.cachedFolder ?? []
        total.append(_configuration.cacheDirectory)
        let name = _configuration.cacheNaming.name(for: url)
        let first = total.compactMap { (dir) -> StreamProvider.URLInfo? in
            let path = (dir as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let u = URL(fileURLWithPath: path)
            return .init(url: u, cachedURL: u, position: position)
        }.first
        /// Has cached file, using it
        if let val = first {
            readWritePipeline = try .init(localPath: val.originalURL.absoluteString, position: position)
            return val
        }
        /// Create a local file path to store remote download
        let remoteName = remoteResourceName(for: url, at: position)
        let pathToStore = (_configuration.cacheDirectory as NSString).appendingPathComponent(remoteName)
        readWritePipeline = try .init(localPath: pathToStore, position: position)
        return .init(url: url, cachedURL: URL(fileURLWithPath: pathToStore), position: position)
    }
}

extension ResourcesManager: DataReader {
    public func read(count: Int) -> ReadWritePipe.ReadResult {
        return readWritePipeline.readData(of: count)
    }
}
