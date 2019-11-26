import Foundation

public final class Streamer {
    private unowned let _configuration: ConfigurationCompatible
    private unowned let _dataReader: DataReader
    private var _dataParser: DataParser = .init()
    private let _bufferSize: Int
    private var _urlInfo: StreamProvider.URLInfo = .init(url: URL(string: "https://APlay.none")!)
    public init(configuration: ConfigurationCompatible, dataReader: DataReader) {
        _configuration = configuration
        _dataReader = dataReader
        _bufferSize = Int(configuration.decodeBufferSize)
    }
}

extension Streamer {
    public func start(with info: StreamProvider.URLInfo) {
        _urlInfo = info
        readLoop()
    }

    private func readLoop() {
        // already on queue.sync
        let result = _dataReader.read(count: _bufferSize)
        switch result {
        case .targetFileLenNotSet: break
        case .lengthCanNotBeNegative: break
        case .waitingForData: print("waiting")
        case .complete: print("done")
        case let .available(data):
            _dataParser.onData(data)
        }
    }
}
