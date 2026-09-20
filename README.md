APlay
---
A Better(Maybe) iOS Audio Stream & Play Swift Framework

Requirements
---
- iOS 15.0+
- Swift 6.0+ (Xcode 16+ toolchain)


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

Equalizer
---
The built-in player wires an `NBandEQ` into its audio graph when `equalizerBandFrequencies` is
configured (the default is `[50, 100, 200, 400, 800, 1600, 2600, 16000]`). Band gains can be
adjusted at any time:

```Swift
// boost the low band by 6 dB (index order matches Configuration.equalizerBandFrequencies)
player.setEqualizerBandGain(6, at: 0)
```

Gapless playback
---
Play a list with `gaplessPlaybackEnabled` turned on and the next track is preloaded while the
current one is still playing; at the end of the track the output audio unit swaps in the
buffered source without stopping, so consecutive tracks of the same format play without a gap:

```Swift
let player = APlay(configuration: APlay.Configuration(gaplessPlaybackEnabled: true))
player.loopPattern = .stopWhenAllPlayed(.order)
player.play([first, second, third])
```

The default is off, so single-track playback behaves exactly as before. A handoff between
different audio formats (for example MP3 → FLAC) still re-initializes the graph and is not
seamless.

Supported formats
---
Anything Core Audio can stream-decode, APlay can play. The matrix below is pinned by
`MacTests/FormatCompatibilityTests.swift`, which drives every bundled fixture through the
real decoder (`AudioFileStream` + `AudioConverter`) — a format only counts as supported
when it both parses its metadata *and* decodes to canonical PCM.

Anything Core Audio can stream-decode, APlay can play. The tables below cover the
audio formats in common use today, and where each one stands in this library. Status
meanings:

- ✅ **Verified** — a bundled fixture is driven through the real decoder
  (`AudioFileStream` + `AudioConverter`) by `MacTests/FormatCompatibilityTests.swift`;
  the format both parses its metadata *and* decodes to canonical PCM.
- ✔ **Routed** — mapped in the hint table (`AudioFileType.fileHint(from:)`) to a
  built-in Core Audio decoder, but no fixture ships, so it is *not* pinned by the
  test matrix.
- ⚠️ **Stream-only** — the streaming parser trips on this container, so local files
  play through the optional `APlayExtras` library (`ExtAudioFile`) instead.
- 🔌 **Inject** — Core Audio ships no decoder for it. Implement
  `AudioDecoderCompatible` and supply it through `audioDecoderBuilder`.

#### Lossy

| Format | Common extensions | Status | Note |
| --- | --- | --- | --- |
| MP3 (MPEG-1/2 Layer III) | `.mp3` | ✅ | CBR and VBR; seek supported |
| MP2 (Layer II) | `.mp2` | ✔ | |
| MP1 (Layer I) | `.mp1` | ✔ | |
| AAC (LC / HE-AAC v1 / v2 / ELD) | `.m4a` `.mp4` `.aac` `.adts` `.aacp` | ✅ | MP4 and raw ADTS verified |
| Opus in OGG | `.opus` | ✅ | Core Audio parses the container on this platform |
| Dolby Digital (AC-3) / Digital Plus (E-AC-3) | `.ac3` `.eac3` | ✔ | |
| AMR-NB / AMR-WB | `.amr` | ✔ | 3GPP speech codec |
| Vorbis in Ogg | `.ogg` | 🔌 | Core Audio has no Vorbis decoder |
| Opus outside an OGG container | (raw) | 🔌 | containerless Opus is not parsed |
| Windows Media Audio | `.wma` `.asf` | 🔌 | |
| Musepack | `.mpc` `.mpp` `.mp+` | 🔌 | |
| ATRAC3 / ATRAC9 | `.oma` `.at9` | 🔌 | Sony codecs |
| Speex | `.spx` | 🔌 | speech codec |
| Dolby AC-4 | `.ac4` | 🔌 | |

#### Lossless

| Format | Common extensions | Status | Note |
| --- | --- | --- | --- |
| FLAC | `.flac` | ✅ | seek supported (with a seek table) |
| ALAC in MP4 | `.m4a` | ✅ | the magic cookie now reaches the converter (2.1.0) |
| ALAC in CAF | `.caf` | ⚠️ | the packet table trails the audio data, so the streaming parser reports `optm`; local files play through `APlayExtras` |
| WavPack | `.wv` | 🔌 | |
| Monkey's Audio | `.ape` | 🔌 | |
| True Audio | `.tta` | 🔌 | |
| Dolby TrueHD / MLP | `.thd` `.mlp` | 🔌 | |
| DSD (DSF / DFF) | `.dsf` `.dff` | 🔌 | 1-bit stream; no Core Audio decoder |
| OptimFROG | `.ofr` `.ofs` | 🔌 | |
| Shorten | `.shn` | 🔌 | |

#### Uncompressed & block PCM

| Format | Common extensions | Status | Note |
| --- | --- | --- | --- |
| WAVE PCM | `.wav` `.wave` | ✅ | tolerates extra chunks (`LIST`/`INFO`, `FLLR`) before `data`; seek supported |
| AIFF / AIFF-C PCM | `.aiff` `.aifc` | ⚠️ | `AudioFileStream` reports a packet discontinuity (`dsc!`); local files play through `APlayExtras` |
| WAVE ADPCM (IMA / Microsoft / DVI) | `.wav` | ✔ | block PCM inside a WAVE container |
| NeXT / Sun AU | `.au` `.snd` | ✔ | µ-law, A-law and PCM payloads |
| RF64 (Broadcast WAVE) | `.rf64` | ✔ | |
| Sound Designer II | `.sd2` | ✔ | |
| Sony Wave64 | `.w64` | 🔌 | |
| Raw PCM | — | 🔌 | no header metadata to parse |

#### Containers & audiobooks

| Format | Common extensions | Status | Note |
| --- | --- | --- | --- |
| MP4 / MPEG-4 | `.mp4` `.mp4f` `.mpg4` | ✔ | typically an AAC or ALAC payload |
| Audiobook MP4 | `.m4b` | ✔ | same MPEG-4 container, hinted separately so Core Audio takes the MP4 branch |
| Core Audio Format | `.caf` `.caff` | ✔ | a container; see ALAC-in-CAF above |
| 3GPP / 3GPP2 | `.3gp` `.3g2` | ✔ | AMR or AAC payload |
| Matroska audio | `.mka` | 🔌 | |
| MPEG-TS | `.ts` | 🔌 | |

#### Not audio streams

| Format | Common extensions | Status | Note |
| --- | --- | --- | --- |
| MIDI | `.mid` `.midi` | — | note sequences, not PCM; needs a synthesiser |
| SoundFont | `.sf2` | — | instrument sample bank, not a stream |

> An extension the hint table does not recognise falls back to `.mp3` and relies on
> `AudioFileStream` to sniff the actual content, so an unknown extension is not
> automatically a failure. Every format marked 🔌 has no Core Audio decoder — the
> library cannot play it without an injected `AudioDecoderCompatible`; see
> `audioDecoderBuilder` and the Todo list.

✅ Known issue (fixed)
---
Earlier releases could only run in `DEBUG` mode: with optimization enabled (`-O`) the decode
loop would stall. The root cause was a set of dangling pointers around the audio converter —
`outDataPacketDescription` pointed at a stack-local `AudioStreamPacketDescription` that the
converter dereferences *after* the input callback returns, and the decode/output buffers were
handed to Core Audio through unscoped `inout` references. These are now backed by stable,
object-owned storage and scoped pointer access, so optimized `Release` builds work correctly.

> ℹ️ Plain `http://` streams: iOS blocks non-HTTPS URLs via App Transport Security by default.
> If your stream URL is `http://...`, add an `NSAllowsArbitraryLoads` (or a per-domain) exception
> to your app's `Info.plist`, otherwise the open will fail with a permission error. This is the
> most common cause of "cannot play HTTP stream".

Docs
---
Run `./generate_docs.sh`

Features
---
- [x] CPU-friendly design to avoid excessive peaks

- [x] Support seek on WAVE, and FLAC(with seektable)

- [x] Support all type of audio format(MP3, WAVE, FLAC, etc...) that iOS already support(Not fully tested)

- [x] Digest(Tested), Basic(not tested) proxy support

- [x] Multiple protocols supported: ShoutCast, standard HTTP, local files

- [x] Prepared for tough network conditions: restart on failures，restart on not full content streamed when end of stream

- [x] Metadata support: ShoutCast metadata, ID3V1, ID3v1.1, ID3v2.2, ID3v2.3, ID3v2.4, FLAC metadata

- [x] Local disk storing: user can add folders for local resource loading

- [x] Playback can start immediately without needing to wait for buffering

- [x] Pre-load a track with `prepare(_:)`: the streamer and decoder buffer the audio
      without starting the output audio unit, so a later `play(_:)` of the same URL
      starts instantly from the filled ring buffer

- [x] Gapless playlist playback: with `Configuration(gaplessPlaybackEnabled: true)` the
      next track is preloaded while the current one plays, and the output audio unit
      switches sources at the end of the track without stopping — no gap and no `.paused`
      state at the handoff (same format only; a format change still re-initializes)

- [x] Support cached the stream contents to a file

- [x] Built-in `NBandEQ` equalizer wired into the `AUPlayer` audio graph (band frequencies
      configurable via `Configuration.equalizerBandFrequencies`; band gains adjustable at runtime
      via `setEqualizerBandGain(_:at:)`)

- [x] Custom logging module and logging into file supported

- [x] Open protocols to support customizing. `AudioDecoderCompatible`, `ConfigurationCompatible`, `LoggerCompatible`...

- [x] Swift 6 language mode with strict concurrency checking enabled

Installation
---
[Swift Package Manager](https://swift.org/package-manager/) is the only supported way to
add APlay — there is no CocoaPods spec and no Carthage support anymore:

```Swift
.package(url: "https://github.com/CodeEagle/APlay.git", from: "2.0.0")
```

Add the `APlay` product to your app target. The package declares macOS 12+, iOS 15+,
tvOS 15+ and visionOS 1+ as supported platforms. The same `Package.swift` also builds
the `APlayMacPlayback` end-to-end validation target and the `APlayTests` suite on
macOS, so `swift build` and `swift test` are the single source of truth for the
framework.

Platform notes: on iOS and visionOS the audio session is configured with the
`.playback` category and the long-form-audio route sharing policy, and the lock screen
/ AirPlay 2 remote commands are wired (see *AirPlay 2 and remote control* below). tvOS
has no `AVAudioSession`, `MPNowPlayingInfoCenter` or background-task concept, so those
stay compiled out there — the decoder, ring buffer and render path work unchanged.

Optional formats: `APlayExtras`
---
The two rows above marked `⚠️ stream only` are seekable file formats whose layout a
streaming parser cannot handle — the packet table sits after the audio data, or the
container reports a discontinuity. Local files in those formats still play, but only
through a seekable file decoder.

`APlayExtras` is an optional companion library that adds exactly that. Add the product
only when you need it; apps that never touch CAF/AIFF/AIFF-C stay on `APlay` alone with
no extra code:

```Swift
.product(name: "APlayExtras", package: "APlay")
```

```Swift
import APlay
import APlayExtras

// `audioDecoderBuilder` is read-only after init, so the builder goes through the
// configuration initializer. The fallback keeps every other format unchanged.
let player = APlay(configuration: APlay.Configuration(
    audioDecoderBuilder: APlayExtras.fileDecoder(fallback: APlay.Configuration().audioDecoderBuilder)))
```

Local CAF/AIFF/AIFF-C files route through an `ExtAudioFile`-backed decoder; everything
else goes to the fallback you supply. An app that already injects its own decoder (a
custom codec, for example) can wrap it instead of the built-in one.

AirPlay 2 and remote control
---
The audio session runs the `.playback` category with the `longFormAudio` route sharing
policy — the combination AirPlay 2 expects for long-form audio — and the lock screen,
Control Center and AirPlay 2 remote commands are wired to the player by default, so a
HomePod, an Apple TV or the iOS lock screen can control playback without extra app
code: play / pause / toggle, next / previous track, change position (when the track is
seekable) and ±15 s skip:

```Swift
let player = APlay()  // remote commands already installed
```

Pass `Configuration(enableRemoteCommandHandling: false)` to opt out.

To let the user *pick* an AirPlay route, add an `AVRoutePickerView` (or an `MPVolumeView`
with its route button) to your UI — that is app-level UI the framework deliberately does
not ship. Now-playing metadata (title / artist / album / artwork / elapsed time) is
already published to `MPNowPlayingInfoCenter` via `metadataUpdate`.

Equalizer
---
The player runs an `AVAudioUnitEQ` in its render chain, one band per entry of
`Configuration.equalizerBandFrequencies` (8 by default: 50 / 100 / 200 / 400 / 800 /
1600 / 2600 / 16000 Hz). The first band is a low shelf, the last a high shelf and the
rest parametric, so a single curve shapes the whole spectrum.

```Swift
let player = APlay()

// A preset is plain data — one gain in dB per band, in the same order as the
// configured frequencies. It takes effect immediately; playback is not restarted.
player.applyEqualizerPreset(.rock)

// Or a single band, clamped to the audio unit's -96...24 dB range.
player.setEqualizerBandGain(3.5, at: 2)

// Read the current curve back.
let gains: [Float] = player.equalizerGains
```

Ten curves are bundled — `flat`, `rock`, `pop`, `jazz`, `classical`, `bassBoost`,
`trebleBoost`, `vocal`, `electronic`, `acoustic` — or build your own:

```Swift
let curve = EqualizerPreset(name: "My Curve", gains: [4, 3, 2, 1, 0, 1, 2, 3])
player.applyEqualizerPreset(curve)
```

A preset whose band count differs from the configuration's frequencies is ignored
(and logged), so a saved curve never silently shifts the wrong frequencies after a
configuration change.

Todo
---
- [x] AirPlay 2 support: the session runs the `longFormAudio` route sharing policy and
      the lock screen / Control Center / AirPlay 2 remote commands
      (play / pause / next / previous / seek / ±15 s skip) are wired in by default via
      `MPRemoteCommandCenter`; route picking stays app-level UI (`AVRoutePickerView`)
- [x] AudioEffectUnit support: band **frequencies** and **gains** are configurable, and
      gains apply at runtime either per band or as a whole preset — see "Equalizer" above.
- [ ] Custom decoder formats (see issue #17): the `audioDecoderBuilder` seam already hands an
      injected decoder the stream's file hint (verified for `.opus`), so an app can decode a
      format Core Audio does not ship — the remaining gap is bundling a reference implementation.

Sponsor 
---
[![Powered by DartNode](https://dartnode.com/branding/DN-Open-Source-sm.png)](https://dartnode.com "Powered by DartNode - Free VPS for Open Source")

License
---
[License](LICENSE)

Contact
---
[Github](https://github.com/CodeEagle), [Twitter](https://twitter.com/_SelfStudio)
