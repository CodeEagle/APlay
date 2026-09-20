//
//  main.swift
//  APlayMacPlayback
//
//  End-to-end macOS playback validation for APlay.
//
//  Why an executable and not XCTest? `AudioOutputUnitStart` returns
//  kAudioUnitErr_CannotDoInCurrentContext (-10867) inside the xctest bundle
//  process on macOS, while it starts without complaint in a normal process.
//  Running the full pipeline (streamer -> decoder -> ring buffer ->
//  AURenderCallback -> AVAudioEngine manual rendering) as a plain executable
//  therefore gives a true end-to-end signal that XCTest cannot.
//

import APlay
import Foundation

/// Resolves the sample asset: first CLI argument, else `<package-root>/APlayDemo/a.m4a`.
private func assetURL() -> URL? {
    if let first = CommandLine.arguments.dropFirst().first {
        if first.hasPrefix("http://") || first.hasPrefix("https://") {
            return URL(string: first)
        }
        if FileManager.default.fileExists(atPath: first) {
            return URL(fileURLWithPath: first)
        }
    }
    let candidate = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // MacPlayback/
        .deletingLastPathComponent()      // package root
        .appendingPathComponent("APlayDemo/a.m4a")
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
}

/// The two short fixtures the gapless run plays back to back. Both decode to
/// the canonical output format, so the handoff must be seamless; the second
/// track is preloaded while the first one is still playing.
private func gaplessAssets() -> [URL]? {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // MacPlayback/
        .deletingLastPathComponent()      // package root
        .appendingPathComponent("MacTests/Fixtures")
    let urls = ["tone.m4a", "tone-alac.m4a"].map { fixtures.appendingPathComponent($0) }
    guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
    return urls
}

enum Verdict {
    case pending
    case pass(String)
    case fail(String)
}

/// Collects playback events and decides success. Thread-safe: events arrive on
/// background queues while the main thread polls the verdict.
final class Recorder {
    let player: APlay
    private let lock = NSLock()
    private var _playing = false
    private var _duration: Int?
    private var _failure: String?
    private var _times: [Float] = []

    init(url: URL, configuration: APlay.Configuration? = nil) {
        player = configuration.map { APlay(configuration: $0) } ?? APlay()
        player.eventPipeline.delegate(to: self) { [weak self] _, event in
            self?.handle(event)
        }
    }

    private func handle(_ event: APlay.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case let .state(state):
            if case .playing = state {
                _playing = true
                print("[phase] reached .playing")
                // The built-in EQ must accept a preset at runtime, on a live
                // render loop, without disturbing playback — and the gains must
                // read back exactly what was applied.
                player.applyEqualizerPreset(.rock)
                let readBack = player.equalizerGains
                if readBack != EqualizerPreset.rock.gains {
                    _failure = "equalizer preset did not reach the audio unit (read back \(readBack))"
                }
                // An out-of-range band must stay safe mid-playback.
                player.setEqualizerBandGain(0, at: Int.max)
            }
        case let .duration(seconds):
            _duration = seconds
            print("[phase] duration = \(seconds)s")
        case let .playback(time):
            _times.append(time)
        case let .error(error):
            _failure = "error event \(error)"
        default:
            break
        }
    }

    /// Success requires *flow*, not just state: at least three playback samples
    /// whose time strictly advances. `currentTime` accumulates inside the manual
    /// rendering input closure, which is only pulled when the render callback
    /// runs — so advancing time proves decoded PCM is actually flowing through
    /// the audio unit. A ticking timer with a silent render loop would report a
    /// frozen time and fail here.
    var verdict: Verdict {
        lock.lock(); defer { lock.unlock() }
        if let failure = _failure { return .fail(failure) }
        guard _playing, let duration = _duration, _times.count >= 3 else { return .pending }
        let first = _times.first ?? 0
        // Playback naturally ends by resetting the clock to 0, so the *last*
        // sample is not the progress signal — the peak is. A frozen render loop
        // never produces a peak above the first sample either, so the check
        // stays strict.
        let peak = _times.max() ?? 0
        guard peak > first else { return .fail("playback time never advanced (samples \(_times)) — render loop produced no decoded audio") }
        return .pass("played \(String(format: "%.1f", peak - first))s of a \(duration)s track")
    }
}

/// Watches a two-track playlist with gapless playback on. The handoff is only
/// worth anything if the output unit keeps running across it: the recorder fails
/// on any `.paused` state before the second track is heard, and the second track
/// must produce advancing playback time of its own.
final class GaplessRecorder {
    let player: APlay
    private let lock = NSLock()
    private var _failure: String?
    private var _paused = false
    private var _playing = false
    private var _secondTrackTimes: [Float] = []
    private var _switchedToSecondTrack = false

    init(urls: [URL]) {
        let config = APlay.Configuration(logPolicy: .disable,
                                         autoHandlingInterruptEvent: false,
                                         gaplessPlaybackEnabled: true)
        player = APlay(configuration: config)
        player.loopPattern = .stopWhenAllPlayed(.order)
        player.eventPipeline.delegate(to: self) { [weak self] _, event in
            self?.handle(event)
        }
    }

    private func handle(_ event: APlay.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case let .state(state):
            switch state {
            case .playing:
                _playing = true
                print("[gapless] reached .playing")
            case .paused:
                _paused = true
                print("[gapless] paused")
            default:
                break
            }
        case .playingIndexChanged:
            print("[gapless] advanced to track 2 without pausing: \(_paused == false)")
            _switchedToSecondTrack = true
        case let .playback(time):
            if _switchedToSecondTrack { _secondTrackTimes.append(time) }
        case let .error(error):
            _failure = "error event \(error)"
        default:
            break
        }
    }

    var verdict: Verdict {
        lock.lock(); defer { lock.unlock() }
        if let failure = _failure { return .fail(failure) }
        guard _switchedToSecondTrack else { return .pending }
        guard _paused == false else { return .fail("the output unit was paused at the handoff — not gapless") }
        guard _secondTrackTimes.count >= 2 else { return .pending }
        guard _secondTrackTimes.last! > _secondTrackTimes.first! else {
            return .fail("the second track's playback time never advanced — the handoff switched to an empty source")
        }
        return .pass("handed over to track 2 without pausing; track 2 advanced to \(String(format: "%.1f", _secondTrackTimes.last!))s")
    }
}

// MARK: - Entry points

/// Single-track end-to-end run (the classic regression baseline).
private func runSingleTrack() {
    guard let url = assetURL() else {
        print("FAIL: sample asset not found (pass a path as the first argument)")
        exit(2)
    }
    print("playing \(url.lastPathComponent)")
    let recorder = Recorder(url: url)
    recorder.player.play(url)
    poll(recorder.verdict)
}

/// Two-track gapless run: the second fixture is preloaded and must take the
/// output over while the audio unit keeps running.
private func runGapless() {
    guard let urls = gaplessAssets() else {
        print("FAIL: gapless fixtures not found (MacTests/Fixtures/tone.m4a and tone-alac.m4a)")
        exit(2)
    }
    print("playing \(urls.map { $0.lastPathComponent }) as a gapless list")
    let recorder = GaplessRecorder(urls: urls)
    recorder.player.play(urls, at: 0)
    poll(recorder.verdict)
}

/// Polls a verdict on the main run loop until it settles or the deadline lapses.
private func poll(_ verdictProvider: @autoclosure @escaping () -> Verdict, deadline: TimeInterval = 60) {
    let deadline = Date().addingTimeInterval(deadline)
    while true {
        switch verdictProvider() {
        case let .pass(summary):
            print("PASS: \(summary)")
            exit(0)
        case let .fail(reason):
            print("FAIL: \(reason)")
            exit(1)
        case .pending:
            break
        }
        if Date() > deadline {
            print("FAIL: timed out waiting for end-to-end playback flow")
            exit(1)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
    }
}

if CommandLine.arguments.dropFirst().first == "gapless" {
    runGapless()
} else {
    runSingleTrack()
}
