extension APlay {
    /// Error for APlay
    ///
    /// - none: init state
    /// - open: error when opening stream
    /// - openedAlready: try to reopen a stream
    /// - streamParse: parser error
    /// - network: network error
    /// - networkPermission: network permission result
    /// - reachMaxRetryTime: reach max retry time error
    /// - networkStatusCode: networ reponse with status code
    /// - parser: parser error with OSStatus
    /// - player: player error
    public enum Error: Swift.Error {
        case none, open(String), openedAlready(String), streamParse(String), network(String), networkPermission(String), reachMaxRetryTime, networkStatusCode(Int), parser(OSStatus), player(String), playItemNotFound(String)
    }

}
