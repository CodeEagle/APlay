import Combine
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

    private var _subscriber: AnyCancellable?

    deinit {
        _subscriber?.cancel()
    }

    private func tagParser(for urlInfo: StreamProvider.URLInfo) -> MetadataParserCompatible? {
        var parser = _configuration.metadataParserBuilder(urlInfo.fileHint, _configuration)
        if parser == nil {
            if _urlInfo.fileHint == .mp3 {
                parser = ID3Parser(config: _configuration)
            } else if _urlInfo.fileHint == .flac {
                parser = FlacParser(config: _configuration)
            } else {
//                outputPipeline.call(.metadata([]))
                return nil
            }
        }
        _subscriber = parser?.outputStream.sink(receiveValue: { [weak self] _ in
            guard let self = self else { return }

        })
//        parser?.outputStream.delegate(to: self, with: { sself, value in
//            switch value {
//            case let .metadata(data): sself.outputPipeline.call(.metadata(data))
//            case let .tagSize(size): sself.outputPipeline.call(.metadataSize(size))
//            case let .flac(value): sself.outputPipeline.call(.flac(value))
//            default: break
//            }
//        })
        return parser
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
