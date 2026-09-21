//
//  MidiDecoderTests.swift
//
//  Pins the optional `APlayMidi` product: a Standard MIDI File renders to
//  canonical, *audible* PCM through a bundled SoundFont, and every other URL
//  still reaches the fallback decoder.
//

import XCTest
@testable import APlayMidi
import AudioToolbox
import CoreAudio
@testable import APlay

final class MidiDecoderTests: XCTestCase {

    private let harness = DecoderTestHarness()

    /// Owns the configuration the decoder references `unowned`, for the whole
    /// test — the decoder outliving it would crash on the first log call.
    private let config = APlay.Configuration(logPolicy: .disable)

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try harness.fixture(name, ext)
    }

    private func wait(for collector: OutputCollector, minBytes: Int) -> Bool {
        harness.waitForDecodedBytes(collector, minBytes: minBytes)
    }

    private func fileSize(of url: URL) -> UInt {
        UInt((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// The loudest sample in the decoded PCM — proves the render is not silence.
    private func peak(of data: Data) -> Int32 {
        var peak: Int32 = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                peak = max(peak, abs(Int32(samples[i])))
            }
        }
        return peak
    }

    private func makeDecoder(soundfont: APlayMidi.Soundfont) -> (MidiDecoder, OutputCollector) {
        let decoder = APlayMidi.decoder(fallback: { DefaultAudioDecoder(config: $0) },
                                        soundfont: soundfont)(config) as! MidiDecoder
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }
        return (decoder, collector)
    }

    // MARK: - Decoding

    /// A local MIDI file renders to canonical PCM through the bundled
    /// SoundFont, and the render is audible rather than a silent buffer.
    func testDecodesMidi() throws {
        let midi = try fixture("melody", "mid")
        let sf2 = try fixture("APlayTestSine", "sf2")
        let (decoder, collector) = makeDecoder(soundfont: .init(url: sf2))

        let streamer = FakeStreamProvider()
        streamer.info = .local(midi, .midi)
        streamer.contentLength = fileSize(of: midi)

        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)

        XCTAssertTrue(wait(for: collector, minBytes: 40_000),
                      "MIDI rendered no PCM")
        XCTAssertTrue(collector.errors.isEmpty,
                      "MIDI emitted \(collector.errors.count) errors")
        XCTAssertEqual(decoder.info.dstFormat.mSampleRate, 44100, accuracy: 1,
                       "the wrapper delivers canonical PCM")
        XCTAssertEqual(decoder.info.dstFormat.mChannelsPerFrame, 2)
        XCTAssertTrue(decoder.seekable(), "a buffered local file must report seekable")
        XCTAssertGreaterThan(peak(of: collector.bytes), 1000,
                             "the SoundFont rendered silence")
    }

    /// The reported length matches the fixture's 2.5 s, so the pipeline's
    /// duration bar and end detection line up with the music.
    func testReportsTheTrackDuration() throws {
        let midi = try fixture("melody", "mid")
        let (decoder, _) = makeDecoder(soundfont: .init(url: try fixture("APlayTestSine", "sf2")))

        let streamer = FakeStreamProvider()
        streamer.info = .local(midi, .midi)
        streamer.contentLength = fileSize(of: midi)
        try decoder.prepare(for: streamer, at: 0)

        let duration = Double(decoder.info.audioDataPacketCount) / decoder.info.sampleRate
        XCTAssertEqual(duration, 2.5, accuracy: 0.05)
    }

    /// Playback drives to the end of the track and reports it via `.empty`.
    func testReachesEndOfTrack() throws {
        let midi = try fixture("melody", "mid")
        let (decoder, collector) = makeDecoder(soundfont: .init(url: try fixture("APlayTestSine", "sf2")))

        let streamer = FakeStreamProvider()
        streamer.info = .local(midi, .midi)
        streamer.contentLength = fileSize(of: midi)
        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)

        // The whole 2.5 s track is ~441 kB of canonical PCM; wait for the
        // end-of-track event itself rather than a byte count, because the
        // renderer keeps pulling the release tail before it reports empty.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, collector.emptyCount == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(collector.totalBytes, 400_000,
                             "the track did not render to the end")
        XCTAssertEqual(collector.emptyCount, 1,
                       "the decoder must report the end of the track exactly once")
    }

    // MARK: - Lifecycle

    /// Pause, resume and destroy are all reachable and none of them disturb
    /// the render pipeline.
    func testPauseResumeAndDestroyAreSafe() throws {
        let midi = try fixture("melody", "mid")
        let (decoder, collector) = makeDecoder(soundfont: .init(url: try fixture("APlayTestSine", "sf2")))

        let streamer = FakeStreamProvider()
        streamer.info = .local(midi, .midi)
        streamer.contentLength = fileSize(of: midi)
        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)
        XCTAssertTrue(wait(for: collector, minBytes: 20_000),
                      "the track should render before pausing")

        decoder.pause()
        let paused = collector.totalBytes
        // Paused means the render timer is suspended: a brief wait must not add PCM.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(collector.totalBytes, paused, "a paused decoder must keep rendering")

        decoder.resume()
        XCTAssertTrue(wait(for: collector, minBytes: paused + 20_000),
                      "a resumed decoder must keep rendering")
        decoder.destroy()
        XCTAssertTrue(collector.errors.isEmpty)
    }

    /// A bank outside the GM set splits across MSB/LSB; a bank the soundfont
    /// does not carry fails to load but the track still plays.
    func testNonGeneralMidiBankIsSplitAcrossMsbAndLsb() throws {
        let midi = try fixture("melody", "mid")
        let (decoder, collector) = makeDecoder(soundfont: .init(url: try fixture("APlayTestSine", "sf2"),
                                                                bank: 1))

        let streamer = FakeStreamProvider()
        streamer.info = .local(midi, .midi)
        streamer.contentLength = fileSize(of: midi)
        decoder.resume()
        try decoder.prepare(for: streamer, at: 0)
        XCTAssertTrue(wait(for: collector, minBytes: 20_000),
                      "a failed soundfont load must not stop playback")
    }

    // MARK: - SMF parsing

    /// The bundled reader measures the same duration the fixture advertises.
    func testSmfParserMeasuresTheFixture() throws {
        let data = try Data(contentsOf: try fixture("melody", "mid"))
        let smf = try XCTUnwrap(SMFFile(data: data))
        XCTAssertEqual(smf.duration, 2.5, accuracy: 0.01)
    }

    /// Running status, system exclusive and the system-common messages all
    /// advance the cursor the right number of bytes, so a real-world file that
    /// uses them still yields the right duration.
    func testParserHandlesRunningStatusSysexAndSystemCommon() throws {
        var track: [UInt8] = [
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,   // delta 0, tempo 500 000 µs/quarter
            0x00, 0xC0, 0x00,                              // delta 0, program 0
            0x00, 0x90, 60, 100,                          // delta 0, note on (opens running status)
            0x60, 0x3C, 0x00,                              // delta 96, note off via running status
            0x00, 0xF0, 0x03, 0x01, 0x02, 0xF7,            // delta 0, system exclusive
            0x00, 0xF2, 0x00, 0x00,                        // delta 0, song position pointer (2 bytes)
            0x00, 0xF1, 0x00,                              // delta 0, MIDI time code (1 byte)
            0x00, 0xFF, 0x2F, 0x00,                        // delta 0, end of track
        ]
        var file = [UInt8]("MThd".utf8)
        file += [0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x01, 0xE0]
        file += [UInt8]("MTrk".utf8)
        let length = UInt32(track.count)
        file += [UInt8(length >> 24), UInt8(length >> 16), UInt8(length >> 8), UInt8(length)]
        file += track

        let smf = try XCTUnwrap(SMFFile(data: Data(file)))
        // 96 ticks at 480/quarter and 120 BPM = 0.1 s.
        XCTAssertEqual(smf.duration, 0.1, accuracy: 0.001)
    }

    /// A track that opens with a data byte but has no prior status is
    /// malformed and refused.
    func testParserRejectsARunningStatusWithoutAPriorStatus() throws {
        let track: [UInt8] = [0x00, 0x3C, 0x00]      // data bytes, no status first
        var file = [UInt8]("MThd".utf8)
        file += [0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x01, 0xE0]
        file += [UInt8]("MTrk".utf8)
        let length = UInt32(track.count)
        file += [UInt8(length >> 24), UInt8(length >> 16), UInt8(length >> 8), UInt8(length)]
        file += track

        XCTAssertNil(SMFFile(data: Data(file)))
    }

    /// Garbage is refused rather than producing a bogus duration.
    func testSmfParserRejectsGarbage() throws {
        XCTAssertNil(SMFFile(data: Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertNil(SMFFile(data: Data()))
        let notMidi = try Data(contentsOf: try fixture("tone-cbr", "mp3"))
        XCTAssertNil(SMFFile(data: notMidi))
    }

    // MARK: - Routing

    /// Direct construction (no fallback) refuses a non-MIDI URL with a parser
    /// error instead of mishandling it.
    func testDirectConstructionRefusesAnMp3() throws {
        let url = try fixture("tone-cbr", "mp3")
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = MidiDecoder(config: config)

        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)

        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0)) { error in
            guard case .parser = error as? APlay.Error else {
                XCTFail("expected a parser error, got \(error)"); return
            }
        }
        XCTAssertFalse(decoder.seekable(), "nothing was opened, so the decoder is not seekable")
    }

    /// A directly-constructed decoder (no fallback) routes its lifecycle calls
    /// to the stand-in decoder and stays safe — nothing is opened, so it must
    /// not pretend to play.
    func testDirectConstructionLifecycleIsSafe() throws {
        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = MidiDecoder(config: config)

        // No file was ever prepared, so every lifecycle call is a no-op and
        // the stream pipes exist but stay silent.
        decoder.pause()
        decoder.resume()
        decoder.destroy()
        XCTAssertFalse(decoder.seekable())
        _ = decoder.outputStream
        _ = decoder.inputStream
    }

    /// A file the sequencer cannot open reports a parser error rather than
    /// crashing.
    func testCorruptFileReportsAnError() throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).mid")
        try Data([0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
                  0x00, 0x00, 0x00, 0x01, 0x01, 0xE0]).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        let (decoder, collector) = makeDecoder(soundfont: .default)
        let streamer = FakeStreamProvider()
        streamer.info = .local(corrupt, .midi)

        // A header with no track chunk: the parser rejects it.
        XCTAssertThrowsError(try decoder.prepare(for: streamer, at: 0))
        XCTAssertEqual(collector.errors.count, 1)
    }

    /// A format this library does not own must still reach the fallback, so
    /// adding the product never regresses any other format. Routing only —
    /// whether the fallback actually decodes is its own test suite's job.
    func testMp3ReachesTheFallback() throws {
        let fake = FakeDecoder()
        let url = try fixture("tone-cbr", "mp3")
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, .mp3)
        fake.setAttached(streamer)

        let config = APlay.Configuration(logPolicy: .disable)
        let decoder = APlayMidi.decoder(fallback: { _ in fake })(config)
        try decoder.prepare(for: streamer, at: 0)

        XCTAssertEqual(fake.prepareCalls.count, 1,
                       "the fallback decoder must prepare for a local mp3")
        XCTAssertEqual(fake.prepareFileHints, [.mp3])
    }
}
