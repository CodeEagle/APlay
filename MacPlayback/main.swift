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

    init(url: URL) {
        player = APlay()
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
                // The built-in EQ must accept gains at runtime without disturbing
                // playback (out-of-range index and live gain must both be safe).
                player.setEqualizerBandGain(6, at: 0)
                player.setEqualizerBandGain(-3, at: 3)
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
        let last = _times.last ?? 0
        guard last > first else { return .fail("playback time never advanced (samples \(_times)) — render loop produced no decoded audio") }
        return .pass("played \(String(format: "%.1f", last - first))s of a \(duration)s track")
    }
}

guard let url = assetURL() else {
    print("FAIL: sample asset not found (pass a path as the first argument)")
    exit(2)
}

print("playing \(url.lastPathComponent)")
let recorder = Recorder(url: url)
recorder.player.play(url)

let deadline = Date().addingTimeInterval(90)
while true {
    switch recorder.verdict {
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
