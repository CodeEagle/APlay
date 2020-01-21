import Combine
import CoreGraphics

final class FlacParser {
    private lazy var _outputStream: PassthroughSubject<MetadataParser.Event, Never> = .init()
    private lazy var _data = Data()
    private lazy var _backupHeaderData = Data()
    private lazy var _isHeaderParserd = false
    private lazy var _state: MetadataParser.State = .initial
    private lazy var _queue = DispatchQueue(concurrentName: "FlacParser")
    private var _flacMetadata: FlacMetadata?
    init(config _: ConfigurationCompatible) {}
}

extension FlacParser: MetadataParserCompatible {
    var eventPipeline: AnyPublisher<MetadataParser.Event, Never> {
        return _outputStream.eraseToAnyPublisher()
    }

    func acceptInput(data: Data) {
        guard _state.isNeedData else { return }
        _queue.async(flags: .barrier) { self.appendTagData(data) }
        _queue.sync {
            if _state == .initial, _data.count < 4 { return }
            parse()
        }
    }
}

// MARK: - Private

extension FlacParser {
    private func appendTagData(_ data: Data) {
        _data.append(data)
        _backupHeaderData.append(data)
    }

    private func parse() {
        if _state == .initial {
            guard let head = String(data: _data[0 ..< 4], encoding: .ascii), head == FlacMetadata.tag else {
                _state = .error("Not a flac file")
                return
            }
            _data = _data.advanced(by: 4)
            _state = .parsering
        }
        var hasBlock = true
        while hasBlock {
            guard _data.count >= FlacMetadata.Header.size else { return }
            let bytes = _data[0 ..< FlacMetadata.Header.size]
            let header = FlacMetadata.Header(bytes: bytes)
            let blockSize = Int(header.metadataBlockDataSize)
            let blockLengthPosition = FlacMetadata.Header.size + blockSize
            guard _data.count >= blockLengthPosition else { return }
            _data = _data.advanced(by: FlacMetadata.Header.size)
            switch header.blockType {
            case .streamInfo:
                let streamInfo = FlacMetadata.StreamInfo(data: _data, header: header)
                _flacMetadata = FlacMetadata(streamInfo: streamInfo)
            case .seektable:
                let tables = FlacMetadata.SeekTable(bytes: _data, header: header)
                _flacMetadata?.seekTable = tables
            case .padding:
                let padding = FlacMetadata.Padding(header: header, length: UInt32(header.metadataBlockDataSize))
                _flacMetadata?.addPadding(padding)
            case .application:
                let app = FlacMetadata.Application(bytes: _data, header: header)
                _flacMetadata?.application = app
            case .cueSheet:
                let cue = FlacMetadata.CUESheet(bytes: _data, header: header)
                _flacMetadata?.cueSheet = cue
            case .vorbisComments:
                let comment = FlacMetadata.VorbisComments(bytes: _data, header: header)
                _flacMetadata?.vorbisComments = comment
            case .picture:
                let picture = FlacMetadata.Picture(bytes: _data, header: header)
                _flacMetadata?.picture = picture
            case .undifined: print("Flac metadta header error, undifined block type")
            }
            _data = _data.advanced(by: blockSize)
            hasBlock = header.isLastMetadataBlock == false
            if hasBlock == false {
                _state = .complete
                if var value = _flacMetadata {
                    _outputStream.send(.tagSize(value.totalSize()))
                    if let meta = value.vorbisComments?.asMetadata() {
                        _outputStream.send(.metadata(meta))
                    }
                    let size = value.totalSize()
                    value.headerData = Data(_backupHeaderData[0 ..< Int(size)])
                    _backupHeaderData = Data()
                    _outputStream.send(.flac(value))
                }
                _outputStream.send(.end)
                _outputStream.send(completion: .finished)
            }
        }
    }
}
