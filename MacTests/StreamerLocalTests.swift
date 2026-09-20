//
//  StreamerLocalTests.swift
//
//  Exercises the real Streamer against a local file through the framework's own
//  Configuration seam. The FileHandle read path needs no audio stack, so it can
//  run under swift test; the remote path stays covered by the MacPlayback
//  end-to-end executable.
//

import XCTest
@testable import APlay

final class StreamerLocalTests: XCTestCase {

    /// Collects streamer events (which arrive on the streamer's read queue).
    ///
    /// `hasBytesAvailable` carries a raw pointer that is only valid for the
    /// duration of the synchronous `outputPipeline.call`, so the collector must
    /// copy the bytes immediately — deferring the read would dereference freed
    /// memory.
    enum SafeEvent {
        case readyForRead
        case bytes([UInt8], Bool)
        case endEncountered
        case error(APlay.Error)
        case metadata([MetadataParser.Item])
    }

    final class Collector {
        private let lock = NSLock()
        private var _events: [SafeEvent] = []

        func append(_ event: StreamProvider.Event) {
            let safe: SafeEvent
            switch event {
            case .readyForRead: safe = .readyForRead
            case let .hasBytesAvailable(pointer, count, isFirst):
                safe = .bytes(Array(UnsafeBufferPointer(start: pointer, count: Int(count))), isFirst)
            case .endEncountered: safe = .endEncountered
            case let .errorOccurred(error): safe = .error(error)
            case let .metadata(items): safe = .metadata(items)
            default: return
            }
            lock.lock()
            _events.append(safe)
            lock.unlock()
        }

        var events: [SafeEvent] {
            lock.lock()
            defer { lock.unlock() }
            return _events
        }

        func clear() {
            lock.lock()
            _events.removeAll()
            lock.unlock()
        }

        /// Blocks until the streamer has reported EOF (or the test times out).
        func waitForEnd(timeout: TimeInterval = 5) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                let done = _events.contains { if case .endEncountered = $0 { return true }; return false }
                lock.unlock()
                if done { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        /// Blocks until the streamer has reported any error (or the test times out).
        func waitForError(timeout: TimeInterval = 5) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                let done = _events.contains { if case .error = $0 { return true }; return false }
                lock.unlock()
                if done { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    let collector = Collector()
    var streamer: StreamProviderCompatible?
    // Streamer holds its config unowned, so the test must keep it alive.
    var config: APlay.Configuration?

    /// Writes a temporary file and wires a real Streamer to it.
    func makeStreamer(payload: [UInt8], viaBuilder: Bool = false) throws -> (StreamProviderCompatible, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("APlayStreamerTest-\(UUID().uuidString).bin")
        try Data(payload).write(to: url)

        let config: APlay.Configuration
        if viaBuilder {
            // Go through the Configuration builder seam exactly like production.
            config = APlay.Configuration(streamerBuilder: { Streamer(config: $0) })
        } else {
            config = APlay.Configuration(logPolicy: .disable)
        }
        let streamer = config.streamerBuilder(config)
        streamer.outputPipeline.delegate(to: collector) { collector, event in
            collector.append(event)
        }
        self.config = config
        self.streamer = streamer
        return (streamer, url)
    }

    override func tearDown() {
        streamer?.destroy()
        // `destroy()` queues the close onto the streamer's state queue with a
        // strong self capture, and the streamer reads its config through an
        // unowned reference — so the config must outlive that queued work.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        streamer = nil
        config = nil
        super.tearDown()
    }

    func testLocalFileDeliversFullPayloadThenEnd() throws {
        let payload: [UInt8] = Array(0 ... 255) + Array(0 ... 255)
        let (streamer, url) = try makeStreamer(payload: payload)

        streamer.open(url: url, at: 0)

        collector.waitForEnd()

        let chunks = collector.events.compactMap { event -> [UInt8]? in
            if case let .bytes(bytes, _) = event { return bytes }
            return nil
        }
        let reassembled = chunks.flatMap { $0 }
        XCTAssertEqual(reassembled, payload, "streamer must deliver the whole file in order")

        XCTAssertTrue(collector.events.contains { if case .readyForRead = $0 { return true }; return false },
                      "readyForRead must precede data so the decoder parser exists")
        XCTAssertTrue(collector.events.contains { if case .endEncountered = $0 { return true }; return false })
    }

    func testFirstPacketFlagFiresOnce() throws {
        let payload = [UInt8](repeating: 0x7F, count: 20_000) // spans multiple 8KB chunks
        let (streamer, url) = try makeStreamer(payload: payload)

        streamer.open(url: url, at: 0)
        collector.waitForEnd()

        let flags = collector.events.compactMap { event -> Bool? in
            if case let .bytes(_, isFirst) = event { return isFirst }
            return nil
        }
        XCTAssertFalse(flags.isEmpty)
        XCTAssertEqual(flags.filter { $0 }.count, 1, "exactly one chunk must be flagged as the first packet")
        XCTAssertEqual(flags.first, true)
    }

    func testContentLengthAndBufferingProgress() throws {
        let payload = [UInt8](repeating: 0x01, count: 16_384)
        let (streamer, url) = try makeStreamer(payload: payload, viaBuilder: true)

        XCTAssertEqual(streamer.contentLength, 0, "before open, contentLength is unknown")
        streamer.open(url: url, at: 0)
        collector.waitForEnd()

        XCTAssertEqual(streamer.contentLength, UInt(payload.count))
        XCTAssertEqual(streamer.bufferingProgress, 1.0, "after EOF the whole file has been read")
    }

    func testOpenAtPositionSeeksIntoTheFile() throws {
        let payload: [UInt8] = Array(0 ... 199)
        let (streamer, url) = try makeStreamer(payload: payload)

        let position: StreamProvider.Position = 100
        streamer.open(url: url, at: position)
        collector.waitForEnd()

        XCTAssertEqual(streamer.position, position)

        let chunks = collector.events.compactMap { event -> [UInt8]? in
            if case let .bytes(bytes, _) = event { return bytes }
            return nil
        }
        XCTAssertEqual(chunks.flatMap { $0 }, Array(payload[100...]),
                       "opening mid-file must skip the leading bytes")
    }

    func testDestroyAllowsReopen() throws {
        let payload: [UInt8] = Array(0 ... 255) + Array(0 ... 255)
        let (streamer, url) = try makeStreamer(payload: payload)

        streamer.open(url: url, at: 0)
        collector.waitForEnd()
        XCTAssertEqual(collector.events.filter { event in
            if case .endEncountered = event { return true }
            return false
        }.count, 1)

        streamer.destroy()

        // destroy must release the stream so the same file can be opened again.
        collector.clear()
        streamer.open(url: url, at: 0)
        collector.waitForEnd()

        let chunks = collector.events.compactMap { event -> [UInt8]? in
            if case let .bytes(bytes, _) = event { return bytes }
            return nil
        }
        XCTAssertEqual(chunks.flatMap { $0 }, payload, "the file must stream in full after reopen")
    }

    func testOpeningTwiceIsRejected() throws {
        let payload = [UInt8](repeating: 0x03, count: 1024)
        let (streamer, url) = try makeStreamer(payload: payload)

        streamer.open(url: url, at: 0)
        streamer.open(url: url, at: 0)

        let errors = collector.events.filter { event in
            if case let .error(error) = event, case .openedAlready = error { return true }
            return false
        }
        XCTAssertEqual(errors.count, 1, "a second open must be rejected with .openedAlready")
    }

    /// Pausing mid-stream stops the read loop; resuming it restarts the loop and
    /// the file still arrives in full and in order.
    func testPauseAndResumeTheLocalReadLoop() throws {
        let payload = [UInt8](repeating: 0x09, count: 32_768)
        let (streamer, url) = try makeStreamer(payload: payload)

        streamer.open(url: url, at: 0)
        streamer.pause()
        // Give the queued pause a moment to land before resuming.
        Thread.sleep(forTimeInterval: 0.1)
        streamer.resume()
        collector.waitForEnd()

        let chunks = collector.events.compactMap { event -> [UInt8]? in
            if case let .bytes(bytes, _) = event { return bytes }
            return nil
        }
        XCTAssertEqual(chunks.flatMap { $0 }, payload,
                       "pause then resume must still deliver the whole file")
    }

    /// Resuming before anything is open is a no-op rather than a crash.
    func testResumeWithoutAnOpenFileIsHarmless() throws {
        let (streamer, _) = try makeStreamer(payload: [0x01, 0x02])
        streamer.resume()
        streamer.pause()
        XCTAssertEqual(collector.events.filter { if case .error = $0 { return true }; return false }.count, 0,
                       "pause/resume on an unopened streamer must not report errors")
    }

    /// A missing file reports an open error instead of throwing out of the
    /// async open path.
    func testOpeningAMissingFileReportsAnError() throws {
        let (streamer, _) = try makeStreamer(payload: [0x01])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("APlayStreamerTest-missing-\(UUID().uuidString).bin")

        streamer.open(url: url, at: 0)
        collector.waitForError()

        XCTAssertTrue(collector.events.contains { event in
            if case let .error(error) = event, case .open = error { return true }
            return false
        }, "a nonexistent file must surface an .open error")
    }
}
