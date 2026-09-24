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
import APlayMidi
import APlayOpus
import APlaySpeex
import APlayVorbis
import APlayWavPack
import Foundation
import AVFoundation
import Darwin

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
        if let configuration = configuration {
            player = APlay(configuration: configuration)
        } else {
            let base = APlay.Configuration()
            let ext = url.pathExtension.lowercased()
            // Only the formats the framework default cannot handle are wired
            // through their optional decoder; everything else stays on the
            // default builder so nothing is wrapped unnecessarily.
            let builder: AudioDecoderBuilder
            switch ext {
            case "webm", "mka":
                builder = APlayOpus.decoder(fallback: base.audioDecoderBuilder)
            case "wv":
                builder = APlayWavPack.decoder(fallback: base.audioDecoderBuilder)
            case "ogg":
                builder = APlayVorbis.decoder(fallback: base.audioDecoderBuilder)
            case "spx":
                builder = APlaySpeex.decoder(fallback: base.audioDecoderBuilder)
            case "mid", "midi", "kar":
                let sf2 = url.deletingLastPathComponent()
                    .appendingPathComponent("APlayTestSine.sf2")
                let soundfont = FileManager.default.fileExists(atPath: sf2.path)
                    ? APlayMidi.Soundfont(url: sf2) : .default
                builder = APlayMidi.decoder(fallback: base.audioDecoderBuilder,
                                            soundfont: soundfont)
            default:
                builder = base.audioDecoderBuilder
            }
            player = APlay(configuration: APlay.Configuration(audioDecoderBuilder: builder))
        }
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

/// Storage is allocated before playback. The tap only uses bounded sample reads
/// and lock-free OSAtomic operations (available on the package's macOS 12 floor).
private final class StressEvidence {
    let frames = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    let nonzero = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let lock = NSLock()
    private var states: [String] = []
    private var index = 0
    private var failure: String?

    init() {
        frames.initialize(to: 0)
        nonzero.initialize(to: 0)
    }

    deinit {
        frames.deinitialize(count: 1); frames.deallocate()
        nonzero.deinitialize(count: 1); nonzero.deallocate()
    }

    func attach(to player: APlay) {
        player.pcmTap = { [self] buffers, count, format in
            guard count > 0 else { return }
            OSAtomicAdd64Barrier(Int64(count), frames)
            if OSAtomicAdd64Barrier(0, nonzero) != 0 { return }
            // Inspect at most 64 valid samples per buffer; never scan padded
            // silence beyond the decoded frame count. Numeric comparisons also
            // distinguish floating-point negative zero from nonzero PCM.
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers)) {
                guard let data = buffer.mData else { continue }
                let sampleCount = min(64, Int(count) * Int(buffer.mNumberChannels))
                var heard = false
                switch format.commonFormat {
                case .pcmFormatInt16:
                    for i in 0..<min(sampleCount, Int(buffer.mDataByteSize) / 2) {
                        if data.load(fromByteOffset: i * 2, as: Int16.self) != 0 { heard = true; break }
                    }
                case .pcmFormatInt32:
                    for i in 0..<min(sampleCount, Int(buffer.mDataByteSize) / 4) {
                        if data.load(fromByteOffset: i * 4, as: Int32.self) != 0 { heard = true; break }
                    }
                case .pcmFormatFloat32:
                    for i in 0..<min(sampleCount, Int(buffer.mDataByteSize) / 4) {
                        let value = data.load(fromByteOffset: i * 4, as: Float.self)
                        if value.isFinite && value != 0 { heard = true; break }
                    }
                case .pcmFormatFloat64:
                    for i in 0..<min(sampleCount, Int(buffer.mDataByteSize) / 8) {
                        let value = data.load(fromByteOffset: i * 8, as: Double.self)
                        if value.isFinite && value != 0 { heard = true; break }
                    }
                default: break
                }
                if heard { OSAtomicAdd64Barrier(1, nonzero); break }
            }
        }
        player.eventPipeline.delegate(to: self) { recorder, event in
            recorder.lock.lock(); defer { recorder.lock.unlock() }
            switch event {
            case let .state(state):
                switch state {
                case .idle: recorder.states.append("idle")
                case .paused: recorder.states.append("paused")
                case .playing: recorder.states.append("running")
                case let .error(error): recorder.failure = "state error: \(error)"
                case let .unknown(error): recorder.failure = "state unknown: \(error)"
                }
            case let .playingIndexChanged(index): recorder.index = index
            case let .error(error): recorder.failure = "error event: \(error)"
            default: break
            }
        }
    }

    var snapshot: (index: Int, failure: String?) {
        lock.lock(); defer { lock.unlock() }
        return (index, failure)
    }

    func report() {
        lock.lock()
        let sequence = states
        lock.unlock()
        print("[stress] renderedFrames=\(OSAtomicAdd64Barrier(0, frames)) nonzeroPCM=\(OSAtomicAdd64Barrier(0, nonzero) > 0)")
        print("[stress] state events (playing mapped to running; not AU stop counts): idle=\(sequence.filter { $0 == "idle" }.count) paused=\(sequence.filter { $0 == "paused" }.count) running=\(sequence.filter { $0 == "running" }.count)")
        print("[stress] state sequence: \(sequence.joined(separator: " -> "))")
    }
}

// AAC tone.m4a and PCM tone.wav decode to different formats, forcing output reconfiguration.
// Avoid aiff/aifc: localFileHit misidentifies them as mp3, so playback fails.
// Use tone.m4a/tone-alac.m4a as the same-format control without reconfiguration.
private func stressAssets(_ fileNames: [String]?) -> [URL] {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MacTests/Fixtures")
    let pair = fileNames ?? ["tone.m4a", "tone.wav"]
    let urls = pair.map { fixtures.appendingPathComponent($0) }
    guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
        print("FAIL: stress fixtures not found: \(pair) under MacTests/Fixtures")
        exit(2)
    }
    return urls
}

private func runStress(switches: Int, interval: TimeInterval, fileNames: [String]? = nil) {
    runStressPlayback(switches: switches, interval: interval, fileNames: fileNames, gapless: false)
}

private func runStressGapless(switches: Int, interval: TimeInterval, fileNames: [String]? = nil) {
    runStressPlayback(switches: switches, interval: interval, fileNames: fileNames, gapless: true)
}

private func runStressPlayback(switches: Int, interval: TimeInterval, fileNames: [String]?, gapless: Bool) {
    // Flush evidence even if the process crashes or the external watchdog kills it.
    setbuf(stdout, nil)
    guard switches >= (gapless ? 1 : 0), switches < 100_000,
          interval.isFinite, interval > 0 else {
        print("FAIL: invalid stress switches/interval")
        exit(2)
    }
    let urls = stressAssets(fileNames)
    print("[stress] mode=\(gapless ? "stress-gapless" : "stress") targetSwitches=\(switches) interval=\(interval) fixtures=\(urls.map { $0.lastPathComponent })")
    let evidence = StressEvidence()
    print("[stress] before player initialization (initial evidence, not a verdict)")
    evidence.report()
    let player = APlay(configuration: APlay.Configuration(logPolicy: .disable,
        autoHandlingInterruptEvent: false, gaplessPlaybackEnabled: gapless))
    evidence.attach(to: player)
    let start = Date()
    let lock = NSLock()
    var done = 0
    var finishedSwitching = false
    var timer: DispatchSourceTimer?
    if gapless {
        // interval controls observation cadence only; never force next()/seek().
        player.loopPattern = .stopWhenAllPlayed(.order)
        player.play((0...switches).map { urls[$0 % urls.count] }, at: 0)
    } else {
        player.play(urls[0])
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        source.schedule(deadline: .now() + 0.5, repeating: interval)
        source.setEventHandler {
            lock.lock()
            if done >= switches {
                finishedSwitching = true
                lock.unlock()
                source.cancel()
                return
            }
            done += 1
            let index = done
            lock.unlock()
            player.play(urls[index % urls.count])
        }
        timer = source
        source.resume()
    }
    let deadline = start.addingTimeInterval(115)
    var previousTime: TimeInterval?
    var finalAdvanced = false
    var finalPeak: TimeInterval = 0
    var failure: String?
    var completed = false
    var lastReport = start
    while Date() < deadline {
        let snapshot = evidence.snapshot
        lock.lock()
        let ready = gapless ? snapshot.index == switches : finishedSwitching
        let count = gapless ? snapshot.index : done
        lock.unlock()
        if let error = snapshot.failure { failure = error; break }
        if ready {
            let time = player.currentTime()
            if let previous = previousTime, time > previous, previous >= 0 { finalAdvanced = true }
            previousTime = time
            finalPeak = max(finalPeak, time)
            if finalAdvanced, OSAtomicAdd64Barrier(0, evidence.frames) > 0,
               OSAtomicAdd64Barrier(0, evidence.nonzero) > 0 {
                completed = true
                break
            }
        }
        if Date().timeIntervalSince(lastReport) >= 5 {
            print("[stress] completedSwitches=\(count) finalTrackTime=\(finalPeak)")
            evidence.report()
            lastReport = Date()
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: gapless ? min(interval, 0.1) : 0.02))
    }
    timer?.cancel()
    evidence.report()
    print("[stress] finalTrackTimePeak=\(finalPeak) advanced=\(finalAdvanced)")
    if OSAtomicAdd64Barrier(0, evidence.frames) == 0 {
        print("FAIL: no audio rendered")
    } else if OSAtomicAdd64Barrier(0, evidence.nonzero) == 0 {
        print("FAIL: no nonzero PCM sampled")
    } else if let failure = failure {
        print("FAIL: \(failure)")
    } else if !completed {
        print("FAIL: timed out waiting for \(switches) switches and final-track currentTime advancement")
    } else {
        print("PASS: survived \(switches) \(gapless ? "natural handoffs" : "switches") in \(String(format: "%.1f", Date().timeIntervalSince(start)))s; rendered nonzero PCM and final-track currentTime advanced")
        exit(0)
    }
    exit(1)
}

if let mode = CommandLine.arguments.dropFirst().first {
    if mode == "gapless" {
        runGapless()
    } else if mode == "stress" || mode == "stress-gapless" {
        let rest = CommandLine.arguments.dropFirst().dropFirst()
        let switches = rest.first.flatMap(Int.init) ?? (mode == "stress" ? 400 : 2)
        let interval = rest.dropFirst().first.flatMap(Double.init) ?? 0.02
        let names = Array(rest.dropFirst().dropFirst().prefix(2))
        if mode == "stress-gapless" {
            runStressGapless(switches: switches, interval: interval, fileNames: names.isEmpty ? nil : names)
        } else {
            runStress(switches: switches, interval: interval, fileNames: names.isEmpty ? nil : names)
        }
    } else {
        runSingleTrack()
    }
} else {
    runSingleTrack()
}
