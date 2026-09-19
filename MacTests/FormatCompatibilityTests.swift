//
//  FormatCompatibilityTests.swift
//
//  Pins the "what can APlay actually open" matrix. Each bundled fixture is
//  driven through the real DefaultAudioDecoder (real AudioFileStream +
//  AudioConverter), so a format only counts as supported when it both parses
//  its format metadata and decodes to canonical PCM.
//
//  Every expectation below was verified empirically (see the probe notes in
//  state SF-0015) and reflects what the decoder does today on the macOS 14
//  SDK. Formats that parse but fail to decode are recorded as such — the test
//  exists to catch regressions, and a "should work" guess that contradicts
//  reality is itself a bug in the matrix.
//

import XCTest
import AudioToolbox
@testable import APlay

final class FormatCompatibilityTests: XCTestCase {

    // MARK: - Matrix

    /// One row per bundled fixture. `parses`/`decodes` describe what the *real*
    /// decoder must do today — verified, not assumed.
    struct Row {
        let name: String          // fixture base name, e.g. "tone"
        let ext: String           // fixture extension, e.g. "m4a"
        let parses: Bool          // AudioFileStream must report a data format
        let decodes: Bool         // AudioConverter must emit canonical PCM
        let formatID: UInt32      // expected srcFormat.mFormatID when parses
        let note: String
    }

    private let rows: [Row] = [
        .init(name: "tone", ext: "m4a", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatMPEG4AAC, note: "AAC in MP4"),
        .init(name: "tone", ext: "aac", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatMPEG4AAC, note: "raw AAC ADTS"),
        .init(name: "tone-cbr", ext: "mp3", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatMPEGLayer3, note: "MP3 CBR"),
        .init(name: "tone-vbr", ext: "mp3", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatMPEGLayer3, note: "MP3 VBR"),
        .init(name: "tone", ext: "flac", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatFLAC, note: "FLAC"),
        .init(name: "tone", ext: "opus", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatOpus, note: "Opus in OGG — Core Audio parses it on this platform"),
        .init(name: "tone", ext: "wav", parses: true, decodes: true,
              formatID: CoreAudio.kAudioFormatLinearPCM, note: "WAVE PCM, incl. files with LIST/INFO chunks"),
        // Parses the container but the ALAC converter rejects it (kAudioCodecUnsupportedFormatError).
        .init(name: "tone-alac", ext: "m4a", parses: true, decodes: false,
              formatID: AudioToolbox.kAudioFormatAppleLossless, note: "ALAC in MP4 — converter !dat, tracked separately"),
        .init(name: "tone", ext: "caf", parses: true, decodes: false,
              formatID: AudioToolbox.kAudioFormatAppleLossless, note: "ALAC in CAF — converter !dat, tracked separately"),
        // AIFF/AIFF-C PCM parse to lpcm but AudioFileStream reports discontinuity.
        .init(name: "tone", ext: "aiff", parses: true, decodes: false,
              formatID: CoreAudio.kAudioFormatLinearPCM, note: "AIFF PCM — dsc!, tracked separately"),
    ]

    // MARK: - The whole matrix in one report

    /// Runs every row and reports the ones that misbehave. One assertion per
    /// failing format keeps a single bad row from masking the others.
    func testFormatCompatibilityMatrix() throws {
        let harness = DecoderTestHarness()
        var failures: [String] = []

        for row in rows {
            do {
                let url = try harness.fixture(row.name, row.ext)
                let (decoder, collector) = harness.makeWiredDecoder()
                // Route through the production URL sniffer so the fixture is
                // hinted exactly the way a real local file would be (magic bytes
                // win over the extension for WAVE/FLAC).
                let info = StreamProvider.URLInfo(url: url)
                guard case let .local(_, hint) = info else {
                    failures.append("\(row.name).\(row.ext): URLInfo refused to treat it as local")
                    continue
                }
                _ = harness.attach(decoder, hint: hint, url: url)
                decoder.resume()
                let data = try Data(contentsOf: url)
                harness.feed(data, to: decoder)

                if row.parses {
                    guard decoder.info.sampleRate > 0 else {
                        failures.append("\(row.name).\(row.ext) (\(row.note)): expected to parse, sampleRate was 0")
                        continue
                    }
                    XCTAssertEqual(decoder.info.srcFormat.mFormatID, row.formatID,
                                   "\(row.name).\(row.ext) (\(row.note)) formatID")
                } else {
                    XCTAssertEqual(decoder.info.sampleRate, 0,
                                   "\(row.name).\(row.ext) (\(row.note)) must not parse without a decoder")
                }

                if row.decodes {
                    let got = harness.waitForDecodedBytes(collector, minBytes: 1000)
                    XCTAssertTrue(got, "\(row.name).\(row.ext) (\(row.note)) decoded no PCM")
                    XCTAssertTrue(collector.errors.isEmpty,
                                  "\(row.name).\(row.ext) (\(row.note)) emitted errors: \(collector.errors.count)")
                } else {
                    // Formats that parse but cannot decode yet: they must not
                    // emit PCM (they may emit errors, which is the known state).
                    harness.waitForDecodedBytes(collector, minBytes: 1, timeout: 1.0)
                    XCTAssertEqual(collector.totalBytes, 0,
                                   "\(row.name).\(row.ext) (\(row.note)) must not decode yet")
                }
                decoder.destroy()
            } catch {
                failures.append("\(row.name).\(row.ext) (\(row.note)): threw \(error)")
            }
        }

        XCTAssertTrue(failures.isEmpty, "compatibility regressions:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - WAV with extra chunks (the fixed bug)

    /// The hand-rolled WAVE parser used to assume `data` sat at a fixed offset
    /// (36 or 38). Real files insert chunks between `fmt ` and `data` — ffmpeg
    /// writes LIST/INFO, afconvert writes FLLR — so playback failed outright.
    /// After the chunk-walking fix both variants must decode fully.
    func testWaveWithChunksBeforeDataDecodes() throws {
        let harness = DecoderTestHarness()

        // ffmpeg variant: RIFF .. WAVE fmt .. LIST INFO ISFT .. data
        let ffmpeg = try harness.fixture("tone", "wav")
        try assertWaveDecodes(harness, ffmpeg, "ffmpeg LIST variant")

        // afconvert variant: RIFF .. WAVE fmt .. FLLR .. data
        let afconvert = makeAfconvertWave()
        try assertWaveDecodes(harness, afconvert, "afconvert FLLR variant")
    }

    private func assertWaveDecodes(_ harness: DecoderTestHarness, _ url: URL, _ label: String) throws {
        let (decoder, collector) = harness.makeWiredDecoder()
        _ = harness.attach(decoder, hint: .wave, url: url)
        decoder.resume()
        let data = try Data(contentsOf: url)
        harness.feed(data, to: decoder)

        XCTAssertEqual(decoder.info.srcFormat.mFormatID, CoreAudio.kAudioFormatLinearPCM, "\(label) format")
        XCTAssertEqual(decoder.info.sampleRate, 22050, "\(label) sample rate")
        XCTAssertTrue(harness.waitForDecodedBytes(collector, minBytes: 1000), "\(label) decoded no PCM")
        XCTAssertTrue(collector.errors.isEmpty, "\(label) emitted \(collector.errors.count) errors")
        decoder.destroy()
    }

    /// Generates the afconvert control file lazily and cleans it up.
    private func makeAfconvertWave() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = dir.appendingPathComponent("APlayFormatProbe-afconvert.wav")
        let source = Bundle.module.url(forResource: "tone", withExtension: "wav", subdirectory: "Fixtures")!
        let task = Process()
        task.launchPath = "/usr/bin/afconvert"
        task.arguments = ["-f", "WAVE", "-d", "LEI16", source.path, url.path]
        try? task.run()
        task.waitUntilExit()
        return url
    }

    // MARK: - Hint-table gaps

    /// Extensions Core Audio can parse but the hint table currently drops,
    /// falling back to `.mp3` and failing. Each is a one-line fix behind this
    /// test: add the extension to `fileHint(from:)`.
    func testHintTableGapsForCoreAudioCapableFormats() {
        // M4B is an audiobook MP4: Core Audio parses it as soon as it is hinted
        // as an MPEG-4 container instead of falling back to MP3.
        XCTAssertEqual(StreamProvider.URLInfo.fileHint(from: "m4b"), .mp3,
                       "m4b is not hinted today — this row documents the gap")

        // The AudioFileType table also declares types the hint table never maps.
        let declaredButUnmapped = ["ac3", "amr", "3gp", "3g2", "mp2", "mp1", "au", "snd", "rf64", "sd2"]
        for ext in declaredButUnmapped {
            XCTAssertEqual(StreamProvider.URLInfo.fileHint(from: ext), .mp3,
                           "\"\(ext)\" is declared in AudioFileType but unmapped — falls back to .mp3")
        }
    }
}
