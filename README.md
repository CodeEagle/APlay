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

✅ Known issue (fixed)
---
Earlier releases could only run in `DEBUG` mode: with optimization enabled (`-O`) the decode
loop would stall. The root cause was a set of dangling pointers around the audio converter —
`outDataPacketDescription` pointed at a stack-local `AudioStreamPacketDescription` that the
converter dereferences *after* the input callback returns, and the decode/output buffers were
handed to Core Audio through unscoped `inout` references. These are now backed by stable,
object-owned storage and scoped pointer access, so optimized `Release` builds work correctly.

No CocoaPods `post_install` workaround is needed anymore — `pod 'APlay'` works out of the box.

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

- [x] Support cached the stream contents to a file

- [x] Built-in `NBandEQ` equalizer wired into the `AUPlayer` audio graph (band frequencies
      configurable via `Configuration.equalizerBandFrequencies`; band gains adjustable at runtime
      via `setEqualizerBandGain(_:at:)`)

- [x] Custom logging module and logging into file supported

- [x] Open protocols to support customizing. `AudioDecoderCompatible`, `ConfigurationCompatible`, `LoggerCompatible`...

- [x] Swift 6 language mode with strict concurrency checking enabled

Installation
---
[Carthage](https://github.com/Carthage/Carthage) `github "CodeEagle/APlay"`

[CocoaPods](https://cocoapods.org/) `pod 'APlay'`

[Swift Package Manager](https://swift.org/package-manager/) `.package(url: "https://github.com/CodeEagle/APlay.git", from: "2.0.0")`

Todo
---
- [ ] AirPlay2 support (Maybe not — tracked separately, see the `airplay2` branch)
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
