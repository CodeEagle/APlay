#!/usr/bin/env python3
"""Generate a minimal, self-contained SoundFont 2 (.sf2) test bank.

One preset (bank 0 / program 0) -> one instrument -> one looping sine sample.
The point is a *loadable* SF2 that Apple's `AVAudioUnitSampler` accepts, so the
APlayMidi tests never depend on a system soundfont or a downloaded bank.

Verified against the SoundFont 2.04 spec chunk/record layouts and the
generator numbers used by FluidSynth:
  41 instrument          43 keyRange        44 velRange
  53 sampleID            54 sampleModes     58 overridingRootKey
"""
import math
import struct
import sys

SAMPLE_RATE = 44100
TONE_HZ = 220.0            # A3; an integer number of cycles fits the loop
AMPLITUDE = 16000          # 0.49 FS — headroom for summed notes
ROOT_KEY = 60              # C4


def chunk(cid: bytes, data: bytes) -> bytes:
    """A RIFF chunk, padded to an even length."""
    pad = b"\0" if len(data) % 2 else b""
    return cid + struct.pack("<I", len(data)) + data + pad


def list_chunk(form: bytes, *subs: bytes) -> bytes:
    body = form + b"".join(subs)
    return chunk(b"LIST", body)


def text_chunk(cid: bytes, text: str) -> bytes:
    raw = text.encode("ascii") + b"\0"
    return chunk(cid, raw)


def make_samples() -> bytes:
    """One second of sine; the loop boundary is click-free (whole cycles)."""
    n = SAMPLE_RATE
    return b"".join(
        struct.pack("<h", int(AMPLITUDE * math.sin(2 * math.pi * TONE_HZ * i / n)))
        for i in range(n))


def gen(oper: int, amount: int) -> bytes:
    return struct.pack("<HH", oper, amount & 0xFFFF)


def build(smpl: bytes) -> bytes:
    n_samples = len(smpl) // 2

    # --- INFO ---
    info = list_chunk(b"INFO",
                      text_chunk(b"INAM", "APlay Test Sine"),
                      text_chunk(b"ISFT", "APlay generate-soundfont.py"))

    # --- sdta ---
    sdta = list_chunk(b"sdta", chunk(b"smpl", smpl))

    # --- pdta ---
    # 1 preset + terminator. The terminator's bag index points one past the
    # last real bag, exactly as the spec requires.
    phdr = struct.pack("<20sHHHIII", b"APlay Sine\0\0\0\0\0\0\0\0", 0, 0, 0, 0, 0, 0)
    phdr += struct.pack("<20sHHHIII", b"EOS\0" + b"\0" * 16, 0, 0, 1, 0, 0, 0)

    pbag = struct.pack("<HH", 0, 0)          # preset bag: pgen[0]
    pbag += struct.pack("<HH", 1, 0)         # terminator

    pmod = b""                                # no preset modulators
    pgen = gen(41, 0)                         # instrument 0
    pgen += gen(0, 0)                         # terminator

    inst = struct.pack("<20sH", b"Sine\0\0\0\0\0\0\0\0\0\0\0", 0)
    inst += struct.pack("<20sH", b"EOI\0" + b"\0" * 16, 1)

    ibag = struct.pack("<HH", 0, 0)           # instrument bag: igen[0..4)
    ibag += struct.pack("<HH", 4, 0)          # terminator

    imod = b""                                # no instrument modulators
    # SF2 spec: if a zone carries a sampleID generator it must be the LAST
    # generator in the zone — loaders stop parsing the list there, so anything
    # after it (loop mode, root key) would be silently ignored.
    igen = gen(43, 0x7F00)                    # keyRange 0..127
    igen += gen(54, 1)                        # sampleModes: loop
    igen += gen(58, ROOT_KEY)                 # overridingRootKey
    igen += gen(53, 0)                        # sampleID 0 (also marks a real zone)
    igen += gen(0, 0)                         # terminator

    shdr = struct.pack("<20sIIIIIBbHH", b"Sine\0\0\0\0\0\0\0\0\0\0\0",
                       0, n_samples, 0, n_samples, SAMPLE_RATE,
                       ROOT_KEY, 0, 0, 1)
    shdr += struct.pack("<20sIIIIIBbHH", b"EOS\0" + b"\0" * 16,
                        n_samples, n_samples, n_samples, n_samples,
                        SAMPLE_RATE, 0, 0, 0, 0)

    pdta = list_chunk(
        b"pdta",
        chunk(b"phdr", phdr), chunk(b"pbag", pbag),
        chunk(b"pmod", pmod), chunk(b"pgen", pgen),
        chunk(b"inst", inst), chunk(b"ibag", ibag),
        chunk(b"imod", imod), chunk(b"igen", igen),
        chunk(b"shdr", shdr))

    body = b"sfbk" + info + sdta + pdta
    return b"RIFF" + struct.pack("<I", len(body)) + body


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "APlayTestSine.sf2"
    smpl = make_samples()
    data = build(smpl)
    with open(out, "wb") as f:
        f.write(data)
    print(f"wrote {out}: {len(data)} bytes "
          f"({len(smpl) // 2} samples, {len(smpl) // 2 / SAMPLE_RATE:.3f}s)")


if __name__ == "__main__":
    main()
