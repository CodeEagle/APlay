#!/usr/bin/env python3
"""Rewrite the Ogg comment packet of a Speex file so it carries real tags.

FFmpeg's libspeex encoder writes the comment packet with a vendor string and
zero user fields — `-metadata` is ignored — so the fixture for `APlaySpeex`
would otherwise never exercise the decoder's comment path. This walks the Ogg
pages, replaces the second page (the comment packet, which both FFmpeg and
speexenc write alone) with one built from the fields passed on the command
line, and recomputes the page CRC. The vendor string is preserved; the comment
is written without the `[3]["vorbis"]` prefix, which is how Speex stores it.

Usage: inject-speex-comment.py <file.spx> TITLE=... ARTIST=... ALBUM=...
Idempotent: the fields replace whatever the comment packet already holds.

Not a general Ogg rewriter: it assumes the comment is the whole of page 1 and
fails loudly rather than mangling a file it does not recognise.
"""
import struct
import sys

POLY = 0x04C11DB7


def _table():
    table = []
    for i in range(256):
        crc = i << 24
        for _ in range(8):
            crc = ((crc << 1) ^ POLY) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
        table.append(crc)
    return table


TABLE = _table()


def ogg_crc(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ TABLE[((crc >> 24) & 0xFF) ^ byte]
    return crc


def parse_pages(data: bytes):
    """Yields (start, header, payload) for every Ogg page in `data`."""
    offset = 0
    while offset + 27 <= len(data) and data[offset:offset + 4] == b"OggS":
        nsegs = data[offset + 26]
        header = data[offset:offset + 27 + nsegs]
        payload_len = sum(header[27:])
        payload = data[offset + 27 + nsegs:offset + 27 + nsegs + payload_len]
        if len(payload) != payload_len:
            raise SystemExit(f"truncated page at byte {offset}")
        yield offset, header, payload
        offset += 27 + nsegs + payload_len
    if offset != len(data):
        raise SystemExit(f"trailing {len(data) - offset} bytes after the last page")


def split_vendor(payload: bytes):
    """The vendor string of a comment packet, and where the fields start."""
    if len(payload) < 4:
        raise SystemExit("comment packet is too short to hold a vendor length")
    (vendor_len,) = struct.unpack("<I", payload[:4])
    end = 4 + vendor_len
    if end > len(payload):
        raise SystemExit("vendor string runs past the end of the comment packet")
    return payload[4:end], end


def encode_segments(payload: bytes) -> bytes:
    """Ogg lacing values for `payload`: runs of 255, then a short final value.

    A packet is only delimited when a lacing value below 255 appears, so a
    payload that is an exact multiple of 255 takes a trailing zero."""
    full, remainder = divmod(len(payload), 255)
    segs = [255] * full
    segs.append(remainder if remainder or not full else 0)
    return bytes(segs)


def build_page(header: bytes, payload: bytes) -> bytes:
    """Re-issues a page around `payload`, keeping every header field but the
    lacing table and the CRC (which is zeroed, then recomputed)."""
    head = bytearray(header[:22])          # through the page sequence number
    head += b"\x00\x00\x00\x00"            # CRC field, zeroed for the checksum
    lacing = encode_segments(payload)
    head += bytes([len(lacing)]) + lacing
    crc = ogg_crc(bytes(head) + payload)
    head[22:26] = struct.pack("<I", crc)
    return bytes(head) + payload


def comment_packet(vendor: bytes, fields: list) -> bytes:
    out = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(fields))
    for field in fields:
        encoded = field.encode("utf-8")
        out += struct.pack("<I", len(encoded)) + encoded
    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    fields = sys.argv[2:]
    if not fields:
        raise SystemExit("no KEY=value fields given")

    data = open(path, "rb").read()
    pages = list(parse_pages(data))
    if len(pages) < 2:
        raise SystemExit(f"{path} has {len(pages)} pages; the comment page is missing")
    if pages[1][1][5] & 0x01:
        raise SystemExit("the comment page is a continuation page; not a layout this tool handles")

    vendor, _ = split_vendor(pages[1][2])
    packet = comment_packet(vendor, fields)

    rebuilt = bytearray()
    for index, (_, header, payload) in enumerate(pages):
        rebuilt += build_page(header, packet) if index == 1 else header + payload

    tmp = path + ".tmp"
    open(tmp, "wb").write(bytes(rebuilt))
    import os
    os.replace(tmp, path)
    print(f"{path}: comment packet now {len(packet)} bytes, {len(fields)} field(s)")


if __name__ == "__main__":
    main()
