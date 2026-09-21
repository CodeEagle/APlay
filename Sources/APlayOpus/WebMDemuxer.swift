//
//  WebMDemuxer.swift
//  APlayOpus
//
//  Pulls an Opus track out of a WebM or Matroska file. Pure Swift EBML — no
//  AudioToolbox, no vendored C — the packets it extracts are handed to Core
//  Audio's Opus decoder by `OpusDecoder`.
//
//  The container is a tree of elements: an ID (a VINT whose length comes from
//  its leading zeros), a size (a VINT of the same shape, but with the marker
//  bit excluded from the value), then the body. Only the pieces this library
//  needs are read — the `A_OPUS` track (its CodecPrivate holds the OpusHead),
//  the SimpleBlocks (Xiph-laced Opus packets) and the tags. Everything else —
//  SeekHead, Void, CRC, Cues, the whole Info block — is skipped by its
//  declared size, so a malformed child cannot desync its parent.
//

import APlay
import Foundation

/// A minimal WebM/Matroska reader for the one codec this library decodes.
enum WebMDemuxer {

    /// The `A_OPUS` track found in the file. Rate and channel count come from
    /// its OpusHead — Matroska's own `Channels`/`SamplingFrequency` agree, but
    /// the head is authoritative for Opus.
    struct Track {
        /// `"A_OPUS"` — anything else means the file is not ours.
        let codecID: String
        let head: Data
        let channels: Int
        let sampleRate: Double
    }

    /// Everything the demuxer found: the Opus track, its packets in decode
    /// order, the container's duration, and its tag fields.
    struct File {
        let track: Track?
        let packets: [Data]
        /// Seconds, from the container's `Duration` element. Zero when the
        /// container does not state one.
        let duration: Double
        let metadata: [MetadataParser.Item]
    }

    /// Walks `data` and returns the Opus track, its packets and its tags.
    /// `nil` when the bytes are not an EBML file at all.
    static func parse(_ data: Data) -> File? {
        guard data.count >= 16,
              data.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]) else { return nil }
        let walker = Walker(data: data)
        walker.walk(from: 0, to: data.count)
        return File(track: walker.track,
                    packets: walker.packets,
                    duration: walker.duration,
                    metadata: walker.metadata)
    }

    /// Reads the Opus track out of a `CodecPrivate` body.
    ///
    /// OpusHead: `"OpusHead" | version(1) | channels(1) | preSkip(2 LE)
    /// | rate(4 LE) | gain(2) | mappingFamily(1)`.
    static func opusTrack(codecID: String, head: Data?) -> Track? {
        guard let head, head.count >= 19 else { return nil }
        guard head.prefix(8) == Data("OpusHead".utf8) else { return nil }
        let channels = Int(head[9])
        let rate = UInt32(head[12])
            | (UInt32(head[13]) << 8)
            | (UInt32(head[14]) << 16)
            | (UInt32(head[15]) << 24)
        guard channels > 0, rate > 0 else { return nil }
        return Track(codecID: codecID, head: head, channels: channels, sampleRate: Double(rate))
    }

    /// Maps a Matroska tag pair onto a metadata item. FFmpeg writes the names
    /// upper-case; the comparison is case-insensitive either way.
    static func metadataItem(name: String, value: String) -> MetadataParser.Item? {
        switch name.uppercased() {
        case "TITLE": return .title(value)
        case "ARTIST": return .artist(value)
        case "ALBUM": return .album(value)
        case "GENRE": return .genre(value)
        case "TRACK", "TRACKNUMBER": return .track(value)
        case "DATE", "YEAR": return .year(value)
        case "COMMENT", "DESCRIPTION": return .comment(value)
        default:
            // ENCODER, DURATION and every private field ride along as "other"
            // so nothing the container carries is dropped.
            return .other([name.uppercased(): value])
        }
    }
}

// MARK: - Element IDs

/// The element IDs this reader descends into or reads.
private enum Element {
    static let segment: UInt64 = 0x18538067
    static let info: UInt64 = 0x1549A966
    static let timecodeScale: UInt64 = 0x2AD7B1
    static let title: UInt64 = 0x7BA9
    static let duration: UInt64 = 0x4489
    static let tracks: UInt64 = 0x1654AE6B
    static let trackEntry: UInt64 = 0xAE
    static let codecID: UInt64 = 0x86
    static let codecPrivate: UInt64 = 0x63A2
    static let cluster: UInt64 = 0x1F43B675
    static let simpleBlock: UInt64 = 0xA3
    static let blockGroup: UInt64 = 0xA0
    static let block: UInt64 = 0xA1
    static let tags: UInt64 = 0x1254C367
    static let tag: UInt64 = 0x7373
    static let simpleTag: UInt64 = 0x67C8
    static let tagName: UInt64 = 0x45A3
    static let tagString: UInt64 = 0x4487
}

/// IDs whose bodies hold more elements rather than data.
private let containerElements: [UInt64] = [
    Element.segment, Element.info, Element.tracks, Element.trackEntry,
    Element.cluster, Element.blockGroup, Element.tags, Element.tag,
    Element.simpleTag,
]

// MARK: - Walker

/// Accumulates the track, packets and tags while it walks the element tree.
private final class Walker {

    let data: Data
    var track: WebMDemuxer.Track?
    var packets: [Data] = []
    var metadata: [MetadataParser.Item] = []
    /// The `Duration`/`TimecodeScale` pair, in seconds.
    var duration: Double = 0
    /// A `TagName` waiting for its `TagString`.
    var pendingTagName: String?

    /// Fields of the `TrackEntry` currently being walked.
    var entryCodecID: String?
    var entryCodecPrivate: Data?

    init(data: Data) { self.data = data }

    /// Walks the elements in `start..<end`.
    func walk(from start: Int, to end: Int) {
        var offset = start
        while offset < end {
            guard let (id, afterID) = readID(at: offset, limit: end) else { return }
            guard let (size, afterSize, toEnd) = readSize(at: afterID, limit: end) else { return }
            let bodyEnd = (toEnd || size > end - afterSize) ? end : afterSize + size
            handle(id: id, body: afterSize..<bodyEnd)
            offset = bodyEnd
        }
    }

    /// Reads one element's body.
    func handle(id: UInt64, body: Range<Int>) {
        if containerElements.contains(id) {
            if id == Element.trackEntry {
                // A file can carry several tracks; only the first Opus one is
                // kept, so its fields are scoped to this entry.
                let savedID = entryCodecID
                let savedPrivate = entryCodecPrivate
                entryCodecID = nil
                entryCodecPrivate = nil
                walk(from: body.lowerBound, to: body.upperBound)
                if track == nil, let codecID = entryCodecID, codecID == "A_OPUS" {
                    track = WebMDemuxer.opusTrack(codecID: codecID, head: entryCodecPrivate)
                }
                entryCodecID = savedID
                entryCodecPrivate = savedPrivate
            } else {
                walk(from: body.lowerBound, to: body.upperBound)
            }
            return
        }
        switch id {
        case Element.codecID:
            entryCodecID = string(body)
        case Element.codecPrivate:
            entryCodecPrivate = data.subdata(in: body)
        case Element.title:
            // The container-level Title holds what ffmpeg writes for
            // `-metadata title=`; artist and album live in Tags.
            if let value = string(body) { metadata.append(.title(value)) }
        case Element.timecodeScale:
            // Nanoseconds per tick; the default is 1 ms.
            duration = Double(unsigned(body)) / 1_000_000_000
        case Element.duration:
            // Ticks, so the scale has to be seen first — Info orders them that
            // way, and a missing scale leaves this at zero.
            if duration > 0 { duration *= Double(float64(body)) }
        case Element.simpleBlock, Element.block:
            packets.append(contentsOf: splitBlock(body))
        case Element.tagName:
            pendingTagName = string(body)
        case Element.tagString:
            if let name = pendingTagName, let value = string(body),
               let item = WebMDemuxer.metadataItem(name: name, value: value) {
                metadata.append(item)
            }
            pendingTagName = nil
        default:
            break   // skipped by size
        }
    }

    // MARK: - Blocks

    /// Splits a SimpleBlock/Block body into its Opus packets.
    ///
    /// body: `trackNumber(VINT) | timecode(int16 BE) | flags(1B) | frames`.
    /// flags bits 1-2 select the lacing: 0 = a single frame, 1 = Xiph sizes,
    /// 2 = equal sizes. Xiph sizes chain `0xFF` bytes; the last frame is
    /// whatever the body has left.
    func splitBlock(_ body: Range<Int>) -> [Data] {
        var offset = body.lowerBound
        guard let (_, afterTrack) = readID(at: offset, limit: body.upperBound) else { return [] }
        offset = afterTrack
        guard offset + 3 <= body.upperBound else { return [] }   // timecode + flags
        offset += 2                                              // cluster-relative
        let flags = data[offset]
        offset += 1
        switch (flags >> 1) & 0x3 {
        case 0:
            guard offset < body.upperBound else { return [] }
            return [data.subdata(in: offset..<body.upperBound)]
        case 1:
            guard offset < body.upperBound else { return [] }
            let frameCount = Int(data[offset]) + 1
            offset += 1
            var sizes: [Int] = []
            for _ in 0..<max(frameCount - 1, 0) {
                var size = 0
                while offset < body.upperBound, data[offset] == 0xFF {
                    size += 255
                    offset += 1
                }
                guard offset < body.upperBound else { return [] }
                size += Int(data[offset])
                offset += 1
                sizes.append(size)
            }
            // The last frame is whatever the body has left once the declared
            // frames are paid for.
            let last = (body.upperBound - offset) - sizes.reduce(0, +)
            guard last >= 0 else { return [] }
            sizes.append(last)
            // The sizes sum to the payload, so every slice is in bounds.
            return sizes.map { size in
                let packet = data.subdata(in: offset..<(offset + size))
                offset += size
                return packet
            }
        case 2:
            guard offset < body.upperBound else { return [] }
            let frameCount = Int(data[offset]) + 1
            offset += 1
            let remaining = body.upperBound - offset
            guard remaining % frameCount == 0 else { return [] }
            let size = remaining / frameCount
            return (0..<frameCount).map { index in
                data.subdata(in: (offset + index * size)..<(offset + (index + 1) * size))
            }
        default:
            return []   // reserved lacing: not a valid Opus block
        }
    }

    // MARK: - Primitives

    /// Reads an element ID — the raw bytes, marker bit included — and returns
    /// it with the offset just past it.
    func readID(at offset: Int, limit: Int) -> (UInt64, Int)? {
        guard offset < limit else { return nil }
        let first = data[offset]
        // A zero byte is never a VINT, so it ends the scope instead.
        guard first != 0, let length = vintLength(first) else { return nil }
        guard offset + length <= limit else { return nil }
        var id: UInt64 = 0
        for index in 0..<length {
            id = (id << 8) | UInt64(data[offset + index])
        }
        return (id, offset + length)
    }

    /// Reads an element size and returns it with the offset just past it. The
    /// value is the first byte's data bits — the marker bit excluded — followed
    /// by the remaining bytes big-endian. An all-ones 8-byte size means
    /// "unknown", reported as `toEnd` so the element runs to the scope's end.
    func readSize(at offset: Int, limit: Int) -> (size: Int, after: Int, toEnd: Bool)? {
        guard offset < limit else { return nil }
        guard let length = vintLength(data[offset]) else { return nil }
        guard offset + length <= limit else { return nil }
        var value = UInt64(data[offset] & (0xFF >> length))
        for index in 1..<length {
            value = (value << 8) | UInt64(data[offset + index])
        }
        // Segment often declares no size; the element ends with its scope.
        let unknown = length == 8 && value == (1 << 56) - 1
        return (unknown ? 0 : Int(truncatingIfNeeded: value), offset + length, unknown)
    }

    /// The VINT length a leading byte implies (1-8), or nil for a zero byte.
    func vintLength(_ first: UInt8) -> Int? {
        for bit in 0..<8 where first & (0x80 >> bit) != 0 { return bit + 1 }
        return nil
    }

    /// The UTF-8 text of a body, with the NUL padding some fields carry.
    func string(_ body: Range<Int>) -> String? {
        guard body.lowerBound < body.upperBound else { return nil }
        var bytes = data.subdata(in: body)
        while let last = bytes.last, last == 0 { bytes = bytes.prefix(bytes.count - 1) }
        return String(data: bytes, encoding: .utf8)
    }

    /// A big-endian unsigned integer of up to 8 bytes.
    func unsigned(_ body: Range<Int>) -> UInt64 {
        var value: UInt64 = 0
        for byte in data.subdata(in: body) { value = (value << 8) | UInt64(byte) }
        return value
    }

    /// A big-endian Float64.
    func float64(_ body: Range<Int>) -> Double {
        guard body.count >= 8 else { return 0 }
        let bits = unsigned(body)
        return Double(bitPattern: bits)
    }
}
