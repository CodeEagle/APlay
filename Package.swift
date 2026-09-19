// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "APlay",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(name: "APlay", targets: ["APlay"]),
        .library(name: "APlayExtras", targets: ["APlayExtras"]),
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
        .executableTarget(
            name: "APlayMacPlayback",
            dependencies: ["APlay"],
            path: "MacPlayback"
        ),
        .testTarget(
            name: "APlayTests",
            dependencies: ["APlay", "APlayExtras"],
            path: "MacTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
