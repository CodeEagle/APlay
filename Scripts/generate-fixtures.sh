#!/bin/bash
# Regenerates every audio fixture under MacTests/Fixtures with FFmpeg.
#
# All clips are the same short sine tone, encoded once per container/codec.
# The point is format coverage, not musical content: two seconds is enough
# for AudioFileStream to parse the header and for AudioConverter to emit real
# PCM, while keeping the repo footprint small.
#
# Usage: ./Scripts/generate-fixtures.sh   (requires ffmpeg >= 4.x)
set -euo pipefail

OUT=MacTests/Fixtures
mkdir -p "$OUT"

gen() {  # gen <name> <ffmpeg -i input> <output args...>
  local name=$1; shift
  local input=$1; shift
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i "$input" "$@" "$OUT/$name"
  printf '%-14s %8s bytes\n' "$name" "$(stat -f%z "$OUT/$name")"
}

# --- MPEG audio -----------------------------------------------------------
# CBR and VBR mp3: VBR exercises the bitrate-estimation path.
gen tone-cbr.mp3 "sine=frequency=440:duration=2:sample_rate=44100" -c:a libmp3lame -b:a 32k -ac 1
gen tone-vbr.mp3 "sine=frequency=440:duration=2:sample_rate=44100" -c:a libmp3lame -q:a 5 -ac 1

# --- MPEG-4 / AAC ---------------------------------------------------------
gen tone.m4a     "sine=frequency=440:duration=2:sample_rate=44100" -c:a aac  -b:a 32k -ac 1 -movflags +faststart
gen tone-alac.m4a "sine=frequency=440:duration=2:sample_rate=44100" -c:a alac -ac 1 -movflags +faststart

# --- Raw AAC / ADTS -------------------------------------------------------
gen tone.aac     "sine=frequency=440:duration=2:sample_rate=44100" -c:a aac -b:a 32k -ac 1 -f adts

# --- WAVE / AIFF family (PCM, big- and little-endian) ---------------------
gen tone.wav     "sine=frequency=440:duration=2:sample_rate=22050" -c:a pcm_s16le -ac 1
gen tone.aiff    "sine=frequency=440:duration=2:sample_rate=22050" -c:a pcm_s16be -ac 1
# AIFF-C carrying ALAC (extension hint is .aifc).
gen tone.aifc    "sine=frequency=440:duration=2:sample_rate=44100" -c:a alac -ac 1 -f aifc

# --- Core Audio Format ----------------------------------------------------
gen tone.caf     "sine=frequency=440:duration=2:sample_rate=44100" -c:a alac -ac 1 -f caf

# --- FLAC -----------------------------------------------------------------
gen tone.flac    "sine=frequency=440:duration=2:sample_rate=44100" -c:a flac -ac 1

# --- Expected-unsupported -------------------------------------------------
# Opus in OGG: the .opus hint is recognised but Core Audio has no AudioFileStream
# opus parser, so decode must fail until an injected decoder is supplied.
gen tone.opus    "sine=frequency=440:duration=2:sample_rate=48000" -c:a libopus -b:a 32k -ac 1 -f opus

echo
echo "fixtures written to $OUT"
