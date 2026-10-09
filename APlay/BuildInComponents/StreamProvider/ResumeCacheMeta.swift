//
//  ResumeCacheMeta.swift
//  APlay
//
//  The on-disk progress table for resumable remote streams.
//
//  A remote track is downloaded straight into its final-sized local container
//  (`<name>.part`, preallocated with `ftruncate`), and every chunk the network
//  delivers is written at its absolute offset. Which offsets already hold real
//  audio — and which are still sparse holes a reader must not enter — is what
//  this file records, alongside the validators that let the server tell us the
//  content has not changed since the download was interrupted.
//

import Foundation

/// The bit set `ResumeCacheMeta` persists: bit `i` is set when block `i` of the
/// container holds downloaded bytes. Kept as a plain `Data` so it serialises in
/// place, with no bridging.
///
/// A set bit means the whole block is on disk — the read loop treats a set bit
/// as permission to serve those bytes straight from the container, so a block
/// marked on a partial write would feed a sparse-file hole to the decoder. A
/// block is therefore credited only once every byte of it (up to
/// `containerLength`) has been written, and the bytes a write brings to a block
/// that does not yet fill it are held in `partial` until a later chunk completes
/// it — a URL session delivers the body in chunks of whatever size it likes, so
/// block boundaries are rarely chunk boundaries.
struct ResumeCacheBitmap {
    /// Bytes per block. Matches the local read loop's 8 KB read size, so a
    /// "downloaded" verdict is always made on exactly the span a reader pulls.
    static let defaultBlockSize: UInt32 = 8192

    private(set) var storage: Data
    let blockSize: UInt32
    let blockCount: Int
    /// The container's real length (`contentLength`); the final block ends here
    /// even when `blockCount * blockSize` overshoots it.
    let containerLength: UInt64
    /// Bytes confirmed written to each block that is not complete yet. Held in
    /// memory only: a restarted stream drops these and simply re-fetches the
    /// block, so the persisted table never claims bytes the file does not hold.
    var partial: [Int: UInt64] = [:]

    init(blockSize: UInt32 = ResumeCacheBitmap.defaultBlockSize, containerLength: UInt64) {
        self.blockSize = max(blockSize, 1)
        self.containerLength = containerLength
        blockCount = containerLength > 0
            ? Int((containerLength + UInt64(self.blockSize) - 1) / UInt64(self.blockSize))
            : 0
        storage = Data(count: (blockCount + 7) / 8)
    }

    init(storage: Data, blockSize: UInt32, containerLength: UInt64) {
        self.storage = storage
        self.blockSize = max(blockSize, 1)
        self.containerLength = containerLength
        blockCount = containerLength > 0
            ? Int((containerLength + UInt64(self.blockSize) - 1) / UInt64(self.blockSize))
            : 0
    }

    /// Absolute byte offset → its block index.
    @inline(__always)
    private func block(of offset: UInt64) -> Int {
        return Int(offset / UInt64(blockSize))
    }

    @inline(__always)
    private func isSet(_ index: Int) -> Bool {
        return storage[index / 8] & (0x80 >> (index % 8)) != 0
    }

    @inline(__always)
    private mutating func setBit(_ index: Int) {
        storage[index / 8] |= 0x80 >> (index % 8)
    }

    /// Whether the block covering `offset` is fully downloaded. An offset at or
    /// past the container end has no block, so it is not reported as present:
    /// the read loop treats that as end-of-file on its own.
    func contains(offset: UInt64) -> Bool {
        let index = block(of: offset)
        guard index < blockCount else { return false }
        return isSet(index)
    }

    /// Records `[offset, offset + length)` as written and returns how many bytes
    /// landed in blocks this call completed. Writes are expected to be disjoint
    /// — the range a gap fill covers is never re-requested — so a block's partial
    /// tally is the union of the spans written to it; overlapping writes would
    /// double count and could mark a block early.
    @discardableResult
    mutating func mark(offset: UInt64, length: UInt64) -> UInt64 {
        guard length > 0, blockSize > 0 else { return 0 }
        let end = min(offset &+ length, containerLength)
        guard offset < end else { return 0 }

        var newly: UInt64 = 0
        var position = offset
        while position < end {
            let index = block(of: position)
            guard index < blockCount else { break }

            let blockStart = UInt64(index) &* UInt64(blockSize)
            let blockEnd = min(blockStart &+ UInt64(blockSize), containerLength)
            let size = blockEnd &- blockStart

            if isSet(index) {
                // Already credited by an earlier write.
                position = blockEnd
                continue
            }

            let span = min(end, blockEnd) &- position
            let covered = min(partial[index, default: 0] &+ span, size)
            if covered >= size {
                setBit(index)
                partial.removeValue(forKey: index)
                newly += size
            } else {
                partial[index] = covered
            }
            position = blockEnd
        }
        return newly
    }

    /// Every block set. A container whose whole span is downloaded is promoted
    /// to the plain cache path and needs this table no longer.
    var isComplete: Bool {
        guard blockCount > 0 else { return false }
        let fullBlocks = blockCount / 8
        if fullBlocks > 0, storage.prefix(fullBlocks).contains(where: { $0 != 0xFF }) { return false }
        let tail = blockCount % 8
        guard tail > 0 else { return true }
        let mask: UInt8 = 0xFF << (8 - tail)
        return storage[fullBlocks] & mask == mask
    }

    /// The offset a resumed download asks the server for: the start of the first
    /// block the table does not vouch for. Blocks are marked only when whole, so
    /// this is the earliest byte that may still be a sparse hole.
    var firstMissingOffset: UInt64 {
        guard blockCount > 0 else { return 0 }
        for index in 0 ..< blockCount where isSet(index) == false {
            return UInt64(index) &* UInt64(blockSize)
        }
        return min(UInt64(blockCount) &* UInt64(blockSize), containerLength)
    }
}

/// The sidecar written next to `<name>.part`.
///
/// Layout (big-endian, version-tagged so a future format is detected instead of
/// misread):
///
///     magic          8 bytes   "APLAYPCM"
///     version        UInt16    1
///     blockSize      UInt32
///     contentLength  UInt64
///     downloaded     UInt64
///     lastAccess     Float64
///     etagLen        UInt16 + etag bytes
///     modLen         UInt16 + Last-Modified bytes
///     urlLen         UInt16 + origin URL bytes
///     bitmapLen      UInt32 + bitmap bytes
struct ResumeCacheMeta {
    static let magic = "APLAYPCM".data(using: .utf8)!
    static let version: UInt16 = 1

    let blockSize: UInt32
    let contentLength: UInt64
    let originURL: URL
    var etag: String?
    var lastModified: String?
    var bitmap: ResumeCacheBitmap
    /// Wall-clock time of the last download into this container, for the
    /// least-recently-used sweep that keeps partial files under
    /// `maxDiskCacheSize`.
    var lastAccess: TimeInterval

    init(blockSize: UInt32 = ResumeCacheBitmap.defaultBlockSize,
         contentLength: UInt64,
         originURL: URL,
         etag: String? = nil,
         lastModified: String? = nil) {
        self.blockSize = max(blockSize, 1)
        self.contentLength = contentLength
        self.originURL = originURL
        self.etag = etag
        self.lastModified = lastModified
        bitmap = ResumeCacheBitmap(blockSize: self.blockSize, containerLength: contentLength)
        lastAccess = Date().timeIntervalSince1970
    }

    /// Number of bytes the bitmap reports as downloaded.
    var downloadedBytes: UInt64 {
        guard bitmap.blockCount > 0 else { return 0 }
        var total: UInt64 = 0
        for index in 0 ..< bitmap.blockCount where bitmap.contains(offset: UInt64(index) * UInt64(bitmap.blockSize)) {
            let blockStart = UInt64(index) * UInt64(bitmap.blockSize)
            total += min(UInt64(bitmap.blockSize), contentLength &- blockStart)
        }
        return total
    }

    var isComplete: Bool {
        guard contentLength > 0 else { return false }
        return downloadedBytes >= contentLength
    }

    /// The header value to send as `If-Range`: an ETag is the stronger
    /// validator, `Last-Modified` the fallback. `nil` when the server gave us
    /// neither, in which case the range request goes out unvalidated.
    var ifRangeValue: String? {
        if let etag, etag.isEmpty == false { return etag }
        return lastModified
    }

    // MARK: - Encoding

    func encoded() -> Data {
        var data = Data()
        data.append(Self.magic)
        data.append(uint16: Self.version)
        data.append(uint32: blockSize)
        data.append(uint64: contentLength)
        data.append(uint64: downloadedBytes)
        data.append(float64: lastAccess)
        data.append(lengthPrefixed: etag?.data(using: .utf8))
        data.append(lengthPrefixed: lastModified?.data(using: .utf8))
        data.append(lengthPrefixed: originURL.absoluteString.data(using: .utf8))
        data.append(uint32: UInt32(bitmap.storage.count))
        data.append(bitmap.storage)
        return data
    }

    static func decode(from data: Data) -> ResumeCacheMeta? {
        guard data.count >= 8 + 2 + 4 + 8 + 8 + 8 else { return nil }
        var reader = ByteReader(data: data)
        guard reader.bytes(8) == magic else { return nil }
        let version = reader.uint16()
        guard version == Self.version else { return nil }
        let blockSize = reader.uint32()
        let contentLength = reader.uint64()
        _ = reader.uint64()              // downloadedBytes is derived from the bitmap
        let lastAccess = reader.float64()
        let etag = reader.lengthPrefixedString()
        let lastModified = reader.lengthPrefixedString()
        guard let urlBytes = reader.lengthPrefixed(),
              let urlString = String(data: urlBytes, encoding: .utf8),
              let originURL = URL(string: urlString) else { return nil }
        let bitmapLength = Int(reader.uint32())
        guard bitmapLength >= 0,
              reader.remaining >= bitmapLength else { return nil }
        let storage = reader.bytes(bitmapLength)

        guard blockSize > 0 else { return nil }
        var meta = ResumeCacheMeta(blockSize: blockSize,
                                   contentLength: contentLength,
                                   originURL: originURL,
                                   etag: etag,
                                   lastModified: lastModified)
        // The table must cover exactly the blocks the content length implies —
        // a short bitmap would shift every block verdict by a byte.
        guard storage.count == meta.bitmap.storage.count else { return nil }
        meta.bitmap = ResumeCacheBitmap(storage: storage,
                                        blockSize: blockSize,
                                        containerLength: contentLength)
        meta.lastAccess = lastAccess
        return meta
    }

    /// Writes this table next to `containerURL` (same path, `.meta` extension)
    /// through a temp file so a crash mid-write leaves the previous table
    /// intact rather than a truncated one.
    @discardableResult
    func atomicWrite(nextTo containerURL: URL) -> Bool {
        let metaURL = containerURL.appendingPathExtension("meta")
        let tmp = metaURL.appendingPathExtension("tmp")
        do {
            try encoded().write(to: tmp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: metaURL)
            try FileManager.default.moveItem(at: tmp, to: metaURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    static func load(nextTo containerURL: URL) -> ResumeCacheMeta? {
        let metaURL = containerURL.appendingPathExtension("meta")
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return decode(from: data)
    }
}

// MARK: - Byte-level read/write

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8((value >> 8) & 0xFF)); append(UInt8(value & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8((value >> 24) & 0xFF)); append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF)); append(UInt8(value & 0xFF))
    }

    mutating func append(uint64 value: UInt64) {
        append(uint32: UInt32(value >> 32)); append(uint32: UInt32(value & 0xFFFFFFFF))
    }

    mutating func append(float64 value: Double) {
        append(uint64: value.bitPattern)
    }

    /// A UInt16-length prefix, so an absent field is "0" rather than a sentinel.
    mutating func append(lengthPrefixed bytes: Data?) {
        let bytes = bytes ?? Data()
        append(uint16: UInt16(Swift.min(bytes.count, 0xFFFF)))
        append(bytes)
    }
}

private struct ByteReader {
    let data: Data
    private(set) var offset: Int = 0

    var remaining: Int { data.count - offset }

    @inline(__always)
    mutating func bytes(_ count: Int) -> Data {
        let end = min(offset + count, data.count)
        let chunk = data.subdata(in: offset ..< end)
        offset = end
        return chunk
    }

    mutating func uint16() -> UInt16 {
        guard remaining >= 2 else { return 0 }
        let value = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2
        return value
    }

    mutating func uint32() -> UInt32 {
        guard remaining >= 4 else { return 0 }
        var value: UInt32 = 0
        for index in offset ..< offset + 4 { value = value << 8 | UInt32(data[index]) }
        offset += 4
        return value
    }

    mutating func uint64() -> UInt64 {
        let high = UInt64(uint32()); let low = UInt64(uint32())
        return high << 32 | low
    }

    mutating func float64() -> Double {
        Double(bitPattern: uint64())
    }

    mutating func lengthPrefixed() -> Data? {
        let length = Int(uint16())
        guard remaining >= length else { return length == 0 ? Data() : nil }
        return bytes(length)
    }

    mutating func lengthPrefixedString() -> String? {
        guard let bytes = lengthPrefixed(), bytes.isEmpty == false else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
