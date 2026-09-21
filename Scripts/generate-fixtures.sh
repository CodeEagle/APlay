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

# --- Optional codec libraries (APlayVorbis / APlaySpeex / APlayWavPack) ----
# Tagged so the decoders can exercise their metadata paths: the two Ogg
# files carry a Vorbis comment packet and the WavPack file an APEv2 block.
# The built-in experimental Vorbis encoder is used instead of libvorbis so the
# script runs on a stock FFmpeg; these fixtures exist for metadata and decode
# path coverage, not sound quality. libspeex still needs a full FFmpeg build.
gen tone.ogg    "sine=frequency=440:duration=2:sample_rate=44100" -c:a vorbis -strict -2 -ac 2 -metadata title="APlay Ogg/Vorbis tone" -metadata artist="APlay" -metadata album="Fixtures"
# Opus inside an Ogg container that still carries the .ogg hint: APlayVorbis
# owns the hint but libvorbis cannot open the stream, so the decoder must
# hand the URL back to the fallback (Core Audio plays Opus-in-Ogg).
gen tone-opus.ogg "sine=frequency=440:duration=2:sample_rate=48000" -c:a libopus -b:a 32k -ac 1
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libspeex; then
  gen tone.spx  "sine=frequency=440:duration=2:sample_rate=44100" -c:a libspeex -b:a 32k -ac 2 -metadata title="APlay Speex tone" -metadata artist="APlay" -metadata album="Fixtures"
else
  echo "tone.spx: this FFmpeg has no libspeex encoder; keeping the bundled file"
fi
# FFmpeg's libspeex encoder ignores -metadata and writes an empty comment
# packet, so the fields are injected straight into the Ogg pages.
python3 Scripts/inject-speex-comment.py "$OUT/tone.spx" \
  "title=APlay Speex tone" "artist=APlay" "album=Fixtures"
gen tone.wv     "sine=frequency=440:duration=2:sample_rate=22050" -c:a wavpack -ac 1 -metadata title="APlay WavPack tone" -metadata artist="APlay" -metadata album="Fixtures"

# --- Expected-unsupported -------------------------------------------------
# Opus in OGG: the .opus hint is recognised but Core Audio has no AudioFileStream
# opus parser, so decode must fail until an injected decoder is supplied.
gen tone.opus    "sine=frequency=440:duration=2:sample_rate=48000" -c:a libopus -b:a 32k -ac 1 -f opus

# --- MIDI + SoundFont (APlayMidi) ----------------------------------------
# Plain Python generators, no ffmpeg needed. melody.mid is the fixture the
# APlayMidi tests render through APlayTestSine.sf2.
python3 "$(dirname "$0")/generate-midi.py" "$OUT/melody.mid"
python3 "$(dirname "$0")/generate-soundfont.py" "$OUT/APlayTestSine.sf2"

# The demo bundles the same two files so its format matrix has a MIDI row and
# a SoundFont for the sampler to load.
cp "$OUT/melody.mid"          APlayDemo/Samples/melody.mid
cp "$OUT/APlayTestSine.sf2"   APlayDemo/Samples/APlayTestSine.sf2

echo
echo "fixtures written to $OUT"
