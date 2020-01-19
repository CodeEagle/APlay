public enum PlayingIndex {
    case none
    case some(UInt)

    public var value: UInt? {
        switch self {
        case .none: return nil
        case let .some(v): return v
        }
    }
}
