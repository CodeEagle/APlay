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
        .executableTarget(
            name: "APlayMacPlayback",
            dependencies: ["APlay"],
            path: "MacPlayback"
        ),
        .testTarget(
            name: "APlayTests",
            dependencies: ["APlay", "APlayExtras", "APlayWavPack", "APlayVorbis"],
            path: "MacTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
