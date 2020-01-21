public final class ReadWritePipe {
    private lazy var _queue = DispatchQueue(concurrentName: "ReadWritePipe")
    private var _readPipe: FileHandle
    private var _writePipe: FileHandle
    private var _storePath: String
    private var _targetFileLength: UInt64 = 0
    private var _readOffset: UInt64 = 0
    public var targetFileLength: UInt64 {
        get { return _queue.sync { _targetFileLength } }
        set { _queue.asyncWrite { self._targetFileLength = newValue } }
    }

    public var readOffset: UInt64 {
        get { return _queue.sync { _readOffset } }
        set { _queue.asyncWrite { self._readOffset = newValue } }
    }

    public init(localPath: String) throws {
        let path = localPath.replacingOccurrences(of: "file://", with: "")
        let url = URL(fileURLWithPath: path)
        _storePath = path
        FileManager.createFileIfNeeded(at: path)
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

    public func readData(of length: Int) -> ReadWritePipe.ReadResult {
        return _queue.sync {
            guard _targetFileLength > 0 else { return .targetFileLenNotSet }
            guard length > 0 else { return .lengthCanNotBeNegative }
            guard _readOffset < _targetFileLength else { return .complete }
            let data = _readPipe.readData(ofLength: length)
            let count = data.count
            if count == 0 { return .waitingForData }
            _readOffset += UInt64(count)
            return .available(data)
        }
    }
}

extension ReadWritePipe {
    public enum ReadResult {
        case targetFileLenNotSet
        case lengthCanNotBeNegative
        case available(Data)
        case waitingForData
        case complete
    }
}
