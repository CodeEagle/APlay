APlay
---
A Better(Maybe) iOS Audio Stream & Play Swift Framework


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

- [x] Support cached the stream contents to a file

- [x] Custom logging module and logging into file supported

- [x] Open protocols to support customizing. `AudioDecoderCompatible`, `ConfigurationCompatible`, `LoggerCompatible`...

Installation
---
[Carthage](https://github.com/Carthage/Carthage) `github "CodeEagle/APlay"`

[CocoaPods](https://cocoapods.org/) `pod 'APlay'`

Todo
---
- [ ] Airplay2 support(Maybe not)
- [ ] AudioEffectUint support

License
---
[License](LICENSE)

Contact
---
[Github](https://github.com/CodeEagle), [Twitter](https://twitter.com/_SelfStudio)
