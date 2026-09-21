APlay
---
A Better(Maybe) iOS Audio Stream & Play Swift Framework

Requirements
---
- iOS 15.0+
- Swift 6.0+ (Xcode 16+ toolchain)

Installation
---
[Swift Package Manager](https://swift.org/package-manager/) is the only supported way to
add APlay — there is no CocoaPods spec and no Carthage support:

```Swift
.package(url: "https://github.com/CodeEagle/APlay.git", from: "2.1.2")
```

Add the `APlay` product to your app target. Supported platforms: macOS 12+, iOS 15+,
tvOS 15+, visionOS 1+. The same `Package.swift` also builds the `APlayMacPlayback`
end-to-end validation target and the `APlayTests` suite on macOS, so `swift build` and
`swift test` are the single source of truth for the framework.

Optional codec libraries ship as separate products — add them only when you need the
formats they bring; plain `APlay` is unchanged:

```Swift
.product(name: "APlayExtras", package: "APlay")   // CAF / AIFF / AU / 3GP / Wave64
.product(name: "APlayWavPack", package: "APlay")  // .wv
.product(name: "APlayVorbis", package: "APlay")   // .ogg
.product(name: "APlaySpeex", package: "APlay")    // .spx
.product(name: "APlayOpus", package: "APlay")   // .webm / .mka
.product(name: "APlayMidi", package: "APlay")     // .mid / .midi / .kar
```

Usage
---
```Swift
import APlay
...
let url = URL(string: "path/to/audio/resource")!
let player = APlay()
player.eventPipeline.delegate(to: self, with: { (target, event) in
    //  event handling
})
player.play(url)
...
```

A track can be preloaded with `prepare(_:)` — the streamer and decoder buffer the audio
without starting the output audio unit, so a later `play(_:)` of the same URL starts
instantly from the filled ring buffer.

> ℹ️ Plain `http://` streams: iOS blocks non-HTTPS URLs via App Transport Security by
> default. Add an `NSAllowsArbitraryLoads` (or a per-domain) exception to your app's
> `Info.plist` if your stream URL is `http://...` — this is the most common cause of
> "cannot play HTTP stream".

Equalizer
---
An `AVAudioUnitEQ` runs in the render chain, one band per entry of
`Configuration.equalizerBandFrequencies` (8 by default: 50 / 100 / 200 / 400 / 800 /
1600 / 2600 / 16000 Hz). The first band is a low shelf, the last a high shelf, the rest
parametric. Gains apply at runtime without restarting playback:

```Swift
let player = APlay()

// A bundled preset — flat / rock / pop / jazz / classical / bassBoost /
// trebleBoost / vocal / electronic / acoustic.
player.applyEqualizerPreset(.rock)

// Or a single band, clamped to the audio unit's -96...24 dB range.
player.setEqualizerBandGain(3.5, at: 2)

// Read the current curve back.
let gains: [Float] = player.equalizerGains

// Or your own curve — a band count that differs from the configuration's
// frequencies is ignored (and logged), never silently shifted.
let curve = EqualizerPreset(name: "My Curve", gains: [4, 3, 2, 1, 0, 1, 2, 3])
player.applyEqualizerPreset(curve)
```

Gapless playback
---
With `gaplessPlaybackEnabled` the next track is preloaded while the current one still
plays, and at the end of the track the output audio unit swaps in the buffered source
without stopping — no gap and no `.paused` state at the handoff:

```Swift
let player = APlay(configuration: APlay.Configuration(gaplessPlaybackEnabled: true))
player.loopPattern = .stopWhenAllPlayed(.order)
player.play([first, second, third])
```

A handoff between *different* audio formats (MP3 → FLAC, say) still re-initializes the
graph and is not seamless.

AirPlay 2 and remote control
---
The audio session runs the `.playback` category with the `longFormAudio` route sharing
policy — the combination AirPlay 2 expects — and the lock screen, Control Center and
AirPlay 2 remote commands (play / pause / next / previous / seek / ±15 s skip) are wired
to the player by default, with now-playing metadata published to `MPNowPlayingInfoCenter`:

```Swift
let player = APlay()  // remote commands already installed
// Pass Configuration(enableRemoteCommandHandling: false) to opt out.
```

Route *picking* stays app-level UI the framework deliberately does not ship — add an
`AVRoutePickerView` (or an `MPVolumeView` with its route button) to let the user choose
an AirPlay route.

Supported formats
---
Anything Core Audio can stream-decode, APlay can play. Formats fall into several buckets.

**Streaming playback (the default path)** — every row is pinned by a test:
`MacTests/FormatCompatibilityTests.swift` drives a bundled fixture through the real
decoder (`AudioFileStream` + `AudioConverter`) and asserts it both parses its metadata
*and* decodes to canonical PCM.

| Format | Common extensions | Note |
| --- | --- | --- |
| AAC (LC / HE-AAC v1 / v2 / ELD) in MP4 | `.m4a` `.mp4` `.mp4f` `.mpg4` | MP4 and raw ADTS verified |
| AAC raw ADTS | `.aac` `.adts` `.aacp` | |
| Audiobook MP4 | `.m4b` | hinted so Core Audio takes the MP4 branch |
| MP3 (MPEG-1/2 Layer III) | `.mp3` | CBR and VBR; seek supported |
| MP2 (MPEG Layer II) | `.mp2` | |
| FLAC | `.flac` | seek supported (with a seek table) |
| Opus in OGG | `.opus` | Core Audio parses the container |
| WAVE PCM | `.wav` `.wave` | tolerates extra chunks before `data`; seek supported |
| IMA ADPCM in WAVE | `.wav` | block PCM; Core Audio reports it as linear PCM |
| ALAC in MP4 | `.m4a` | the magic cookie now reaches the converter (2.1.0) |
| Dolby Digital (AC-3) | `.ac3` | verified on macOS; iOS decoding is Dolby-licensed and varies by device |
| Dolby Digital Plus (E-AC-3) | `.eac3` | same licensing caveat as AC-3 |

**Formats behind the optional libraries** — Core Audio ships no decoder for these, or
the container cannot be parsed by a streaming parser. Each optional product plugs into
the same `audioDecoderBuilder` seam and claims only its own extensions; everything else
falls through to the fallback unchanged:

```Swift
// One seam, one pattern per product. Plain APlay alone stays on the built-in decoder.
let config = APlay.Configuration(
    audioDecoderBuilder: APlayMidi.decoder(
        fallback: APlayExtras.fileDecoder(
            fallback: APlay.Configuration().audioDecoderBuilder),
        soundfont: .init(url: soundfontURL)))
```

not (the framing cannot be rewound, and the codec needs its header packets first).
Each row is pinned by a test: `MacTests/OpusDecoderTests` (`APlayOpus`),
`SeekableFileDecoderTests` (APlayExtras), `WavPackDecoderTests`,
`VorbisDecoderTests`, `SpeexDecoderTests`, `MidiDecoderTests`.
`VorbisDecoderTests`, `SpeexDecoderTests`, `MidiDecoderTests`.

| Library | Format | Extensions | Note |
| --- | --- | --- | --- |
| `APlayExtras` | ALAC in CAF | `.caf` `.caff` | packet table trails the audio data |
| `APlayExtras` | AIFF / AIFF-C PCM | `.aiff` `.aifc` | discontinuity / no stream properties |
| `APlayExtras` | NeXT / Sun AU | `.au` `.snd` | µ-law, A-law and PCM payloads |
| `APlayExtras` | 3GPP / 3GPP2 | `.3gp` `.3g2` | typically an AAC or AMR payload |
| `APlayExtras` | Sony Wave64 | `.w64` | file-only container |
| `APlayWavPack` | WavPack | `.wv` | vendored reference C library, BSD-3 |
| `APlayVorbis` | Vorbis in Ogg | `.ogg` | vendored libvorbis + `CAPlayOgg`, BSD-3 |
| `APlaySpeex` | Speex | `.spx` | vendored libspeex + libogg, BSD-3 |
| `APlayOpus` | Opus in WebM / Matroska | `.webm` `.mka` | pure-Swift EBML demuxer, then Core Audio's Opus converter |
| `APlayMidi` | Standard MIDI File | `.mid` `.midi` `.kar` | `AVAudioSequencer` + `AVAudioUnitSampler` renders offline to canonical PCM |
| — | RF64 / Sound Designer II | `.rf64` `.sd2` | mapped but no fixture could be built |

`APlayMidi` needs a SoundFont — Core Audio ships none, so pass a `.sf2` / `.dls` URL you
ship with your app; leave `.default` and the sampler falls back to its built-in single
tone.

**Not supported** — Core Audio ships no decoder for these, or the container cannot be
parsed. Any of them can still be added by implementing `AudioDecoderCompatible` and
supplying it through `audioDecoderBuilder`.

| Format | Extensions | Why |
| --- | --- | --- |
| MP1 / AMR-NB / AMR-WB | `.mp1` `.amr` | hint-table mapped, but no encoder was available to build a fixture — unverified |
| Opus outside an OGG container | (raw) | containerless Opus is not parsed |
| Windows Media Audio | `.wma` `.asf` | no Core Audio decoder |
| Monkey's Audio / True Audio | `.ape` `.tta` | no Core Audio decoder |
| Dolby TrueHD / MLP / AC-4 | `.thd` `.mlp` `.ac4` | no Core Audio decoder |
| DSD | `.dsf` `.dff` | 1-bit stream; no Core Audio decoder |
| Musepack | `.mpc` `.mpp` `.mp+` | no Core Audio decoder |
| ATRAC3 / ATRAC9 | `.oma` `.at9` | Sony codecs; no Core Audio decoder |
| Matroska audio / MPEG-TS | `.mka` `.ts` | no Core Audio parser (`APlayOpus` covers Opus in Matroska) |
| Raw PCM | — | no header metadata to parse |

> An extension the hint table does not recognise falls back to `.mp3` and relies on
> `AudioFileStream` to sniff the actual content, so an unknown extension is not
> automatically a failure.

Features
---
- CPU-friendly design to avoid excessive peaks
- Every audio format iOS already supports (MP3, WAVE, FLAC, ALAC, AAC, …), plus the
  optional codec libraries above for the formats Core Audio does not ship
- Seek on WAVE, FLAC (with a seek table) and every optional-library format
- Multiple protocols: standard HTTP, ShoutCast/ICY (with metadata), local files
- Prepared for tough network conditions: restart on failures, and restart when the end
  of stream arrives with incomplete content
- Metadata: ShoutCast, ID3v1 / v1.1 / v2.2 / v2.3 / v2.4, FLAC
- Playback starts immediately, without waiting for buffering; `prepare(_:)` preloads a
  track so a later `play(_:)` starts instantly
- Gapless playlist playback (same format across the handoff)
- Stream contents can be cached to a file on disk
- Built-in `NBandEq` equalizer (see *Equalizer*)
- Custom logging module, with logging to file
- Open protocols for customization: `AudioDecoderCompatible`,
  `ConfigurationCompatible`, `LoggerCompatible`, …
- Swift 6 language mode with strict concurrency checking enabled
- AirPlay 2 and lock-screen remote control wired in by default (see *AirPlay 2*)

✅ Release-build silence (fixed)
---
Earlier releases could go silent with optimization (`-O`) enabled — two separate
pointer-lifetime bugs, both invisible in `Debug`:

1. **The decode loop** (2.1.0): the packet-description pointer and decode buffers were
   handed to Core Audio through stack locals and unscoped `inout` references; the
   converter dereferences them *after* the input callback returns.
2. **The render loop** (2.1.1): the `AVAudioEngine` manual-rendering input block returned
   its `AudioBufferList` via `withUnsafePointer(to: &property)`, which only guarantees
   the pointer for the duration of the call — the engine reads the list *after* the block
   returns, so under `-O` the render pulled freed memory and emitted silence.

Both are now backed by stable, object-owned storage that outlives the call. If playback
is silent in a `Release` build again, look for a pointer crossing an API boundary before
checking anything else.

Docs
---
Run `./generate_docs.sh`

Platform notes
---
On iOS and visionOS the audio session is configured with the `.playback` category and
the long-form-audio route sharing policy, and the lock screen / AirPlay 2 remote
commands are wired (see *AirPlay 2 and remote control*). tvOS has no `AVAudioSession`,
`MPNowPlayingInfoCenter` or background-task concept, so those stay compiled out there —
the decoder, ring buffer and render path work unchanged.

Sponsor
---
[![Powered by DartNode](https://dartnode.com/branding/DN-Open-Source-sm.png)](https://dartnode.com "Powered by DartNode - Free VPS for Open Source")

License
---
[License](LICENSE)

Contact
---
[Github](https://github.com/CodeEagle), [Twitter](https://twitter.com/_SelfStudio)
