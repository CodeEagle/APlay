//
//  DecoderTestHarness.swift
//
//  Shared scaffolding for tests that drive the real DefaultAudioDecoder.
//
//  `OutputCollector` copies decoded bytes the moment they arrive: the pointer
//  in an `.output` event is only valid for the duration of the delegate call,
//  so it must be copied inside the closure (lesson ①). The harness owns the
//  `Configuration` because the decoder holds it `unowned` (lesson ④).
//

import XCTest
import AudioToolbox
@testable import APlay

/// Records what the decoder emits: decoded PCM, bitrate notifications, empty
/// ticks and errors. Safe to touch from the decode queue and the test thread.
final class OutputCollector {
    private let lock = NSLock()
    private var _bytes = Data()
    private(set) var bitrateEvents: UInt32 = 0
    private(set) var seekableEvents: Int = 0
    private(set) var emptyCount = 0
    private(set) var errors: [APlay.Error] = []
    private var _metadata: [MetadataParser.Item] = []

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
        case let .metadata(items): lock.lock(); _metadata.append(contentsOf: items); lock.unlock()
        case .seekable: lock.lock(); seekableEvents &+= 1; lock.unlock()
        }
    }

    var bytes: Data { lock.lock(); defer { lock.unlock() }; return _bytes }
    var totalBytes: Int { bytes.count }
    /// Every metadata item the decoder emitted, in arrival order.
    var metadata: [MetadataParser.Item] {
        lock.lock(); defer { lock.unlock() }; return _metadata
    }
    /// The text of every title item, in arrival order.
    var titles: [String] {
        lock.lock(); defer { lock.unlock() }
        return _metadata.compactMap { item in
            if case let .title(value) = item { return value } else { return nil }
        }
    }
}

/// Owns the configuration the decoder references `unowned`, and wires decoders
/// to collectors. One harness instance per test method.
final class DecoderTestHarness {
    private let config = APlay.Configuration(logPolicy: .disable)

    func makeDecoder() -> DefaultAudioDecoder {
        DefaultAudioDecoder(config: config)
    }

    /// Wires a collector to a fresh decoder and returns both.
    func makeWiredDecoder() -> (decoder: DefaultAudioDecoder, collector: OutputCollector) {
        let decoder = makeDecoder()
        let collector = OutputCollector()
        decoder.outputStream.delegate(to: collector) { collector, event in
            collector.record(event: event)
        }
        return (decoder, collector)
    }

    /// Feeds `data` in chunks exactly like a streamer would. `inputStream.call`
    /// is synchronous, so a per-chunk pointer is valid for the whole call.
    func feed(_ data: Data, to decoder: DefaultAudioDecoder, chunk: Int = 8 * 1024) {
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

    /// Prepares the decoder against a fake streamer carrying `hint`. Mirrors
    /// what Composer does on the first data event so the decoder takes the right
    /// input branch (the hand-rolled WAV parser only runs once fileHint == .wave).
    func attach(_ decoder: DefaultAudioDecoder, hint: AudioFileType, url: URL, contentLength: UInt = 0) -> FakeStreamProvider {
        let streamer = FakeStreamProvider()
        streamer.info = .local(url, hint)
        streamer.contentLength = contentLength
        try? decoder.prepare(for: streamer, at: 0)
        decoder.info.fileHint = hint
        return streamer
    }

    /// Spins the run loop until the collector holds at least `minBytes` of
    /// decoded PCM, or `timeout` elapses. Real decode happens on the 30ms GCD
    /// timer off the main thread, so this waits without blocking that queue.
    @discardableResult
    func waitForDecodedBytes(_ collector: OutputCollector, minBytes: Int, timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collector.totalBytes >= minBytes { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return collector.totalBytes >= minBytes
    }

    /// Loads a bundled fixture under MacTests/Fixtures.
    func fixture(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw FixtureError.missing("\(name).\(ext)")
        }
        return url
    }

    enum FixtureError: Error {
        case missing(String)
    }
}
