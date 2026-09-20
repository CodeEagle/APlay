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
        // ALAC in MP4 needs the magic cookie the file stream exposes; before
        // the fix the decoder asked for the wrong property, got '!prp', and
        // never fed the cookie to the converter ('!dat').
        .init(name: "tone-alac", ext: "m4a", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatAppleLossless, note: "ALAC in MP4"),
        // CAF carries its packet table after the audio data, so the streaming
        // parser reports 'optm' (not optimised). A container limitation, not a
        // decoder bug — seekable-file playback handles it, streaming cannot.
        .init(name: "tone", ext: "caf", parses: true, decodes: false,
              formatID: AudioToolbox.kAudioFormatAppleLossless, note: "ALAC in CAF — packet table trails the data ('optm')"),
        // AIFF/AIFF-C PCM parse to lpcm but AudioFileStream reports discontinuity.
        .init(name: "tone", ext: "aiff", parses: true, decodes: false,
              formatID: CoreAudio.kAudioFormatLinearPCM, note: "AIFF PCM — dsc!, tracked separately"),
        .init(name: "tone", ext: "aifc", parses: false, decodes: false,
              formatID: CoreAudio.kAudioFormatLinearPCM, note: "AIFF-C PCM — streaming reports no properties at all; local files decode through APlayExtras"),
        // AAC in a plain MP4 container (as opposed to .m4a): the hint table
        // routes it separately, but the payload decoder is the same.
        .init(name: "tone-mp4", ext: "mp4", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatMPEG4AAC, note: "AAC in MP4"),
        // Audiobook MP4: identical bytes to tone.m4a, but hinted as .m4b so
        // Core Audio takes the MP4 branch instead of an MP3 fallback.
        .init(name: "tone", ext: "m4b", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatMPEG4AAC, note: "Audiobook MP4"),
        // MPEG audio Layer II — same AudioFileStream path as MP3, one layer down.
        .init(name: "tone-mp2", ext: "mp2", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatMPEGLayer2, note: "MP2"),
        // Dolby Digital in its own container.
        .init(name: "tone", ext: "ac3", parses: true, decodes: true,
              formatID: AudioToolbox.kAudioFormatAC3, note: "AC-3"),
        .init(name: "tone", ext: "eac3", parses: true, decodes: true,
              formatID: 0x65632D33 /* 'ec-3' */, note: "E-AC-3 (Dolby Digital Plus)"),
        // NeXT/Sun AU carrying µ-law speech PCM.
        .init(name: "tone", ext: "au", parses: true, decodes: false,
              formatID: AudioToolbox.kAudioFormatULaw, note: "AU µ-law — parses the header, but the converter emits no PCM"),
        // Block PCM (IMA ADPCM) inside a WAVE container: decodes to PCM,
        // and Core Audio reports the source as plain linear PCM.
        .init(name: "tone-ima4", ext: "wav", parses: true, decodes: true,
              formatID: CoreAudio.kAudioFormatLinearPCM, note: "IMA ADPCM in WAVE"),
        // 3GPP containers: the hint table maps the extensions, but
        // AudioFileStream cannot parse the container at all.
        .init(name: "tone", ext: "3gp", parses: false, decodes: false,
              formatID: 0, note: "AAC in 3GPP — container not parsed by the streaming decoder"),
        .init(name: "tone", ext: "3g2", parses: false, decodes: false,
              formatID: 0, note: "AAC in 3GPP2 — container not parsed by the streaming decoder"),
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

    // MARK: - Hint-table coverage

    /// Extensions the hint table used to drop (falling back to `.mp3` and
    /// failing), now mapped to the AudioFileType Core Audio opens natively.
    /// This test pins the fix: any of these regressing to `.mp3` is a bug.
    func testHintTableCoversCoreAudioCapableFormats() {
        let mapped: [String: AudioFileType] = [
            "m4b": .m4b,               // audiobook MP4
            "ac3": .ac3,
            "amr": .amr,
            "3gp": .k3gp, "3g2": .k3gp2,
            "mp2": .mp2, "mp1": .mp1,
            "au": .next, "snd": .next,
            "rf64": .rf64, "sd2": .soundDesigner2,
        ]
        for (ext, expected) in mapped {
            XCTAssertEqual(StreamProvider.URLInfo.fileHint(from: ext), expected,
                           "\"\(ext)\" must map to \(expected.rawValue), not fall back to .mp3")
        }
    }
}
