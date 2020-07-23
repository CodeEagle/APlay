/// Event for playback
///
/// - state: player state
/// - buffering: buffer event with progress
/// - waitForStreaming: bad network detech, waiting for more data to come
/// - streamerEndEncountered: stream end
/// - playEnded: playback complete
/// - playback: playback with current time
/// - duration: song duration
/// - seekable: seekable event
/// - playlistChanged: playlist changed
/// - playLoopPatternChanged: loop pattern changed
/// - error: error
/// - metadata: song matadata
/// - flac: flac metadata
public enum Event {
    case state(State)
    case buffering(URLSessionDelegator.Info)
    case waitForStreaming
    case streamerEndEncountered
    case playEnded
    case playback(Float)
    case duration(Int)
    case seekable(Bool)
    case playingIndexChanged(PlayingIndex)
    case playlistChanged([URL])
    case playLoopPatternChanged(LoopPattern)
    case error(APlay.Error)
    case metadata([MetadataParser.Item])
    case flac(FlacMetadata)
    case unknown(Error)
}
