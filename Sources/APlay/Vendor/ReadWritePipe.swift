public final class ReadWritePipe {
    private lazy var _queue = DispatchQueue(concurrentName: "ReadWritePipe")
    private var _readPipe: FileHandle
    private var _writePipe: FileHandle
    private var _storePath: String
    public init(localPath: String) throws {
        let path = localPath.replacingOccurrences(of: "file://", with: "")
        let url = URL(fileURLWithPath: path)
        _storePath = path
        FileManager.createFileIfNeeded(at: url)
        _readPipe = try .init(forReadingFrom: url)
        _writePipe = try .init(forWritingTo: url)
        _writePipe.seekToEndOfFile()
    }
    var storePath: String { _storePath }
}

extension ReadWritePipe {
    public func write(_ data: Data) {
        _queue.asyncWrite { self._writePipe.write(data) }
    }
    
    public func readData(ofLength count: Int) -> Data {
        guard count > 0 else { return .init() }
        return _queue.sync { _readPipe.readData(ofLength: count) }
    }
}
