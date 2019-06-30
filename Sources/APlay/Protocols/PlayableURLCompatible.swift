public protocol PlayableURLCompatible: Equatable {
    var url: URL { get }
}

extension URL: PlayableURLCompatible {
    public var url: URL { return self }
}
