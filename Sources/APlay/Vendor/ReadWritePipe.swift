public final class ReadWritePipe {
    private lazy var _queue = DispatchQueue(concurrentName: "ReadWritePipe")
    private var _readPipe: FileHandle
    private var _writePipe: FileHandle?
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

    public init(localPath: String, position: UInt64) throws {
        let path = localPath.replacingOccurrences(of: "file://", with: "")
        // fixed empty space in filename's bug
        let p = path.removingPercentEncoding ?? path
        let url = URL(fileURLWithPath: p)
        _storePath = p
        FileManager.createFileIfNeeded(at: p)
        _readPipe = try .init(forReadingFrom: url)
        _readPipe.seek(toFileOffset: position)
        readOffset = position
        // local resource dont need to init write Pipe
        do {
            _writePipe = try .init(forWritingTo: url)
            _writePipe?.seekToEndOfFile()
        } catch {}
    }

    var storePath: String { _storePath }
}

extension ReadWritePipe {
    public func write(_ data: Data) {
        _queue.asyncWrite { self._writePipe?.write(data) }
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
