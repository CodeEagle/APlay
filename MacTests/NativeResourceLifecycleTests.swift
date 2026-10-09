import XCTest
@testable import APlay

/// Count the actual Core Audio/CFNetwork allocations, not Composer.liveCount:
/// a Swift decoder can deallocate while its opaque C handles still leak.
final class NativeResourceLifecycleTests: XCTestCase {
    func testLongReadReleasesChunksBeforeEOF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("APlay-chunk-lifetime-\(UUID().uuidString).bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 6000 * 8192)
        try file.close()
        defer { try? FileManager.default.removeItem(at: url) }

        let config = APlay.Configuration(logPolicy: .disable, cachePolicy: .disable)
        let streamer = Streamer(config: config)
        let reached = expectation(description: "5000 chunks delivered before EOF")
        let ended = expectation(description: "EOF after inspection")
        let release = DispatchSemaphore(value: 0)
        var chunks = 0
        streamer.outputPipeline.manuallyDelegate { event in
            switch event {
            case let .hasBytesAvailable(pointer, size, _):
                XCTAssertEqual(size, 8192)
                XCTAssertEqual(pointer.pointee, 0) // Pointer stays valid through delivery.
                chunks += 1
                if chunks == 5000 {
                    reached.fulfill()
                    _ = release.wait(timeout: .now() + 30)
                }
            case .endEncountered: ended.fulfill()
            default: break
            }
        }
        defer {
            release.signal()
            streamer.destroy()
            withExtendedLifetime(config) {}
        }
        let name = "NSConcreteData (Bytes Storage)"
        let before = try counts([name])[name] ?? 0
        streamer.open(url: url, at: 0)
        wait(for: [reached], timeout: 10)
        let during = try counts([name])[name] ?? 0
        print("CHUNK LIFECYCLE before=\(before) during5000=\(during)")
        // The current callback can retain its single chunk. Earlier chunks must
        // already be gone while the read queue is still parked inside the loop.
        XCTAssertLessThanOrEqual(during - before, 32)
        release.signal()
        wait(for: [ended], timeout: 10)
        XCTAssertEqual(chunks, 6000)
    }

    private func counts(_ names: [String]) throws -> [String: Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "-sortBySize"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, output.contains("CLASS_NAME") else {
            throw NSError(domain: "NativeResourceLifecycleTests.heap", code: Int(process.terminationStatus))
        }
        return Dictionary(uniqueKeysWithValues: names.map { name in
            let count = output.split(separator: "\n").first { $0.contains("   \(name) ") }
                .flatMap { Int($0.split(whereSeparator: { $0.isWhitespace }).first ?? "") } ?? 0
            return (name, count)
        })
    }

    func testRepeatedRealDecoderRetirementReleasesNativeHandles() throws {
        let harness = DecoderTestHarness()
        let url = try harness.fixture("tone", "flac")
        let data = try Data(contentsOf: url)
        func retire() {
            autoreleasepool {
                let (decoder, collector) = harness.makeWiredDecoder()
                let provider = harness.attach(decoder, hint: .flac, url: url)
                decoder.resume()
                harness.feed(data, to: decoder)
                XCTAssertTrue(harness.waitForDecodedBytes(collector, minBytes: 1000))
                decoder.destroy()
                withExtendedLifetime(provider) {}
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        retire() // Warm framework initialization before taking the baseline.
        let names = ["AudioFileStreamWrapper", "FLACAudioStream", "acv2::CodecConverter"]
        let before = try counts(names)
        for _ in 0..<20 { retire() }
        let after = try counts(names)
        print("NATIVE LIFECYCLE decoder before=\(before) after=\(after)")
        for name in names {
            XCTAssertEqual(after[name], before[name], "retired native resource accumulated: \(name)")
        }
        withExtendedLifetime(harness) {}
    }

    func testRepeatedStreamerRetirementReleasesSessionDelegatesInReleaseToo() throws {
        let config = APlay.Configuration(logPolicy: .disable)
        func retire() {
            autoreleasepool {
                let streamer = Streamer(config: config)
                streamer.destroy()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        retire()
        let names = ["Streamer.SessionDataDelegate"]
        let before = try counts(names)
        for _ in 0..<20 { retire() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let after = try counts(names)
        print("NATIVE LIFECYCLE session before=\(before) after=\(after)")
        XCTAssertEqual(after[names[0]], before[names[0]])
        withExtendedLifetime(config) {}
    }
}
