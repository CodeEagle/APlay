import XCTest
@testable import APlay

final class DiskCacheCleanerTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aplay-cleaner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ directory: URL, _ name: String, time: TimeInterval = 100) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x61, count: 16384).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
        return url
    }

    private func size(_ url: URL) throws -> UInt64 {
        UInt64(try XCTUnwrap(url.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func sidecar(_ container: URL, access: TimeInterval) throws -> URL {
        var meta = ResumeCacheMeta(contentLength: 32768,
                                   originURL: URL(string: "https://example.com/track.mp3")!, etag: "v1")
        meta.bitmap.mark(offset: 0, length: 16384)
        meta.lastAccess = access
        XCTAssertTrue(meta.atomicWrite(nextTo: container))
        return container.appendingPathExtension("meta")
    }

    func testWithinBudgetPreservesEveryFile() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = try file(dir, "final")
        let part = try file(dir, "track.part")
        let meta = try sidecar(part, access: 50)
        let budget = try size(final) + size(part) + size(meta)
        var logs: [String] = []
        DiskCacheCleaner().sweepIfNeeded(cacheDirectory: dir.path, maxSize: budget, log: { logs.append($0) })
        for url in [final, part, meta] { XCTAssertTrue(exists(url)) }
        XCTAssertEqual(logs, ["Disk cache total allocated size: \(budget) bytes"])
    }

    func testEvictsOldestGroupsAndStopsAtBudget() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldest = try file(dir, "oldest", time: 10)
        let part = try file(dir, "track.part", time: 500)
        let meta = try sidecar(part, access: 20)
        let temporary = try file(dir, "track.part.meta.tmp")
        let newest = try file(dir, "newest", time: 30)
        let budget = try size(newest)
        var logs: [String] = []
        DiskCacheCleaner().sweepIfNeeded(cacheDirectory: dir.path, maxSize: budget, log: { logs.append($0) })
        for url in [oldest, part, meta, temporary] { XCTAssertFalse(exists(url)) }
        XCTAssertTrue(exists(newest))
        XCTAssertEqual(logs.first, "Disk cache deleted: oldest")
        XCTAssertEqual(logs.filter { $0.hasPrefix("Disk cache deleted:") }.count, 4)
        XCTAssertEqual(logs.last, "Disk cache total allocated size: \(budget) bytes")
    }

    func testSparseContainerUsesAllocatedSize() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let part = dir.appendingPathComponent("sparse.part")
        try Data().write(to: part)
        let handle = try FileHandle(forWritingTo: part)
        try handle.truncate(atOffset: 4 * 1024 * 1024)
        try handle.close()
        let allocated = try size(part)
        XCTAssertLessThan(allocated, 64 * 1024)
        let final = try file(dir, "final")
        DiskCacheCleaner().sweepIfNeeded(cacheDirectory: dir.path, maxSize: try size(final) + allocated)
        XCTAssertTrue(exists(part))
        XCTAssertTrue(exists(final))
    }

    func testSidecarAccessOverridesNewerModificationTime() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let older = try file(dir, "older.part", time: 500)
        let olderMeta = try sidecar(older, access: 10)
        let newer = try file(dir, "newer.part", time: 100)
        let newerMeta = try sidecar(newer, access: 20)
        DiskCacheCleaner().sweepIfNeeded(cacheDirectory: dir.path, maxSize: try size(newer) + size(newerMeta))
        XCTAssertFalse(exists(older))
        XCTAssertFalse(exists(olderMeta))
        XCTAssertTrue(exists(newer))
        XCTAssertTrue(exists(newerMeta))
    }

    func testOrphanSidecarCountsTowardBudget() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let orphan = try file(dir, "orphan.part.meta", time: 10)
        let final = try file(dir, "final", time: 20)
        DiskCacheCleaner().sweepIfNeeded(cacheDirectory: dir.path, maxSize: try size(final))
        XCTAssertFalse(exists(orphan))
        XCTAssertTrue(exists(final))
    }

    func testTemporaryGarbageIsRemovedWithoutConsumingBudget() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = try file(dir, "final", time: 10)
        let temporary = try file(dir, "legacy.tmp", time: 500)
        let orphanTemporary = try file(dir, "orphan.part.meta.tmp", time: 600)
        DiskCacheCleaner().sweepIfNeeded(cacheDirectory: dir.path, maxSize: try size(final))
        XCTAssertFalse(exists(temporary))
        XCTAssertFalse(exists(orphanTemporary))
        XCTAssertTrue(exists(final))
    }

    func testMissingDirectoryIsSilent() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var logs: [String] = []
        DiskCacheCleaner().sweepIfNeeded(cacheDirectory: dir.appendingPathComponent("missing").path,
                                         maxSize: 0, log: { logs.append($0) })
        XCTAssertTrue(logs.isEmpty)
    }

    func testCorruptSidecarFallsBackToContainerModificationTime() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let part = try file(dir, "track.part", time: 10)
        let corrupt = try file(dir, "track.part.meta", time: 500)
        let final = try file(dir, "final", time: 20)
        DiskCacheCleaner().sweepIfNeeded(cacheDirectory: dir.path, maxSize: try size(final))
        XCTAssertFalse(exists(part))
        XCTAssertFalse(exists(corrupt))
        XCTAssertTrue(exists(final))
    }

    func testEveryCallRescansAndSkipsDirectories() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("nested.part")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let child = try file(nested, "child")
        let cleaner = DiskCacheCleaner()
        cleaner.sweepIfNeeded(cacheDirectory: dir.path, maxSize: 0)
        let added = try file(dir, "added")
        cleaner.sweepIfNeeded(cacheDirectory: dir.path, maxSize: 0)
        XCTAssertFalse(exists(added))
        XCTAssertTrue(exists(child))
    }
}
