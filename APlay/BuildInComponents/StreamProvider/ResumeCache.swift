//
//  ResumeCache.swift
//  APlay
//
//  The write side of resumable remote playback.
//
//  A remote track is laid out in a preallocated container (`<name>.part`) the
//  moment its length is known, and every chunk the network delivers is written
//  at its absolute offset. `ResumeCacheMeta` remembers which blocks hold real
//  bytes; this class owns the container's file handle, advances the write
//  cursor, and keeps the table on disk current — everything the read loop and
//  the reconnect watchdog need to treat a half-empty file as a playable one.
//

import Foundation

/// The container plus its progress table for one remote track.
///
/// Both the URLSession delegate callbacks (`_stateQueue`) and the local read
/// loop (`_readQueue`) reach in: the writer marks blocks, the reader asks
/// whether the block ahead is real. Every accessor goes through `lock`, so the
/// two never race over the cursor or the table.
final class ResumeCache: @unchecked Sendable {
    let containerURL: URL
    let originURL: URL
    /// Where the container lands once every block is real, i.e. the plain cache
    /// path the next open finds as a full hit.
    let finalURL: URL

    private let lock = NSLock()
    private var _meta: ResumeCacheMeta
    private var _handle: UnsafeMutablePointer<FILE>?
    /// Absolute offset in the container where the active download writes next.
    private var _writeOffset: UInt64 = 0
    private var _lastFlush = Date.distantPast

    /// Throttles table flushes: a block closes on every 8 KB, and the sidecar
    /// is only needed across process restarts, so a stale-by-one-block table
    /// costs at most one re-fetched block.
    private static let flushInterval: TimeInterval = 0.5

    private init(containerURL: URL, originURL: URL, finalURL: URL, meta: ResumeCacheMeta) {
        self.containerURL = containerURL
        self.originURL = originURL
        self.finalURL = finalURL
        _meta = meta
    }

    deinit {
        if let handle = _handle { fclose(handle) }
    }

    // MARK: - Opening

    /// Creates a fresh, fully sized container for a download about to start.
    /// Preallocation is what makes every write positional, and the file is
    /// sparse, so the up-front cost is metadata rather than disk.
    static func create(name: String,
                       cacheDirectory: String,
                       originURL: URL,
                       blockSize: UInt32 = ResumeCacheBitmap.defaultBlockSize,
                       contentLength: UInt64,
                       etag: String?,
                       lastModified: String?) -> ResumeCache? {
        guard contentLength > 0 else { return nil }
        let directory = URL(fileURLWithPath: cacheDirectory)
        let container = directory.appendingPathComponent("\(name).part")
        guard let handle = openWriteHandle(at: container, length: contentLength, truncate: true) else { return nil }
        // A table left by an earlier container of the same name would describe
        // bytes this one has not written; drop it rather than mislead a restart.
        try? FileManager.default.removeItem(at: container.appendingPathExtension("meta"))

        let cache = ResumeCache(containerURL: container,
                                originURL: originURL,
                                finalURL: directory.appendingPathComponent(name),
                                meta: ResumeCacheMeta(blockSize: blockSize,
                                                      contentLength: contentLength,
                                                      originURL: originURL,
                                                      etag: etag,
                                                      lastModified: lastModified))
        cache._handle = handle
        cache.flushMetaLocked()
        return cache
    }

    /// Reopens a container that a previous session left partly filled, so the
    /// download picks up at the first block the table does not vouch for.
    /// Returns `nil` when there is no table, or when the table belongs to a
    /// different source: the bytes are not this track's.
    static func open(name: String,
                     cacheDirectory: String,
                     expectedOriginURL url: URL) -> ResumeCache? {
        let directory = URL(fileURLWithPath: cacheDirectory)
        let container = directory.appendingPathComponent("\(name).part")
        guard let meta = ResumeCacheMeta.load(nextTo: container), meta.originURL == url else { return nil }
        guard let handle = openWriteHandle(at: container, length: meta.contentLength, truncate: false) else { return nil }

        let cache = ResumeCache(containerURL: container,
                                originURL: meta.originURL,
                                finalURL: directory.appendingPathComponent(name),
                                meta: meta)
        cache._handle = handle
        return cache
    }

    private static func openWriteHandle(at url: URL, length: UInt64, truncate: Bool) -> UnsafeMutablePointer<FILE>? {
        // `w+` truncates, which a fresh container wants; `r+b` keeps the bytes a
        // previous session wrote, which a resumed one depends on.
        guard let handle = fopen(url.path, truncate ? "w+" : "r+b") else { return nil }
        guard ftruncate(fileno(handle), off_t(length)) == 0 else {
            fclose(handle)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return handle
    }

    // MARK: - State the streamer reads

    var contentLength: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _meta.contentLength
    }

    /// The `If-Range` value for the request that tops this container up: an
    /// ETag wins over `Last-Modified`, and `nil` means the server gave neither,
    /// so the range goes out unvalidated and a changed body shows up as a 200.
    var ifRangeValue: String? {
        lock.lock(); defer { lock.unlock() }
        return _meta.ifRangeValue
    }

    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return _meta.isComplete
    }

    var downloadedBytes: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _meta.downloadedBytes
    }

    /// Absolute offset the active download writes next; the reconnect watchdog
    /// resumes from here, and the read loop uses it to tell a hole that is
    /// about to be filled from one nothing is fetching.
    var writeOffset: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _writeOffset
    }

    func setWriteOffset(_ offset: UInt64) {
        lock.lock(); _writeOffset = offset; lock.unlock()
    }

    /// Offset of the first byte the table does not vouch for — where a resumed
    /// download asks the server to start.
    func firstMissingOffset() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _meta.bitmap.firstMissingOffset
    }

    /// Whether the block covering `offset` is whole on disk. The read loop asks
    /// before every pull, so a `true` answer is a promise the bytes are there.
    func bitmapContains(offset: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _meta.bitmap.contains(offset: offset)
    }

    // MARK: - Writing

    /// Writes a chunk at the cursor, marks the blocks it closes, and keeps the
    /// table fresh enough to survive a crash. Returns the bytes credited to
    /// blocks this call completed.
    @discardableResult
    func write(bytes pointer: UnsafeRawPointer, count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        lock.lock(); defer { lock.unlock() }
        guard let handle = _handle else { return 0 }

        let offset = _writeOffset
        guard fseeko(handle, off_t(offset), SEEK_SET) == 0 else { return 0 }
        let written = fwrite(pointer, 1, count, handle)
        guard written == count else { return 0 }
        // The read loop shares the container through its own descriptor, so the
        // bytes must leave this stream's buffer before they can be served.
        fflush(handle)
        _writeOffset = offset &+ UInt64(count)

        let credited = _meta.bitmap.mark(offset: offset, length: UInt64(count))
        if credited > 0 {
            _meta.lastAccess = Date().timeIntervalSince1970
            flushMetaLocked()
        }
        return credited
    }

    /// Records the validators a response just handed over. They are collected
    /// only when the caller's policy asks for them, so a table that predates
    /// them still validates through `Last-Modified` if it has one.
    func setValidators(etag: String?, lastModified: String?) {
        lock.lock(); defer { lock.unlock() }
        _meta.etag = etag
        _meta.lastModified = lastModified
    }

    /// Resets the table to an empty container for a body the server replaced
    /// out from under us (a 200 after we asked for a range).
    ///
    /// The container is not torn down: the old bytes stay put until the new
    /// download overwrites them, and the fresh table makes the stale tail
    /// invisible to the reader and to promotion. Tearing it down instead would
    /// truncate a file the read loop may be mid-pull from.
    func restart(contentLength: UInt64, etag: String?, lastModified: String?) {
        lock.lock(); defer { lock.unlock() }
        guard contentLength > 0 else { return }
        if contentLength != _meta.contentLength, let handle = _handle {
            ftruncate(fileno(handle), off_t(contentLength))
        }
        _meta = ResumeCacheMeta(blockSize: _meta.blockSize,
                                contentLength: contentLength,
                                originURL: originURL,
                                etag: etag,
                                lastModified: lastModified)
        _writeOffset = 0
        flushMetaLocked()
    }

    // MARK: - Table persistence

    /// Forces the table to disk; called on every tear-down so a pause or an
    /// error still leaves the progress durable.
    func flushMeta() {
        lock.lock(); defer { lock.unlock() }
        flushMetaLocked()
    }

    private func flushMetaLocked() {
        let now = Date()
        guard now.timeIntervalSince(_lastFlush) > Self.flushInterval else { return }
        _lastFlush = now
        _meta.lastAccess = now.timeIntervalSince1970
        _meta.atomicWrite(nextTo: containerURL)
    }

    /// Closes the write handle. The read loop's descriptor is its own, so it
    /// keeps serving the container.
    func close() {
        lock.lock(); defer { lock.unlock() }
        flushMetaLocked()
        if let handle = _handle { fclose(handle); _handle = nil }
    }

    /// Every block is real, so the container is indistinguishable from a
    /// completed download: move it to the plain cache path and drop the table.
    /// Returns the final URL on success.
    @discardableResult
    func promote() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _meta.isComplete else { return false }
        if let handle = _handle { fclose(handle); _handle = nil }
        do {
            try FileManager.default.moveItem(at: containerURL, to: finalURL)
        } catch {
            // A sweep or a stale entry may already hold the name; replace it so
            // the newest completion wins.
            try? FileManager.default.removeItem(at: finalURL)
            do { try FileManager.default.moveItem(at: containerURL, to: finalURL) }
            catch { return false }
        }
        try? FileManager.default.removeItem(at: containerURL.appendingPathExtension("meta"))
        return true
    }
}
