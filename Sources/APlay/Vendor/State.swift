/// Player State
///
/// - idle: init state
/// - playing: playing
/// - paused: paused
/// - error: error
/// - unknown: exception
public enum State {
    case idle
    case playing
    case paused
    case error(Error)
    case unknown(Swift.Error)

    public var isPlaying: Bool {
        switch self {
        case .playing: return true
        default: return false
        }
    }
}
