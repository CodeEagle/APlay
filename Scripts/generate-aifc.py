#!/usr/bin/env python3
"""Writes MacTests/Fixtures/tone.aifc

FFmpeg (8.x) ships no AIFC muxer, but AIFF-C is a trivial wrap of big-endian
PCM: it is an AIFF with FORM type 'AIFC', a FVER chunk, and a compressionType
of 'twos' (signed big-endian) in COMM. Core Audio parses it natively, so this
is what pins the .aifc row of the compatibility table.
"""
import math
import struct
import sys
from pathlib import Path

SAMPLE_RATE = 44100
DURATION = 2.0
FREQUENCY = 440.0

out = Path(sys.argv[1] if len(sys.argv) > 1 else "MacTests/Fixtures/tone.aifc")
out.parent.mkdir(parents=True, exist_ok=True)

n_frames = int(SAMPLE_RATE * DURATION)
samples = []
for i in range(n_frames):
    v = math.sin(2 * math.pi * FREQUENCY * i / SAMPLE_RATE)
    samples.append(int(max(-1.0, min(1.0, v)) * 32000))
pcm = struct.pack(">%dh" % len(samples), *samples)


def extended(value: int) -> bytes:
    """80-bit big-endian IEEE extended for a positive integer."""
    e = value.bit_length() - 1
    mantissa = value << (63 - e)
    return ((e + 16383) << 64 | mantissa).to_bytes(10, "big")


def chunk(tag: bytes, body: bytes) -> bytes:
    assert len(tag) == 4
    data = tag + struct.pack(">I", len(body)) + body
    return data + b"\x00" if len(body) % 2 else data  # pad to even


fver = chunk(b"FVER", struct.pack(">I", 0xA2805140))  # AIFCFormatVersion 1.0
comm_body = (
    struct.pack(">HIH", 1, n_frames, 16)  # channels, frames, bits
    + extended(SAMPLE_RATE)
    + b"twos"  # compressionType: signed big-endian PCM
    + b"\x00"  # compressionName: empty pstring
)
comm = chunk(b"COMM", comm_body)
ssnd = chunk(b"SSND", struct.pack(">II", 0, 0) + pcm)  # offset, blockSize, data

body = b"AIFC" + fver + comm + ssnd
out.write_bytes(chunk(b"FORM", body))
print(f"{out.name:14} {out.stat().st_size:8} bytes")
