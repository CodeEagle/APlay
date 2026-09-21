#!/usr/bin/env python3
"""Writes MacTests/Fixtures/melody.mid

A short Standard MIDI File (format 0) used to pin `APlayMidi` playback: a
two-bar arpeggio over a held bass, at 120 BPM. Short on purpose — two seconds
is enough to prove the sequence renders real, pitched, non-silent PCM.
"""
import struct
import sys
from pathlib import Path

TICKS_PER_QUARTER = 480          # so 1 tick = 1/960 s at 120 BPM
TEMPO_US_PER_QUARTER = 500_000   # 120 BPM


def varlen(value: int) -> bytes:
    out = bytearray([value & 0x7F])
    value >>= 7
    while value:
        out.insert(0, (value & 0x7F) | 0x80)
        value >>= 7
    return bytes(out)


def event(delta: int, data: bytes) -> bytes:
    return varlen(delta) + data


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1
               else "MacTests/Fixtures/melody.mid")
    out.parent.mkdir(parents=True, exist_ok=True)

    # (start tick, duration, note, velocity)
    melody = [
        (0,    240, 72, 96),   # C5
        (240,  240, 76, 96),   # E5
        (480,  240, 79, 96),   # G5
        (720,  480, 84, 100),  # C6
        (1200, 240, 79, 96),   # G5
        (1440, 240, 76, 96),   # E5
        (1680, 240, 72, 96),   # C5
        (1920, 480, 67, 100),  # G4
        (0,    2400, 48, 80),  # C3 bass, held under everything
    ]

    timeline = []
    for start, duration, note, velocity in melody:
        timeline.append((start, bytes([0x90, note, velocity])))
        timeline.append((start + duration, bytes([0x80, note, 0])))
    timeline.append((0, bytes([0xC0, 0x00])))          # program 0 (piano)
    timeline.append((0, bytes([0xFF, 0x51, 0x03])
                     + struct.pack(">I", TEMPO_US_PER_QUARTER)[1:]))
    timeline.sort(key=lambda item: item[0])

    track = b""
    last = 0
    for tick, data in timeline:
        track += event(max(0, tick - last), data)
        last = tick
    track += event(0, b"\xFF\x2F\x00")                 # end of track

    header = b"MThd" + struct.pack(">IHHH", 6, 0, 1, TICKS_PER_QUARTER)
    body = b"MTrk" + struct.pack(">I", len(track)) + track
    out.write_bytes(header + body)
    duration = last / TICKS_PER_QUARTER * (TEMPO_US_PER_QUARTER / 1_000_000)
    print(f"wrote {out}: {len(header + body)} bytes, {last} ticks, {duration:.2f}s")


if __name__ == "__main__":
    main()
