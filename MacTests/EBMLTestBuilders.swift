//
//  EBMLTestBuilders.swift
//
//  Shared EBML encoding helpers for the synthetic WebM/Matroska containers the
//  APlayOpus suites build. The demuxer suite has its own private builders for
//  its lacing cases; these are the ones the decoder suite needs to write a
//  container a real `OpusDecoder` can open — and to write it to a URL.
//

import Foundation
import XCTest

/// A 19-byte OpusHead: 48 kHz stereo, matching the bundled fixtures.
let testOpusHead: [UInt8] = [
    0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64,   // "OpusHead"
    0x01,                                               // version
    0x02,                                               // channels
    0x38, 0x01,                                         // pre-skip
    0x80, 0xBB, 0x00, 0x00,                             // 48000 Hz
    0x00, 0x00, 0x00,                                   // gain, mapping
]

extension XCTestCase {

    /// Writes `bytes` to a unique temporary file with `ext`, so a decoder can
    /// open a container that exists only in a test.
    func temporaryFile(_ bytes: [UInt8], _ ext: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apl-ebml-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        return url
    }

    /// The EBML header every file starts with.
    func ebmlHeader() -> [UInt8] {
        ebmlElement(0x1A45DFA3, [0x42, 0x86, 0x01,     // EBML version
                                 0x42, 0xF7, 0x01,     // read version
                                 0x42, 0x82] + Array("webm".utf8))
    }

    /// A Segment element with an unknown size — what a muxer that cannot seek
    /// back writes, so the element runs to the end of the file.
    func ebmlSegment(body: [UInt8]) -> [UInt8] {
        var element = ebmlElementID(0x18538067)
        element.append(contentsOf: [0x01] + [UInt8](repeating: 0xFF, count: 7))
        element.append(contentsOf: body)
        return element
    }

    /// A Tracks element holding one entry with `codecID`; an `A_OPUS` entry
    /// carries the OpusHead the decoder needs.
    func ebmlTracks(codecID: String, head: [UInt8] = testOpusHead) -> [UInt8] {
        var entry = ebmlElement(0x86, Array(codecID.utf8))
        if codecID == "A_OPUS" { entry.append(contentsOf: ebmlElement(0x63A2, head)) }
        return ebmlElement(0x1654AE6B, ebmlElement(0xAE, entry))
    }

    /// A Cluster element holding `packets`, one unlaced SimpleBlock each.
    func ebmlCluster(packets: [Data]) -> [UInt8] {
        var body: [UInt8] = []
        for packet in packets {
            var block: [UInt8] = [0x81, 0x00, 0x00, 0x00]   // track 1, zero timecode, no lacing
            block.append(contentsOf: packet)
            body.append(contentsOf: ebmlElement(0xA3, block))
        }
        return ebmlElement(0x1F43B675, body)
    }

    /// One element: its ID, its size, then its body.
    func ebmlElement(_ id: UInt64, _ body: [UInt8]) -> [UInt8] {
        var element = ebmlElementID(id)
        element.append(contentsOf: ebmlElementSize(body.count))
        element.append(contentsOf: body)
        return element
    }

    /// Encodes an element ID in its shortest form.
    func ebmlElementID(_ id: UInt64) -> [UInt8] {
        for length in 1...8 {
            guard id < 1 << (8 * length),
                  UInt8(truncatingIfNeeded: id >> (8 * (length - 1))) & (0x80 >> (length - 1)) != 0
            else { continue }
            return (0..<length).reversed().map { UInt8(truncatingIfNeeded: id >> (8 * $0)) }
        }
        return []
    }

    /// Encodes an element size in its shortest form.
    func ebmlElementSize(_ size: Int) -> [UInt8] {
        for length in 1...8 {
            guard size <= (1 << (8 * length - length)) - 1 else { continue }
            var bytes = (0..<length).reversed().map { index -> UInt8 in
                UInt8(truncatingIfNeeded: size >> (8 * index))
            }
            bytes[0] |= 0x80 >> (length - 1)
            return bytes
        }
        return []
    }
}
