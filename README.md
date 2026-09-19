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

| Format | Container / codec | Decode | Note |
| --- | --- | --- | --- |
| AAC | MP4 (`.m4a`) | ✅ | |
| AAC | raw ADTS (`.aac`) | ✅ | |
| MP3 | CBR and VBR (`.mp3`) | ✅ | seek supported |
| FLAC | native (`.flac`) | ✅ | seek supported (with a seek table) |
| Opus | in OGG (`.opus`) | ✅ | Core Audio parses the container on this platform |
| WAVE | PCM (`.wav`) | ✅ | tolerates extra chunks (`LIST`/`INFO`, `FLLR`) before `data`; seek supported |
| ALAC | MP4 (`.m4a`) | ✅ | |
| ALAC | CAF (`.caf`) | ⚠️ stream only | the packet table trails the audio data, so the streaming parser reports `optm`. Local files play through `APlayExtras` |
| AIFF / AIFF-C | PCM (`.aiff`, `.aifc`) | ⚠️ stream only | `AudioFileStream` reports a packet discontinuity (`dsc!`). Local files play through `APlayExtras` |

The hint table also routes these Core Audio-native extensions, but no fixture ships for
them, so they are *not* covered by the test matrix: `.m4b`, `.ac3`, `.amr`, `.3gp`,
`.3g2`, `.mp2`, `.mp1`, `.au`/`.snd`, `.rf64`, `.sd2`. Formats Core Audio does not ship
(Vorbis, Opus outside an OGG container, …) need an injected custom decoder — see
`audioDecoderBuilder` and the Todo list.

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

Todo
---
- [x] AirPlay 2 support: the session runs the `longFormAudio` route sharing policy and
      the lock screen / Control Center / AirPlay 2 remote commands
      (play / pause / next / previous / seek / ±15 s skip) are wired in by default via
      `MPRemoteCommandCenter`; route picking stays app-level UI (`AVRoutePickerView`)
- [ ] AudioEffectUnit support: band **frequencies** and **gains** are now configurable, but gains
      can only be set per-band — preset management (save/apply an EQ curve) is the remaining gap.
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
