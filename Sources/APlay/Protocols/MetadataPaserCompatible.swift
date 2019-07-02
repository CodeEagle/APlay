
/// Protocol for metadata parser
public protocol MetadataParserCompatible: AnyObject {
    var outputStream: AnyPublisher<MetadataParser.Event, Never> { get }
    func acceptInput(data: UnsafeMutablePointer<UInt8>, count: UInt32)
    func parseID3V1Tag(at url: URL)
    init(config: ConfigurationCompatible)
}

extension MetadataParserCompatible { func parseID3V1Tag(at _: URL) {} }