//
//  DefaultAudioDecoderTests.swift
//
//  Drives the real AudioFileStream/AudioConverter decoder with synthesized WAV
//  (the hand-rolled header parser) and a real m4a fixture (the AAC decode path),
//  so the actual parsing/conversion code is exercised rather than a fake.
//

import XCTest
import AudioToolbox
@testable import APlay

final class DefaultAudioDecoderTests: XCTestCase {

    // MARK: - Output collection

    /// Copies decoder output into a buffer the moment it arrives: the pointer in an
    /// `.output` event is only valid for the duration of the delegate call.
    final class OutputCollector {
        private let lock = NSLock()
        private var _bytes = Data()
        private(set) var bitrateEvents: UInt32 = 0
        private(set) var emptyCount = 0
        private(set) var errors: [APlay.Error] = []

        func append(_ pointer: UnsafeRawPointer, _ count: UInt32) {
            let buffer = UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: Int(count))
            lock.lock(); _bytes.append(contentsOf: buffer); lock.unlock()
        }

        func record(event: AudioDecoder.Event) {
            switch event {
            case let .output((pointer, count)): append(pointer, count)
            case .bitrate: lock.lock(); bitrateEvents &+= 1; lock.unlock()
            case .empty: lock.lock(); emptyCount &+= 1; lock.unlock()
            case let .error(error): lock.lock(); errors.append(error); lock.unlock()
            case .seekable: break
            }
        }

        var bytes: Data { lock.lock(); defer { lock.unlock() }; return _bytes }
        var totalBytes: Int { bytes.count }
    }

    // MARK: - Fixtures

    private let fixtureURL = Bundle.module.url(forResource: "a", withExtension: "m4a", subdirectory: "Fixtures")!

    /// The decoder holds its config `unowned`, so the test must keep one alive for
    /// as long as the decoder runs (lesson ④: unowned references must be owned
    /// by the test, not passed as temporaries).
    private let config = APlay.Configuration(logPolicy: .disable)

    private func makeDecoder() -> DefaultAudioDecoder {
        DefaultAudioDecoder(config: config)
    }

    /// Wires a collector to a fresh decoder and returns both.
    private func makeWiredDecoder() -> (decoder: DefaultAudioDecoder, collector: OutputCollector) {
        let decoder = makeDecoder()
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }
        return (decoder, collector)
    }

    /// Feeds `data` in chunks exactly like a streamer would. `inputStream.call` is
    /// synchronous, so a per-chunk pointer is valid for the whole call.
    private func feed(_ data: Data, to decoder: DefaultAudioDecoder, chunk: Int = 8 * 1024) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < data.count {
                let length = min(chunk, data.count - offset)
                decoder.inputStream.call((base.advanced(by: offset), UInt32(length), offset == 0))
                offset += length
            }
        }
    }

    /// Builds a 16-bit PCM WAV file. `subchunk1Size` of 18 adds the `cbSize` field,
    /// which exercises the 46-byte-header branch of the parser.
    private func makeWave(channels: UInt16 = 1, sampleRate: UInt32 = 44100, frames: Int = 44100,
                          extendedHeader: Bool = false, payload: [UInt8] = []) -> Data {
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = payload.isEmpty ? UInt32(frames * Int(blockAlign)) : UInt32(payload.count)
        let byteRate = sampleRate * UInt32(blockAlign)

        var data = Data()
        func u32(_ value: UInt32) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) }) }
        func u16(_ value: UInt16) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) }) }

        data.append("RIFF".data(using: .ascii)!)
        u32(36 + dataSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        u32(extendedHeader ? 18 : 16)
        u16(1)                      // PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        if extendedHeader { u16(0) } // cbSize
        data.append("data".data(using: .ascii)!)
        u32(dataSize)

        if payload.isEmpty {
            for index in 0..<frames {
                let sample = sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)) * 32000
                u16(UInt16(bitPattern: Int16(sample)))
            }
        } else {
            data.append(contentsOf: payload)
        }
        return data
    }

    private func attach(_ decoder: DefaultAudioDecoder, hint: AudioFileType, url: URL, contentLength: UInt = 0) -> FakeStreamProvider {
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, hint)
        streamer.contentLength = contentLength
        try? decoder.prepare(for: streamer, at: 0)
        // Composer syncs the streamer's hint into the decoder on the first data
        // event; mirror that here so the decoder takes the right input branch
        // (the hand-rolled WAV parser only runs once `info.fileHint == .wave`).
        decoder.info.fileHint = hint
        return streamer
    }

    // MARK: - WAV parsing (synchronous, hand-rolled header parser)

    func testWaveHeaderIsParsedAndPcmIsForwarded() throws {
        let (decoder, collector) = makeWiredDecoder()
        let wave = makeWave(channels: 1, sampleRate: 44100, frames: 44100)
        _ = attach(decoder, hint: .wave, url: URL(fileURLWithPath: "/tmp/t.wav"))

        feed(wave, to: decoder)

        XCTAssertEqual(decoder.info.sampleRate, 44100)
        XCTAssertEqual(decoder.info.srcFormat.mFormatID, CoreAudio.kAudioFormatLinearPCM)
        XCTAssertEqual(decoder.info.srcFormat.mChannelsPerFrame, 1)
        XCTAssertEqual(decoder.info.srcFormat.mBitsPerChannel, 16)
        XCTAssertEqual(decoder.info.srcFormat.mFramesPerPacket, 1)
        XCTAssertEqual(decoder.info.dataOffset, 44, "the parser must report where the PCM payload starts")
        XCTAssertEqual(decoder.info.audioDataByteCount, 88200)
        XCTAssertEqual(decoder.info.audioDataPacketCount, 44100, "one PCM frame per packet")
        XCTAssertEqual(decoder.info.bitrate, 705, "byteRate * 8 / 1000")
        XCTAssertTrue(decoder.seekable())
        XCTAssertEqual(collector.totalBytes, 88200, "the payload after the header must be forwarded verbatim")
        XCTAssertEqual(collector.bytes, wave.suffix(88200))
    }

    func testExtendedWaveHeaderIsParsed() throws {
        let (decoder, collector) = makeWiredDecoder()
        let payload = (0..<2000).map { _ in UInt8.random(in: 0...255) }
        let wave = makeWave(channels: 2, sampleRate: 22050, frames: 0, extendedHeader: true, payload: payload)
        _ = attach(decoder, hint: .wave, url: URL(fileURLWithPath: "/tmp/t.wav"))

        feed(wave, to: decoder)

        XCTAssertEqual(decoder.info.sampleRate, 22050)
        XCTAssertEqual(decoder.info.srcFormat.mChannelsPerFrame, 2)
        XCTAssertEqual(decoder.info.dataOffset, 46, "subchunk1Size == 18 means a 46-byte header")
        XCTAssertEqual(decoder.info.audioDataByteCount, UInt(payload.count))
        XCTAssertEqual(collector.totalBytes, payload.count)
        XCTAssertEqual(collector.bytes, Data(payload))
    }

    func testWavePayloadAfterTheHeaderStreamsThrough() throws {
        let (decoder, collector) = makeWiredDecoder()
        _ = attach(decoder, hint: .wave, url: URL(fileURLWithPath: "/tmp/t.wav"))

        // First chunk carries the header; once parsed, subsequent chunks must pass
        // through as PCM without re-parsing.
        let header = makeWave(channels: 1, sampleRate: 8000, frames: 0, payload: [1, 2, 3, 4])
        feed(header, to: decoder)
        XCTAssertEqual(collector.totalBytes, 4)

        feed(Data([9, 9, 9, 9]), to: decoder, chunk: 4)
        XCTAssertEqual(collector.totalBytes, 8)
        XCTAssertEqual(collector.bytes, Data([1, 2, 3, 4, 9, 9, 9, 9]))
    }

    func testNonWaveInputReportsAnError() throws {
        let (decoder, collector) = makeWiredDecoder()
        _ = attach(decoder, hint: .wave, url: URL(fileURLWithPath: "/tmp/t.wav"))

        feed(Data(repeating: 0x41, count: 64), to: decoder)

        XCTAssertEqual(collector.errors.count, 1)
        if case let .open(message)? = collector.errors.first {
            XCTAssertEqual(message, "Not a validate wave format")
        } else { XCTFail("expected an .open error") }
    }

    func testWaveWithMissingFmtChunkReportsAnError() throws {
        let (decoder, collector) = makeWiredDecoder()
        _ = attach(decoder, hint: .wave, url: URL(fileURLWithPath: "/tmp/t.wav"))

        var broken = Data()
        broken.append("RIFF".data(using: .ascii)!)
        broken.append(contentsOf: [0, 0, 0, 0])
        broken.append("WAVE".data(using: .ascii)!)
        broken.append("JUNK".data(using: .ascii)!)
        feed(broken, to: decoder)

        XCTAssertEqual(collector.errors.count, 1)
    }

    // MARK: - m4a decode (real AudioFileStream + AudioConverter path)

    func testM4aParsesFormatAndDecodesToCanonicalPcm() throws {
        let (decoder, collector) = makeWiredDecoder()
        let data = try Data(contentsOf: fixtureURL)
        _ = attach(decoder, hint: .m4a, url: fixtureURL, contentLength: UInt(data.count))

        decoder.resume()
        feed(data, to: decoder)

        // Format metadata is set synchronously while the bytes are parsed.
        XCTAssertEqual(decoder.info.srcFormat.mFormatID, AudioToolbox.kAudioFormatMPEG4AAC)
        XCTAssertEqual(decoder.info.sampleRate, 44100)
        XCTAssertEqual(decoder.info.srcFormat.mChannelsPerFrame, 2)
        XCTAssertGreaterThan(decoder.info.audioDataPacketCount, 0)
        let duration = Double(decoder.info.audioDataPacketCount) * Double(decoder.info.srcFormat.mFramesPerPacket) / decoder.info.sampleRate
        XCTAssertGreaterThan(duration, 100, "the fixture is ~136s")

        // Decoded PCM arrives on the 30ms decode loop; wait for it to drain.
        let drained = expectation(description: "decode loop drained the queued packets")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { drained.fulfill() }
        wait(for: [drained], timeout: 10.0)

        XCTAssertGreaterThan(collector.totalBytes, 100_000, "real AAC samples must be decoded")
        XCTAssertEqual(collector.totalBytes % 4, 0, "canonical output is 2ch * 16-bit")
        XCTAssertGreaterThan(collector.bitrateEvents, 0, "bitrate is estimated from the packets")
        XCTAssertTrue(collector.errors.isEmpty, "a clean fixture must not produce decoder errors")
        print("m4a decoded \(collector.totalBytes) bytes from \(data.count) bytes of input")
    }

    func testDestroyStopsDecoding() throws {
        let (decoder, collector) = makeWiredDecoder()
        let data = try Data(contentsOf: fixtureURL)
        _ = attach(decoder, hint: .m4a, url: fixtureURL, contentLength: UInt(data.count))

        decoder.resume()
        feed(data, to: decoder)
        decoder.destroy()

        let frozen = expectation(description: "no output after destroy")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { frozen.fulfill() }
        wait(for: [frozen], timeout: 5.0)

        XCTAssertEqual(collector.totalBytes, 0, "the decode loop must not run after destroy")
    }

    func testPauseAndResumeReachTheStreamer() throws {
        let (decoder, _) = makeWiredDecoder()
        let streamer = FakeStreamProvider()
        streamer.info = .local(fixtureURL, .m4a)
        try decoder.prepare(for: streamer, at: 0)

        decoder.resume()
        XCTAssertEqual(streamer.resumeCount, 1)
        decoder.pause()
        XCTAssertEqual(streamer.pauseCount, 1)
        decoder.resume()
        XCTAssertEqual(streamer.resumeCount, 2)

        decoder.destroy()
    }

    func testPrepareAtNonZeroPositionKeepsTheExistingInfo() throws {
        let (decoder, _) = makeWiredDecoder()
        let streamer = FakeStreamProvider()
        streamer.info = .local(fixtureURL, .m4a)
        try decoder.prepare(for: streamer, at: 0)
        decoder.info.sampleRate = 22050   // pretend a seek mid-stream

        try decoder.prepare(for: streamer, at: 12345)

        XCTAssertEqual(decoder.info.sampleRate, 22050, "a non-zero position must not reset accumulated info")
        decoder.destroy()
    }
}
