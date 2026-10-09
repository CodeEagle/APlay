//
//  ResumeCacheMetaTests.swift
//
//  The resume table is the only record of which bytes a partial container
//  actually holds, so its round trip and its bitmap boundaries are load
//  bearing: a bit read wrong is either a hole the reader falls into (silence
//  or garbage) or a span the network needlessly re-downloads.
//

import XCTest
@testable import APlay

final class ResumeCacheMetaTests: XCTestCase {

    // MARK: - Bitmap

    func testBitmapSetsABlockOnlyWhenFullyWritten() {
        var bitmap = ResumeCacheBitmap(blockSize: 8192, containerLength: 16384)

        // A partial write is held in `partial` but does not set the bit: the
        // read loop must never be pointed at a half-real block.
        _ = bitmap.mark(offset: 0, length: 100)
        XCTAssertFalse(bitmap.contains(offset: 0))

        // The next chunk closes the block, and only then is it readable.
        _ = bitmap.mark(offset: 100, length: 8092)
        XCTAssertTrue(bitmap.contains(offset: 0))
        XCTAssertTrue(bitmap.contains(offset: 8191))
        XCTAssertFalse(bitmap.contains(offset: 8192), "the next block is untouched")
    }

    func testBitmapMarkSpansMultipleBlocks() {
        var bitmap = ResumeCacheBitmap(blockSize: 100, containerLength: 1000)
        _ = bitmap.mark(offset: 50, length: 300)

        // 50..349 crosses blocks 0..3; only the blocks it covers wholly close.
        XCTAssertTrue(bitmap.contains(offset: 100), "block 1 (100-199) is fully covered")
        XCTAssertTrue(bitmap.contains(offset: 250), "block 2 (200-299) is fully covered")
        XCTAssertFalse(bitmap.contains(offset: 0), "block 0 is only half covered")
        XCTAssertFalse(bitmap.contains(offset: 350), "block 3 is only half covered")

        // The partial bookkeeping survives until each block is closed.
        _ = bitmap.mark(offset: 0, length: 50)
        XCTAssertTrue(bitmap.contains(offset: 0))
        _ = bitmap.mark(offset: 349, length: 51)
        XCTAssertTrue(bitmap.contains(offset: 350))
    }

    func testBitmapCreditsACompletedBlockOnlyOnce() {
        var bitmap = ResumeCacheBitmap(blockSize: 100, containerLength: 400)

        XCTAssertEqual(bitmap.mark(offset: 0, length: 150), 100,
                       "only block 0 is closed by the first write")
        XCTAssertEqual(bitmap.mark(offset: 50, length: 150), 100,
                       "the overlap closes block 1")
        XCTAssertEqual(bitmap.mark(offset: 0, length: 200), 0,
                       "both blocks are already credited")

        XCTAssertTrue(bitmap.contains(offset: 0))
        XCTAssertTrue(bitmap.contains(offset: 199))
        XCTAssertFalse(bitmap.contains(offset: 200), "blocks 2 and 3 are untouched")
    }

    func testBitmapIgnoresOffsetsPastTheContainerEnd() {
        var bitmap = ResumeCacheBitmap(blockSize: 100, containerLength: 200)
        _ = bitmap.mark(offset: 0, length: 1000)

        XCTAssertTrue(bitmap.contains(offset: 99))
        XCTAssertTrue(bitmap.contains(offset: 199), "the final block ends at the container length")
        XCTAssertFalse(bitmap.contains(offset: 200), "there is no block 2")
        XCTAssertTrue(bitmap.isComplete, "the whole 2-block container is marked")
    }

    func testBitmapIsCompleteOnlyWhenEveryBlockIsSet() {
        var bitmap = ResumeCacheBitmap(blockSize: 100, containerLength: 300)
        XCTAssertFalse(bitmap.isComplete)

        _ = bitmap.mark(offset: 0, length: 250)
        XCTAssertFalse(bitmap.isComplete, "block 2's real span is only half covered")

        _ = bitmap.mark(offset: 250, length: 50)
        XCTAssertTrue(bitmap.isComplete)
    }

    // MARK: - Round trip

    func testRoundTripPreservesEveryField() throws {
        var meta = ResumeCacheMeta(blockSize: 8192,
                                   contentLength: 1_000_000,
                                   originURL: URL(string: "https://example.com/track.mp3")!,
                                   etag: "\"abc-123\"",
                                   lastModified: "Wed, 21 Oct 2015 07:28:00 GMT")
        _ = meta.bitmap.mark(offset: 0, length: 500_000)
        meta.lastAccess = 1_700_000_000

        let decoded = try XCTUnwrap(ResumeCacheMeta.decode(from: meta.encoded()))

        XCTAssertEqual(decoded.blockSize, 8192)
        XCTAssertEqual(decoded.contentLength, 1_000_000)
        XCTAssertEqual(decoded.originURL.absoluteString, "https://example.com/track.mp3")
        XCTAssertEqual(decoded.etag, "\"abc-123\"")
        XCTAssertEqual(decoded.lastModified, "Wed, 21 Oct 2015 07:28:00 GMT")
        XCTAssertEqual(decoded.lastAccess, 1_700_000_000)
        // 500_000 bytes reach partway into block 61, so that block is not yet
        // whole and only the 61 closed blocks before it are credited.
        XCTAssertEqual(decoded.downloadedBytes, 499_712)
        XCTAssertFalse(decoded.isComplete)
        XCTAssertEqual(decoded.bitmap.storage, meta.bitmap.storage)
    }

    func testRoundTripWithoutValidators() throws {
        var meta = ResumeCacheMeta(contentLength: 4096,
                                   originURL: URL(string: "https://example.com/a.mp3")!)
        _ = meta.bitmap.mark(offset: 0, length: 4096)

        let decoded = try XCTUnwrap(ResumeCacheMeta.decode(from: meta.encoded()))
        XCTAssertNil(decoded.etag)
        XCTAssertNil(decoded.lastModified)
        XCTAssertNil(decoded.ifRangeValue)
        XCTAssertTrue(decoded.isComplete)
    }

    func testIfRangePrefersEtag() {
        let meta = ResumeCacheMeta(contentLength: 100,
                                   originURL: URL(string: "https://example.com/a.mp3")!,
                                   etag: "\"v1\"",
                                   lastModified: "Wed, 21 Oct 2015 07:28:00 GMT")
        XCTAssertEqual(meta.ifRangeValue, "\"v1\"")
    }

    func testIfRangeFallsBackToLastModified() {
        let meta = ResumeCacheMeta(contentLength: 100,
                                   originURL: URL(string: "https://example.com/a.mp3")!,
                                   etag: nil,
                                   lastModified: "Wed, 21 Oct 2015 07:28:00 GMT")
        XCTAssertEqual(meta.ifRangeValue, "Wed, 21 Oct 2015 07:28:00 GMT")
    }

    func testDownloadedBytesClampsTheFinalPartialBlock() {
        var meta = ResumeCacheMeta(blockSize: 1000, contentLength: 2500,
                                   originURL: URL(string: "https://example.com/a.mp3")!)
        XCTAssertEqual(meta.bitmap.blockCount, 3, "2500 bytes over a 1000-byte block")

        _ = meta.bitmap.mark(offset: 0, length: 2500)
        XCTAssertEqual(meta.downloadedBytes, 2500, "the last block contributes its real 500 bytes, not 1000")
        XCTAssertTrue(meta.isComplete)
    }

    // MARK: - Rejection

    func testDecodeRejectsWrongMagic() {
        var data = Data("NOTAPLAY".utf8)
        data.append(UInt8(0)); data.append(UInt8(1))
        XCTAssertNil(ResumeCacheMeta.decode(from: data))
    }

    func testDecodeRejectsUnknownVersion() {
        var meta = ResumeCacheMeta(contentLength: 100,
                                   originURL: URL(string: "https://example.com/a.mp3")!)
        var data = meta.encoded()
        // version sits right after the 8-byte magic.
        data[8] = 0x99
        XCTAssertNil(ResumeCacheMeta.decode(from: data))
    }

    func testDecodeRejectsTruncatedPayload() {
        let meta = ResumeCacheMeta(contentLength: 100,
                                   originURL: URL(string: "https://example.com/a.mp3")!)
        let full = meta.encoded()
        XCTAssertNil(ResumeCacheMeta.decode(from: full.prefix(full.count - 4)))
    }

    // MARK: - Disk

    func testAtomicWriteAndLoad() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aplay-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let container = tmp.appendingPathComponent("track.part")
        try Data().write(to: container)

        var meta = ResumeCacheMeta(contentLength: 100_000,
                                   originURL: URL(string: "https://example.com/track.mp3")!,
                                   etag: "\"v1\"")
        _ = meta.bitmap.mark(offset: 0, length: 40_000)
        XCTAssertTrue(meta.atomicWrite(nextTo: container))

        let loaded = try XCTUnwrap(ResumeCacheMeta.load(nextTo: container))
        XCTAssertEqual(loaded.originURL.absoluteString, "https://example.com/track.mp3")
        XCTAssertEqual(loaded.etag, "\"v1\"")
        // 40_000 bytes close blocks 0...3; block 4 is still short of its end.
        XCTAssertEqual(loaded.downloadedBytes, 32_768)
        XCTAssertFalse(loaded.isComplete)

        // The temp file must not be left behind.
        let metaURL = container.appendingPathExtension("meta")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.appendingPathExtension("tmp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path))
    }

    func testLoadReturnsNilWhenNoTableExists() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aplay-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let container = tmp.appendingPathComponent("track.part")
        try Data().write(to: container)
        XCTAssertNil(ResumeCacheMeta.load(nextTo: container))
    }
}
