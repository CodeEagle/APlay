//
//  FormatHintTests.swift
//
//  Pins down the supported-format table: which extensions and MIME types map
//  to which AudioFileType, and how local files are sniffed by magic bytes.
//  This is the authoritative "what can APlay open" list.
//

import XCTest
@testable import APlay

final class FormatHintTests: XCTestCase {

    // MARK: - Extension / MIME -> hint

    /// Every extension and MIME type the hint table recognises. Anything not
    /// listed here falls back to `.mp3`.
    func testKnownExtensionsAndMimeTypes() {
        let table: [String: AudioFileType] = [
            // FLAC
            "flac": .flac,
            // MPEG audio
            "mp3": .mp3, "mpg3": .mp3, "audio/mpeg": .mp3, "audio/mp3": .mp3,
            "mp2": .mp2,
            "mp1": .mp1,
            // WAVE family
            "wav": .wave, "wave": .wave, "audio/x-wav": .wave,
            "rf64": .rf64,
            // AIFF family
            "aiff": .aiff, "audio/x-aiff": .aiff,
            "aifc": .aifc, "audio/x-aifc": .aifc,
            // MPEG-4 container
            "m4a": .m4a, "audio/x-m4a": .m4a,
            "m4b": .m4b,   // audiobook MP4
            "mp4": .mp4, "mp4f": .mp4, "mpg4": .mp4, "audio/mp4": .mp4, "video/mp4": .mp4,
            // Core Audio Format
            "caf": .caf, "caff": .caf, "audio/x-caf": .caf,
            // Raw AAC / ADTS
            "aac": .aacADTS, "adts": .aacADTS, "aacp": .aacADTS,
            "audio/aac": .aacADTS, "audio/aacp": .aacADTS,
            // Dolby / speech / legacy containers Core Audio opens natively
            "ac3": .ac3, "audio/ac3": .ac3, "eac3": .ac3,
            "amr": .amr,
            "3gp": .k3gp, "3gpp": .k3gp, "audio/3gpp": .k3gp,
            "3g2": .k3gp2, "3gp2": .k3gp2, "audio/3gpp2": .k3gp2,
            "au": .next, "snd": .next, "audio/basic": .next,
            "sd2": .soundDesigner2,
            "w64": .w64,
            // Opus — the hint is recognised and Core Audio decodes the OGG
            // container on this platform (see the README format matrix).
            "opus": .opus, "audio/opus": .opus,
        ]

        for (value, expected) in table.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(StreamProvider.URLInfo.fileHint(from: value), expected,
                           "expected \"\(value)\" to map to \(expected.rawValue)")
        }
    }

    func testUnknownExtensionFallsBackToMp3() {
        XCTAssertEqual(StreamProvider.URLInfo.fileHint(from: "xyz"), .mp3)
        XCTAssertEqual(StreamProvider.URLInfo.fileHint(from: ""), .mp3)
    }

    // MARK: - URL -> URLInfo

    func testRemoteUrlsUseTheExtensionHint() {
        let url = URL(string: "https://example.com/a.m4a")!
        if case let .remote(resolved, hint) = StreamProvider.URLInfo(url: url) {
            XCTAssertEqual(resolved, url)
            XCTAssertEqual(hint, .m4a)
        } else { XCTFail("expected a remote info") }

        if case let .remote(_, hint) = StreamProvider.URLInfo(url: URL(string: "https://example.com/a.flac")!) {
            XCTAssertEqual(hint, .flac)
        } else { XCTFail() }

        // No scheme -> unknown.
        if case .unknown = StreamProvider.URLInfo(url: URL(string: "relative/path.mp3")!) {
        } else { XCTFail("expected .unknown for a schemeless URL") }
    }

    func testLocalUrlPrefersMagicBytesOverTheExtension() throws {
        // A file whose extension says mp3 but whose bytes are a WAVE: the sniffer
        // reads "WAVE" at offset 8 and wins.
        let url = try makeTempFile(name: "disguised.mp3", contents: [
            ("RIFF", 0),
            ("0000", 4),          // placeholder chunk size
            ("WAVE", 8),          // <- localFileHit reads here
        ])
        if case let .local(_, hint) = StreamProvider.URLInfo(url: url) {
            XCTAssertEqual(hint, .wave, "the magic bytes must override the extension")
        } else { XCTFail("expected a local info") }
    }

    func testLocalFlacIsSniffedAtOffsetZero() throws {
        // "fLaC" at offset 0 — that is where localFileHit looks on a WAVE miss.
        let url = try makeTempFile(name: "song.mp3", contents: [("fLaC", 0)])
        if case let .local(_, hint) = StreamProvider.URLInfo(url: url) {
            XCTAssertEqual(hint, .flac)
        } else { XCTFail() }
    }

    func testLocalUrlFallsBackToTheExtensionWhenTheFileIsUnreadable() {
        // No such file: the sniffer cannot read it, so the extension decides.
        let url = URL(fileURLWithPath: "/tmp/APlayFormatHint-missing.wav")
        if case let .local(_, hint) = StreamProvider.URLInfo(url: url) {
            XCTAssertEqual(hint, .wave)
        } else { XCTFail() }

        let mp3 = URL(fileURLWithPath: "/tmp/APlayFormatHint-missing.mp3")
        if case let .local(_, hint) = StreamProvider.URLInfo(url: mp3) {
            XCTAssertEqual(hint, .mp3)
        } else { XCTFail() }
    }

    func testIsWaveDetection() {
        XCTAssertTrue(StreamProvider.URLInfo.isWave(for: URL(fileURLWithPath: "/tmp/a.wav")))
        XCTAssertFalse(StreamProvider.URLInfo.isWave(for: URL(fileURLWithPath: "/tmp/a.mp3")))
    }

    // MARK: - Local content length

    func testLocalContentLengthMatchesTheFileSize() throws {
        let url = try makeTempFile(name: "sized.bin", contents: [(String(repeating: "A", count: 1234), 0)])
        XCTAssertEqual(StreamProvider.URLInfo(url: url).localContentLength(), 1234)
    }

    func testRemoteContentLengthIsZero() {
        let url = URL(string: "https://example.com/a.m4a")!
        XCTAssertEqual(StreamProvider.URLInfo(url: url).localContentLength(), 0)
    }

    // MARK: - Helpers

    /// Writes `(string, offset)` pairs into a fresh temp file, truncated to the
    /// last byte written, and returns its URL.
    private func makeTempFile(name: String, contents: [(string: String, offset: UInt64)]) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/APlayFormatHint-\(name)")
        try Data(count: 4096).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var end: UInt64 = 0
        for item in contents {
            try handle.seek(toOffset: item.offset)
            let bytes = item.string.data(using: .ascii)!
            try handle.write(contentsOf: bytes)
            end = max(end, item.offset + UInt64(bytes.count))
        }
        try handle.truncate(atOffset: end)
        return url
    }
}
