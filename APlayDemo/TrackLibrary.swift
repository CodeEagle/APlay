//
//  TrackLibrary.swift
//  APlayDemo
//
//  The catalog of playable content bundled with the demo. Each entry pairs a
//  bundle resource with the story of *how* APlay decodes it, so the format
//  matrix doubles as a live capability map.
//

import Foundation

/// Which decoder path a file takes inside the framework.
enum DecodeRoute: String, Hashable, Sendable {
    /// The built-in streaming decoder (the default for everything it can open).
    case native = "Native streaming decoder"
    /// Routed through `APlayExtras` + ExtAudioFile for containers the streaming
    /// decoder cannot open.
    case fileFallback = "APlayExtras · ExtAudioFile"

    var badge: String { self == .native ? "APlay" : "APlayExtras" }
}

/// A playable entry in the demo.
struct Track: Identifiable, Hashable, Sendable {
    let id = UUID()
    /// Resource lookup parts (`Bundle.main.path(forResource:ofType:)`).
    let resourceName: String
    let resourceType: String
    /// Short label shown in lists, e.g. "Opus".
    let format: String
    /// One-line explanation of container / codec / why it is interesting.
    let detail: String
    let route: DecodeRoute
    /// True when the sample is long enough to show seeking & gapless handoffs.
    let isShowcase: Bool

    var displayName: String { isShowcase ? "Showcase track" : "Tone · \(format)" }
}

enum TrackLibrary {

    /// Live status of one matrix row, driven by playback events.
    enum Status: String, Sendable, Equatable {
        case idle = "—"
        case playing = "playing"
        case played = "done"
        case failed = "failed"
    }

    /// The bundled sample that exercises a format end to end.
    static let showcase = local[0]

    /// All local samples, ordered as the demo plays them. The three containers
    /// the streaming decoder cannot open come last so their `APlayExtras` badge
    /// lands right after the native ones.
    static let local: [Track] = [
        Track(resourceName: "a", resourceType: "m4a",
              format: "AAC · M4A",
              detail: "The longest bundled file — watch Now Playing, seek and the lock screen.",
              route: .native, isShowcase: true),

        Track(resourceName: "tone", resourceType: "m4a",
              format: "AAC-LC",
              detail: "The bread-and-butter container: HTTP and local alike.",
              route: .native, isShowcase: false),
        Track(resourceName: "tone", resourceType: "opus",
              format: "Opus",
              detail: "Codec support is platform-dependent — this row tells you which.",
              route: .native, isShowcase: false),
        Track(resourceName: "tone-alac", resourceType: "m4a",
              format: "ALAC",
              detail: "Lossless Apple codec; needs the magic cookie fed to the decoder.",
              route: .native, isShowcase: false),
        Track(resourceName: "tone-cbr", resourceType: "mp3",
              format: "MP3 · CBR",
              detail: "Constant bitrate MP3, the classic streaming case.",
              route: .native, isShowcase: false),
        Track(resourceName: "tone-vbr", resourceType: "mp3",
              format: "MP3 · VBR",
              detail: "Variable bitrate MP3 — duration math is trickier here.",
              route: .native, isShowcase: false),
        Track(resourceName: "tone", resourceType: "aac",
              format: "AAC · ADTS",
              detail: "Raw ADTS stream with no container framing.",
              route: .native, isShowcase: false),
        Track(resourceName: "tone", resourceType: "flac",
              format: "FLAC",
              detail: "Free Lossless Audio Codec, parsed by hand including its metadata block.",
              route: .native, isShowcase: false),
        Track(resourceName: "tone", resourceType: "wav",
              format: "WAVE",
              detail: "PCM with extra chunks skipped before the data section.",
              route: .native, isShowcase: false),

        Track(resourceName: "tone", resourceType: "aiff",
              format: "AIFF",
              detail: "Only openable through the APlayExtras ExtAudioFile route.",
              route: .fileFallback, isShowcase: false),
        Track(resourceName: "tone", resourceType: "aifc",
              format: "AIFF-C",
              detail: "Compressed AIFF variant, also routed via APlayExtras.",
              route: .fileFallback, isShowcase: false),
        Track(resourceName: "tone", resourceType: "caf",
              format: "CAF",
              detail: "Core Audio Format, also routed via APlayExtras.",
              route: .fileFallback, isShowcase: false),
    ]

    /// Remote source shipped by the old demo, kept to show HTTP streaming.
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/CodeEagle/APlay/master/APlayDemo/a.m4a")!

    /// Resolves the local samples to on-disk URLs, skipping anything missing
    /// from the bundle.
    static func localURLs() -> [URL] {
        local.compactMap { track in
            guard let path = Bundle.main.path(forResource: track.resourceName,
                                              ofType: track.resourceType) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }
}
