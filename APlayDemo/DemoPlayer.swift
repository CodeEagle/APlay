//
//  DemoPlayer.swift
//  APlayDemo
//
//  The single `APlay` instance behind the demo UI. Every capability the
//  framework exposes is reachable from here: local/remote playback, the four
//  loop patterns, gapless handoffs, the 8-band equalizer, Now Playing
//  injection, and the event pipeline.
//
//  Event callbacks arrive on whatever queue the audio pipeline happens to use,
//  so every published mutation is funneled back onto the main thread.
//

import APlay
import APlayExtras
import APlayMidi
import APlayOpus
import Combine
import UIKit

@MainActor
final class DemoPlayer: ObservableObject {

    // MARK: Published state

    /// What the UI is currently pointing at: the bundled format matrix, a
    /// single remote URL the user typed in, or a file picked from the device.
    enum PlaybackSource: Equatable {
        case matrix
        case remote(URL)
        case file(URL)
    }

    private(set) var source: PlaybackSource = .matrix

    /// The latest inline ICY fields, surfaced so the stream test card can show
    /// what the player actually received.
    @Published private(set) var icyStreamTitle: String?
    @Published private(set) var icyStreamURL: String?

    @Published private(set) var state: APlay.State = .idle
    @Published private(set) var nowPlayingTitle: String = "APlay"
    @Published private(set) var nowPlayingArtist: String = ""
    @Published private(set) var nowPlayingAlbum: String = ""
    @Published private(set) var cover: UIImage?
    @Published private(set) var coverPalette = CoverArt.palette(forSeed: "APlay")
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isSeekable: Bool = false
    @Published private(set) var playingIndex: Int = -1
    /// Transient buffering progress for the current track, `nil` when idle.
    @Published private(set) var buffering: Float?
    @Published private(set) var trackStatuses: [TrackLibrary.Status]
    @Published private(set) var bandGains: [Float]
    @Published private(set) var entries: [LogEntry] = []

    @Published var loopPattern: PlayList.LoopPattern = .stopWhenAllPlayed(.order) {
        didSet { player.loopPattern = loopPattern }
    }
    /// Toggling rebuilds the player: the gapless setting is baked into the
    /// configuration, which is immutable once playback has started.
    @Published var gaplessEnabled = true {
        didSet { rebuild() }
    }

    // MARK: Constants the views need

    /// Equalizer centre frequencies straight off the configuration, so the
    /// sliders can never drift from what the engine was actually built with.
    let bandFrequencies: [Float]
    let presets = EqualizerPreset.builtIn
    let supportedLoopPatterns: [PlayList.LoopPattern] = [
        .single, .order, .random, .stopWhenAllPlayed(.order),
    ]

    // MARK: Init

    init() {
        bandFrequencies = DemoPlayer.makeConfig(gapless: true, logSink: nil).equalizerBandFrequencies
        trackStatuses = Array(repeating: .idle, count: TrackLibrary.local.count)
        bandGains = Array(repeating: 0, count: bandFrequencies.count)
        config = DemoPlayer.makeConfig(gapless: true, logSink: nil)
        player = APlay(configuration: config)
        // Rebuild now that every stored property is initialized: the sink the
        // rebuilt configuration installs may capture `self`, the one above
        // could not (Swift forbids capturing partially-initialized self).
        rebuild()
    }

    deinit {
        // `deinit` is nonisolated, so the scope is released inline.
        if let scopedFileURL {
            scopedFileURL.stopAccessingSecurityScopedResource()
        }
        player.destroy()
    }

    // MARK: Sandbox scope

    /// The picker URL we currently hold sandbox access for, if any. Kept
    /// apart from `source` because the token has to be released explicitly —
    /// handing the URL to the player does not keep access alive by itself.
    /// `nonisolated(unsafe)` because `deinit` releases it off the main actor;
    /// every other access is main-actor bound.
    nonisolated(unsafe) private var scopedFileURL: URL?

    /// Claims sandbox access for a document-picker URL, releasing any scope
    /// the previous source was holding.
    @discardableResult
    func retainScopedFileURL(_ url: URL) -> Bool {
        let granted = url.startAccessingSecurityScopedResource()
        guard granted else {
            appendLog("Sandbox access denied for \(url.lastPathComponent)", isFramework: false)
            return false
        }
        releaseScopedFileURL()
        scopedFileURL = url
        return true
    }

    func releaseScopedFileURL() {
        if let scopedFileURL {
            scopedFileURL.stopAccessingSecurityScopedResource()
            self.scopedFileURL = nil
        }
    }

    // MARK: Playback

    func playMatrix() {
        releaseScopedFileURL()
        let urls = TrackLibrary.localURLs()
        guard !urls.isEmpty else {
            appendLog("No bundled samples found in the app bundle", isFramework: false)
            return
        }
        source = .matrix
        trackStatuses = Array(repeating: .idle, count: TrackLibrary.local.count)
        config.startBackgroundTask()
        player.play(urls, at: 0)
    }

    /// Jumps to one row of the format matrix.
    func playTrack(at index: Int) {
        guard TrackLibrary.local.indices.contains(index) else { return }
        if source != .matrix {
            releaseScopedFileURL()
            source = .matrix
            config.startBackgroundTask()
            player.play(TrackLibrary.localURLs(), at: index)
        } else {
            config.startBackgroundTask()
            player.play(at: index)
        }
    }

    func playRemote(_ url: URL) {
        releaseScopedFileURL()
        source = .remote(url)
        playingIndex = -1
        nowPlayingTitle = url.lastPathComponent
        nowPlayingArtist = url.host ?? ""
        nowPlayingAlbum = "Remote stream"
        let seed = url.absoluteString
        cover = CoverArt.image(forSeed: seed)
        coverPalette = CoverArt.palette(forSeed: seed)
        pushNowPlaying()
        config.startBackgroundTask()
        player.play(url)
    }

    /// Plays a file the document picker handed over. The URL is
    /// security-scoped, so the scope is claimed here and held until playback
    /// moves to any other source.
    func playFile(_ url: URL) {
        guard retainScopedFileURL(url) else { return }
        source = .file(url)
        playingIndex = -1
        icyStreamTitle = nil
        icyStreamURL = nil
        nowPlayingTitle = url.lastPathComponent
        nowPlayingArtist = url.deletingPathExtension().lastPathComponent
        nowPlayingAlbum = "Local file"
        let seed = url.absoluteString
        cover = CoverArt.image(forSeed: seed)
        coverPalette = CoverArt.palette(forSeed: seed)
        pushNowPlaying()
        config.startBackgroundTask()
        player.play(url)
    }

    func toggle() {
        player.toggle()
    }

    /// True while the player streams from this device's own ICY test server.
    var isPlayingLocalStream: Bool {
        if case let .remote(url) = source {
            return url.host == "127.0.0.1" || url.host == "localhost"
        }
        return false
    }

    /// Stops playback outright. `pause()` halts the output unit immediately, so
    /// a stream whose ring buffer is still draining — or which is about to
    /// reconnect — makes no further sound. The ICY card calls this when its
    /// server is shut down mid-playback; stopping the server alone left the
    /// buffered audio still playing out for a while.
    func stop() {
        player.pause()
        releaseScopedFileURL()
        source = .matrix
        playingIndex = -1
        icyStreamTitle = nil
        icyStreamURL = nil
        nowPlayingTitle = "APlay"
        nowPlayingArtist = ""
        nowPlayingAlbum = ""
        cover = nil
        coverPalette = CoverArt.palette(forSeed: "APlay")
        currentTime = 0
        duration = 0
        isSeekable = false
        buffering = nil
        trackStatuses = Array(repeating: .idle, count: TrackLibrary.local.count)
        pushNowPlaying()
    }

    func seek(to time: TimeInterval) {
        player.seek(to: time)
        currentTime = time
    }

    func next() { player.next() }
    func previous() { player.previous() }

    // MARK: Equalizer

    func setBandGain(at index: Int, to gain: Float) {
        player.setEqualizerBandGain(gain, at: index)
        bandGains = player.equalizerGains
    }

    @discardableResult
    func applyPreset(_ preset: EqualizerPreset) -> Bool {
        let applied = player.applyEqualizerPreset(preset)
        bandGains = player.equalizerGains
        return applied
    }

    // MARK: Log

    func log(_ text: String) {
        appendLog(text, isFramework: false)
    }

    func clearLog() {
        entries.removeAll()
    }

    // MARK: Internals

    var config: APlay.Configuration
    private var player: APlay
    /// Index of the last track the UI blamed a framework log line on.
    private var logIndex = -1

    /// Builds the configuration the demo runs on. The `APlayExtras` file
    /// decoder is chained in front of the built-in streaming decoder so the
    /// three containers that one cannot open (AIFF/AIFF-C/CAF) still play —
    /// and so the demo can badge those rows with the route that serves them.
    /// `APlayMidi` sits one step further in: a `.mid` is a note sequence, not
    /// an audio stream, so it is rendered through the bundled SoundFont.
    /// `APlayOpus` takes the WebM/Matroska rows Core Audio has no parser for.
    private static func makeConfig(gapless: Bool, logSink: ((String) -> Void)?) -> APlay.Configuration {
        let soundfont = Bundle.main.url(forResource: "APlayTestSine", withExtension: "sf2")
        return APlay.Configuration(
            cachePolicy: .disable,
            autoHandlingInterruptEvent: true,
            gaplessPlaybackEnabled: gapless,
            enableVolumeMixer: true,
            enableRemoteCommandHandling: true,
            loggerBuilder: { policy in
                DemoLogger(policy: policy, sink: logSink ?? { _ in })
            },
            audioDecoderBuilder: APlayExtras.fileDecoder(fallback: APlayMidi.decoder(
                fallback: APlayOpus.decoder(
                    fallback: { config in
                        // A fresh default configuration is the only public way to reach
                        // the built-in decoder builder; building one here also keeps the
                        // chain from recursing into this router.
                        APlay.Configuration().audioDecoderBuilder(config)
                    }),
                soundfont: .init(url: soundfont)))
        )
    }

    /// Recreates the player so a configuration change (gapless on/off) takes
    /// effect. A player that had not started anything is replaced silently.
    private func rebuild() {
        let hadStarted = playingIndex >= 0 || state.isPlaying
        guard hadStarted else {
            player.eventPipeline.delegate(to: DemoPlayer.noop) { _, _ in }
            player.destroy()
            config = DemoPlayer.makeConfig(gapless: gaplessEnabled) { [weak self] line in
                // The framework logs on its own background queue; a `@Published`
                // mutation there re-enters SwiftUI's body getter off the main
                // thread and traps. Hop over first.
                if Thread.isMainThread {
                    self?.appendLog(line, isFramework: true)
                } else {
                    DispatchQueue.main.async { [weak self] in self?.appendLog(line, isFramework: true) }
                }
            }
            player = APlay(configuration: config)
            player.loopPattern = loopPattern
            wireEvents()
            return
        }

        let wasPlaying = state.isPlaying
        let index = max(playingIndex, 0)
        let source = self.source
        let time = currentTime

        player.eventPipeline.delegate(to: DemoPlayer.noop) { _, _ in }
        player.destroy()

        config = DemoPlayer.makeConfig(gapless: gaplessEnabled) { [weak self] line in
            // The framework logs on its own background queue; a `@Published`
            // mutation there re-enters SwiftUI's body getter off the main
            // thread and traps. Hop over first.
            if Thread.isMainThread {
                self?.appendLog(line, isFramework: true)
            } else {
                DispatchQueue.main.async { [weak self] in self?.appendLog(line, isFramework: true) }
            }
        }
        player = APlay(configuration: config)
        player.loopPattern = loopPattern
        wireEvents()

        switch source {
        case .matrix:
            player.play(TrackLibrary.localURLs(), at: index)
        case let .remote(url):
            player.play(url)
        case let .file(url):
            player.play(url)
        }
        if !wasPlaying {
            player.pause()
        } else if time > 0, isSeekable {
            player.seek(to: time)
        }
    }

    private func wireEvents() {
        player.eventPipeline.delegate(to: self) { [weak self] _, event in
            guard let self else { return }
            if Thread.isMainThread {
                self.handle(event)
            } else {
                DispatchQueue.main.async { [weak self] in self?.handle(event) }
            }
        }
    }

    // MARK: Event handling

    private func handle(_ event: APlay.Event) {
        switch event {
        case let .state(newState):
            state = newState
            if newState.isPlaying { markCurrentStatus(.playing) }
            log("state → \(newPlayingStateLabel(newState))")

        case let .playingIndexChanged(index):
            markStatus(.played, at: playingIndex)   // whatever we were mid-play
            playingIndex = index
            buffering = nil
            if case .matrix = source, TrackLibrary.local.indices.contains(index) {
                markCurrentStatus(.playing)
                adoptTrack(TrackLibrary.local[index])
            }
            log("playingIndexChanged → \(index)")

        case let .duration(seconds):
            duration = TimeInterval(seconds)
        case let .playback(time):
            currentTime = TimeInterval(time)
        case let .seekable(value):
            isSeekable = value
        case let .buffering(progress):
            buffering = progress
        case .waitForStreaming:
            log("slow network — waiting for more data")
        case .streamerEndEncountered:
            log("streamer reached end of track")
        case .playEnded:
            markCurrentStatus(.played)
            log("playEnded")
        case let .playModeChanged(pattern):
            loopPattern = pattern
        case .playlistChanged:
            log("playlist changed")
        case let .metadata(items):
            applyParsedMetadata(items)
        case let .flac(metadata):
            log("flac metadata: \(metadata)")
        case let .error(error):
            markCurrentStatus(.failed)
            log("✘ \(error)")
        }
    }

    // MARK: Metadata → Now Playing

    /// The framework auto-fills parsed ID3 tags into Now Playing; this method
    /// shows the manual injection path and supplies artwork for files that
    /// carry no cover at all (which is every bundled tone).
    private func applyParsedMetadata(_ items: [MetadataParser.Item]) {
        var title: String?
        var artist: String?
        var album: String?
        var coverData: Data?
        for item in items {
            switch item {
            case let .title(value): title = value
            case let .artist(value): artist = value
            case let .album(value): album = value
            case let .cover(data): coverData = data
            // Inline ICY frames arrive as raw fields: StreamTitle is surfaced
            // to the stream test card, and also feeds Now Playing unless a
            // later item (icy-name arrives last) overrides the title.
            case let .other(dict):
                if let value = dict["StreamTitle"] {
                    title = value
                    icyStreamTitle = value
                }
                if let value = dict["StreamUrl"] {
                    icyStreamURL = value
                }
            default: continue
            }
        }
        if let title { nowPlayingTitle = title }
        if let artist { nowPlayingArtist = artist }
        if let album { nowPlayingAlbum = album }
        if let coverData, let image = UIImage(data: coverData) {
            cover = image
        }
        pushNowPlaying()
        log("metadata parsed: \(items.count) item(s)")
    }

    /// Adopts a matrix row as the current track: generated artwork and a
    /// fallback title, pushed to the lock screen straight away.
    private func adoptTrack(_ track: Track) {
        nowPlayingTitle = track.displayName
        nowPlayingArtist = track.format
        nowPlayingAlbum = track.route == .native
            ? "APlay · native decoder"
            : track.route == .midi ? "APlayMidi · SoundFont sampler"
            : track.route == .opus ? "APlayOpus · EBML demuxer" : "APlayExtras · ExtAudioFile"
        let seed = track.resourceName + "." + track.resourceType
        cover = CoverArt.image(forSeed: seed)
        coverPalette = CoverArt.palette(forSeed: seed)
        pushNowPlaying()
    }

    private func pushNowPlaying() {
        player.metadataUpdate(title: nowPlayingTitle,
                              album: nowPlayingAlbum,
                              artist: nowPlayingArtist,
                              cover: cover)
    }

    // MARK: Matrix status

    private func markCurrentStatus(_ status: TrackLibrary.Status) {
        guard case .matrix = source, TrackLibrary.local.indices.contains(playingIndex) else { return }
        trackStatuses[playingIndex] = status
    }

    private func markStatus(_ status: TrackLibrary.Status, at index: Int) {
        guard TrackLibrary.local.indices.contains(index) else { return }
        trackStatuses[index] = status
    }

    // MARK: Log

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isFramework: Bool
    }

    private func appendLog(_ text: String, isFramework: Bool) {
        entries.append(LogEntry(text: text, isFramework: isFramework))
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
    }

    private func newPlayingStateLabel(_ state: APlay.State) -> String {
        switch state {
        case .idle: return "idle"
        case .playing: return "playing"
        case .paused: return "paused"
        case let .error(error): return "error(\(error))"
        case let .unknown(error): return "unknown(\(error))"
        }
    }

    /// A stable no-op target so a player being torn down stops calling back.
    private static let noop = NoopSink()
}

private final class NoopSink: AnyObject {}

// MARK: - Custom logger (injection seam demo)

/// Captures the framework's internal log lines into the demo's event stream.
/// Supplied through `Configuration.loggerBuilder`, alongside the decoder
/// builder above — both are seams the library leaves open for exactly this.
private final class DemoLogger: LoggerCompatible {

    let currentFile = ""
    let isLoggedToConsole = false
    private let sink: (String) -> Void

    init(policy: Logger.Policy, sink: @escaping (String) -> Void) {
        self.sink = sink
    }

    // `LoggerCompatible` also requires a policy-only initializer.
    convenience init(policy: Logger.Policy) {
        self.init(policy: policy, sink: { _ in })
    }

    // `Logger.Channel` keeps its symbols and cases internal, so the demo
    // forwards the message as-is — the method name already says which
    // subsystem logged it.
    func log(_ msg: String, to channel: Logger.Channel, method: String) {
        sink("\(method): \(msg)")
    }

    func cleanAllLogs() {}
    func reset() {}
}

// MARK: - Time formatting

enum TimeFormat {
    static func string(from seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Pretty frequency labels for the equalizer sliders.
    static func frequency(_ hertz: Float) -> String {
        hertz >= 1000
            ? String(format: "%.1fk", hertz / 1000).replacingOccurrences(of: ".0", with: "")
            : "\(Int(hertz))"
    }
}
