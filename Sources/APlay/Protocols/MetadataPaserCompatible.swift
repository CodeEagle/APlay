
/// Protocol for metadata parser
public protocol MetadataParserCompatible: AnyObject {
    var eventPipeline: AnyPublisher<MetadataParser.Event, Never> { get }
    func acceptInput(data: Data)
    func parseID3V1Tag(at url: URL)
    init(config: ConfigurationCompatible)
}

extension MetadataParserCompatible { func parseID3V1Tag(at _: URL) {} }
