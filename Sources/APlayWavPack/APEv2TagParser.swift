//
//  APEv2TagParser.swift
//  APlayWavPack
//
//  Reads the APEv2 trailer FFmpeg appends to a `.wv` (title / artist / album
//  and friends). The WavPack library exposes the tag through
//  `WavpackGetTagItem`, but that path touches a NULL `ape_tag_data` on files
//  that carry no tag, so the trailer is parsed here instead — the whole file
//  is already buffered by the decoder.
//
//  APEv2 layout (from the end of the file backwards):
//      [ items ... ] [ 32-byte footer ]
//  footer:  "APETAGEX" | version(4) | size(4) | itemCount(4) | flags(4) | reserved(8)
//  item:     valueSize(4) | flags(4) | key\0 | value(valueSize)
//  The footer's `size` counts the items plus the footer itself, so the items
//  run from (fileEnd - size) to (fileEnd - 32).
//

import APlay
import Foundation

enum APEv2TagParser {

    /// The text fields of the trailer, in file order. `nil` when the file has
    /// no APEv2 tag or the trailer is malformed.
    static func parse(_ data: Data) -> [MetadataParser.Item]? {
        guard data.count >= 64 else { return nil }  // footer (32) + one item
        let footerStart = data.count - 32
        guard data[footerStart..<(footerStart + 8)].elementsEqual("APETAGEX".utf8) else { return nil }

        let tagSize = littleEndian32(data, at: footerStart + 12)
        let itemCount = littleEndian32(data, at: footerStart + 16)
        guard tagSize >= 32, tagSize <= UInt32(data.count) else { return nil }

        var offset = data.count - Int(tagSize)
        var items: [MetadataParser.Item] = []
        for _ in 0..<min(itemCount, 64) {
            guard offset + 8 <= footerStart else { break }
            let valueSize = littleEndian32(data, at: offset)
            let flags = littleEndian32(data, at: offset + 4)
            offset += 8

            var keyEnd = offset
            while keyEnd < footerStart, data[keyEnd] != 0 { keyEnd += 1 }
            guard keyEnd < footerStart,
                  let key = String(bytes: data[offset..<keyEnd], encoding: .utf8) else { break }
            offset = keyEnd + 1

            guard offset + Int(valueSize) <= footerStart else { break }
            // Bits 1..2 of the flags select the item type; 0 is text.
            if (flags & 6) >> 1 == 0,
               let text = String(bytes: data[offset..<(offset + Int(valueSize))], encoding: .utf8) {
                if let item = metadataItem(key: key, value: text) {
                    items.append(item)
                }
            }
            offset += Int(valueSize)
        }
        return items
    }

    /// Maps one `KEY=value` pair onto a metadata item. Field names are
    /// case-insensitive (FFmpeg writes them title-cased, the spec upper).
    static func metadataItem(key: String, value: String) -> MetadataParser.Item? {
        switch key.uppercased() {
        case "TITLE": return .title(value)
        case "ARTIST": return .artist(value)
        case "ALBUM": return .album(value)
        case "GENRE": return .genre(value)
        case "TRACK", "TRACKNUMBER": return .track(value)
        case "YEAR", "DATE": return .year(value)
        case "COMMENT", "DESCRIPTION": return .comment(value)
        default: return .other([key.uppercased(): value])
        }
    }

    /// A little-endian UInt32 at `offset`, or 0 outside the buffer.
    private static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
