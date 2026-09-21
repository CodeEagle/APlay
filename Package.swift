// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "APlay",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "APlay", targets: ["APlay"]),
        .library(name: "APlayExtras", targets: ["APlayExtras"]),
        .library(name: "APlayWavPack", targets: ["APlayWavPack"]),
        .library(name: "APlayVorbis", targets: ["APlayVorbis"]),
        .library(name: "APlaySpeex", targets: ["APlaySpeex"]),
        // MIDI playback through a SoundFont. Pure Swift on AVFoundation — no
        // vendored C — because AVAudioSequencer + AVAudioUnitSampler already
        // render Standard MIDI Files to PCM.
        .library(name: "APlayMidi", targets: ["APlayMidi"]),
    ],
    targets: [
        .target(
            name: "APlay",
            path: "APlay",
            exclude: ["Info.plist"]
        ),
        .target(
            name: "APlayExtras",
            dependencies: ["APlay"],
            path: "APlayExtras"
        ),
        // WavPack decoder, vendored. The C library is pure ANSI C with no
        // config header; the wrapper implements `AudioDecoderCompatible` and
        // is wired through the same `audioDecoderBuilder` seam as APlayExtras.
        .target(
            name: "CAPlayWavPack",
            path: "Sources/CAPlayWavPack",
            publicHeadersPath: "include",
            cSettings: [
                // The local headers sit next to the sources; the public one is
                // reached as <wavpack/wavpack.h>.
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("include/wavpack"),
            ]
        ),
        .target(
            name: "APlayWavPack",
            dependencies: ["APlay", "CAPlayWavPack"],
            path: "Sources/APlayWavPack"
        ),
        // Ogg page/framing layer, shared by every Ogg-carried codec. Pure
        // ANSI C; `os_types.h` resolves its integer types per platform without
        // a generated config header.
        .target(
            name: "CAPlayOgg",
            path: "Sources/CAPlayOgg",
            publicHeadersPath: "include"
        ),
        // Vorbis decoder, vendored. Only the decode side is compiled — the
        // encoder (the sole user of `modes/`) is excluded, so no setup tables
        // are needed. Reaches libogg through `<ogg/ogg.h>`.
        .target(
            name: "CAPlayVorbis",
            dependencies: ["CAPlayOgg"],
            path: "Sources/CAPlayVorbis",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "APlayVorbis",
            dependencies: ["APlay", "CAPlayOgg", "CAPlayVorbis"],
            path: "Sources/APlayVorbis"
        ),
        // Speex decoder, vendored. Only the decode side is compiled — the
        // encoders and the psychoacoustic model (its sole consumer) are
        // excluded. Reaches libogg through `<ogg/ogg.h>`. `FLOATING_POINT` is
        // the configuration the reference `speexdec` uses.
        .target(
            name: "CAPlaySpeex",
            dependencies: ["CAPlayOgg"],
            path: "Sources/CAPlaySpeex",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("FLOATING_POINT"),
                .define("HAVE_CONFIG_H"),
                .define("USE_KISS_FFT"),
            ]
        ),
        .target(
            name: "APlaySpeex",
            dependencies: ["APlay", "CAPlayOgg", "CAPlaySpeex"],
            path: "Sources/APlaySpeex"
        ),
        // Standard MIDI File playback. Core Audio has no MIDI decoder, so this
        // product renders the file itself through AVAudioSequencer + an
        // AVAudioUnitSampler loaded with a SoundFont, inside an AVAudioEngine
        // in offline manual rendering mode. The wrapper implements
        // `AudioDecoderCompatible` and is wired through the same
        // `audioDecoderBuilder` seam as the vendored codecs.
        .target(
            name: "APlayMidi",
            dependencies: ["APlay"],
            path: "Sources/APlayMidi"
        ),
        .executableTarget(
            name: "APlayMacPlayback",
            dependencies: ["APlay"],
            path: "MacPlayback"
        ),
        .testTarget(
            name: "APlayTests",
            dependencies: ["APlay", "APlayExtras", "APlayWavPack", "APlayVorbis", "APlaySpeex", "APlayMidi"],
            path: "MacTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
