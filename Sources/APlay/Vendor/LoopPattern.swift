public indirect enum LoopPattern: Equatable {
    /// Single Loop
    case single
    /// Order Loop
    case order
    /// Random Loop
    case random
    /// Stop when play once for pattern single/order/random
    case stopWhenAllPlayed(LoopPattern)
    
    public var isGonnaStopAtEndOfList: Bool {
        switch self {
        case .stopWhenAllPlayed: return true
        default: return false
        }
    }
}
