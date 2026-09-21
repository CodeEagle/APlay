APlay
---
A Better(Maybe) iOS Audio Stream & Play Swift Framework

Requirements
---
- iOS 15.0+ · Swift 6.0+ (Xcode 16+ toolchain)

Highlights
---
- Playback starts immediately, without waiting for buffering
- HTTP, ShoutCast/ICY and local files; restarts on failure or on a truncated stream
- Metadata: ShoutCast, ID3v1 / v1.1 / v2.2 / v2.3 / v2.4, FLAC
- Stream contents can be cached to disk; folders can be added for local resource loading
- Gapless playlists, `prepare(_:)` preloading, a built-in `NBandEq` equalizer
- AirPlay 2 and lock-screen remote control wired in by default
- Swift 6 language mode with strict concurrency checking enabled

Installation
---
[Swift Package Manager](https://swift.org/package-manager/) is the only supported way —
no CocoaPods spec, no Carthage:

```Swift
.package(url: "https://github.com/CodeEagle/APlay.git", from: "2.1.2")
```

Add the `APlay` product. Supported platforms: macOS 12+, iOS 15+, tvOS 15+, visionOS 1+.

Optional codec products exist for formats Core Audio does not ship — add them only when
you need the extensions they claim; plain `APlay` is unchanged:

| Product | Adds | Extensions |
| --- | --- | --- |
| `APlayExtras` | seekable local-file decoding | `.caf` `.aiff` `.aifc` `.au` `.3gp` `.3g2` `.w64` |
| `APlayOpus` | Opus in WebM / Matroska | `.webm` `.mka` |
| `APlayWavPack` | WavPack | `.wv` |
| `APlayVorbis` | Vorbis in Ogg | `.ogg` |
| `APlaySpeex` | Speex | `.spx` |
| `APlayMidi` | Standard MIDI File | `.mid` `.midi` `.kar` |

Usage
---
```Swift
import APlay

let url = URL(string: "path/to/audio/resource")!
let player = APlay()
player.eventPipeline.delegate(to: self, with: { (target, event) in
    //  event handling
})
player.play(url)
```

`prepare(_:)` fills the ring buffer without starting the output audio unit, so a later
`play(_:)` of the same URL starts instantly.

> Plain `http://` streams are blocked by App Transport Security by default — add an
> `NSAllowsArbitraryLoads` (or per-domain) exception to your `Info.plist`. This is the
> most common cause of "cannot play HTTP stream".

Equalizer
---
An `AVAudioUnitEQ` runs in the render chain, one band per entry of
`Configuration.equalizerBandFrequencies` (8 by default: 50 / 100 / 200 / 400 / 800 / 1600
/ 2600 / 16000 Hz; first band low shelf, last high shelf, the rest parametric). Gains
apply at runtime without restarting playback:

```Swift
player.applyEqualizerPreset(.rock)                 // flat / rock / pop / jazz / classical /
                                                   // bassBoost / trebleBoost / vocal /
                                                   // electronic / acoustic
player.setEqualizerBandGain(3.5, at: 2)            // one band, -96...24 dB
let gains = player.equalizerGains                  // read the curve back
player.applyEqualizerPreset(.init(name: "Mine", gains: [4, 3, 2, 1, 0, 1, 2, 3]))
```

A preset whose band count differs from the configuration's frequencies is ignored (and
logged), never silently shifted.

Gapless playback
---
```Swift
let player = APlay(configuration: APlay.Configuration(gaplessPlaybackEnabled: true))
player.loopPattern = .stopWhenAllPlayed(.order)
player.play([first, second, third])
```

The next track is preloaded while the current one still plays, and the output audio unit
swaps in the buffered source without stopping — no gap, no `.paused` at the handoff. A
handoff between *different* formats still re-initializes the graph.

AirPlay 2 and remote control
---
The audio session runs the `.playback` category with the `longFormAudio` route sharing
policy — the combination AirPlay 2 expects — and the lock screen, Control Center and
AirPlay 2 remote commands (play / pause / next / previous / seek / ±15 s skip) are wired
in by default, with now-playing metadata published to `MPNowPlayingInfoCenter`:

```Swift
let player = APlay()  // remote commands already installed
// Pass Configuration(enableRemoteCommandHandling: false) to opt out.
```

Route *picking* stays app-level UI — add an `AVRoutePickerView` (or an `MPVolumeView`
with its route button).

Supported formats
---
Anything Core Audio can stream-decode, APlay can play. Formats fall into three buckets.

**Streaming (the default path)** — each row is pinned by a fixture-driven test
(`MacTests/FormatCompatibilityTests.swift`) that asserts the decoder both parses its
metadata *and* decodes to canonical PCM.

| Format | Extensions | Note |
| --- | --- | --- |
| AAC (LC / HE-AAC v1 / v2 / ELD) | `.m4a` `.mp4` `.mp4f` `.mpg4` | MP4 and raw ADTS verified |
| AAC raw ADTS | `.aac` `.adts` `.aacp` | |
| Audiobook MP4 | `.m4b` | hinted so Core Audio takes the MP4 branch |
| MP3 / MP2 | `.mp3` `.mp2` | CBR and VBR MP3; seek supported |
| FLAC | `.flac` | seek supported (with a seek table) |
| Opus in OGG | `.opus` | Core Audio parses the container |
| WAVE PCM | `.wav` `.wave` | tolerates extra chunks before `data`; seek supported |
| IMA ADPCM in WAVE | `.wav` | Core Audio reports it as linear PCM |
| ALAC in MP4 | `.m4a` | the magic cookie reaches the converter (2.1.0) |
| Dolby Digital / Plus | `.ac3` `.eac3` | verified on macOS; iOS decoding is Dolby-licensed and varies by device |

**Optional libraries** — the products above plug into one seam and claim only their own
extensions; everything else falls through to the built-in decoder:

```Swift
let config = APlay.Configuration(
    audioDecoderBuilder: APlayMidi.decoder(
        fallback: APlayExtras.fileDecoder(
            fallback: APlay.Configuration().audioDecoderBuilder),
        soundfont: .init(url: soundfontURL)))
```

A local file through an optional library is buffered whole and is seekable; a live stream
is not (the framing cannot be rewound, and the codec needs its header packets first).
`APlayMidi` needs a SoundFont — Core Audio ships none, so pass a `.sf2` / `.dls` URL you
ship with your app, or leave `.default` for the sampler's built-in single tone. Each row
is pinned by a test: `MacTests/OpusDecoderTests`, `SeekableFileDecoderTests`,
`WavPackDecoderTests`, `VorbisDecoderTests`, `SpeexDecoderTests`, `MidiDecoderTests`.
The vendored C libraries are BSD-3 (`CAPlayOgg`, `CAPlayVorbis`, `CAPlaySpeex`,
`CAPlayWavPack`).

**Not supported** — no Core Audio decoder, or the container cannot be parsed. Any of them
can still be added by implementing `AudioDecoderCompatible`:

| Format | Extensions | Why |
| --- | --- | --- |
| MP1 / AMR | `.mp1` `.amr` | hint-table mapped, but no encoder was available to build a fixture — unverified |
| Opus outside OGG | (raw) | containerless Opus is not parsed |
| WMA / ASF | `.wma` `.asf` | no Core Audio decoder |
| Monkey's Audio / True Audio | `.ape` `.tta` | no Core Audio decoder |
| Dolby TrueHD / MLP / AC-4 | `.thd` `.mlp` `.ac4` | no Core Audio decoder |
| DSD | `.dsf` `.dff` | 1-bit stream |
| Musepack | `.mpc` `.mpp` `.mp+` | no Core Audio decoder |
| ATRAC3 / ATRAC9 | `.oma` `.at9` | Sony codecs |
| MPEG-TS | `.ts` | no Core Audio parser |
| Raw PCM | — | no header metadata to parse |

> An extension the hint table does not recognise falls back to `.mp3` and relies on
> `AudioFileStream` to sniff the actual content, so an unknown extension is not
> automatically a failure.

Troubleshooting
---
- **Silent in `Release` but fine in `Debug`**: fixed in 2.1.0 / 2.1.1 — two
  pointer-lifetime bugs where Core Audio dereferenced storage *after* the callback that
  supplied it returned. If it ever recurs, look for a pointer crossing an API boundary
  before checking anything else.
- **Robustness on bad networks**: playback restarts on failure, and restarts again when
  the end of stream arrives with incomplete content.
- **Custom codecs**: implement `AudioDecoderCompatible` and supply it through
  `audioDecoderBuilder`. `ConfigurationCompatible` and `LoggerCompatible` offer the same
  seam for configuration and logging; the built-in logger can write to file.

Docs
---
Run `./generate_docs.sh`

Sponsor
---
[![Powered by DartNode](https://dartnode.com/branding/DN-Open-Source-sm.png)](https://dartnode.com "Powered by DartNode - Free VPS for Open Source")

License
---
[License](LICENSE)

Contact
---
[Github](https://github.com/CodeEagle), [Twitter](https://twitter.com/_SelfStudio)
