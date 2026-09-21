//
//  APlayOpus.swift
//  APlayOpus
//
//  Optional Opus decoder for WebM (`.webm`) and Matroska audio (`.mka`).
//  Core Audio has an Opus codec but no AudioFileStream parser for the EBML
//  container, so this product demuxes the track in Swift and decodes the
//  packets through the platform converter — no vendored C. Add the product
//  only when you need it; plain `APlay` is unchanged.
//
//  Wire it once on the configuration:
//  ```swift
//  let config = APlay.Configuration(
//     audioDecoderBuilder: APlayOpus.decoder(fallback: APlay.Configuration().audioDecoderBuilder))
//  ```
//

import APlay
import Foundation

/// Routes `.webm`/`.mka` URLs to the Opus decoder and leaves everything else
/// on the decoder it wraps.
public enum APlayOpus {
    /// The file hints this library owns.
    public static let handledHints: [AudioFileType] = [.webm, .mka]

    /// Builds an `audioDecoderBuilder` that routes WebM/Matroska files through
    /// this decoder and everything else through a fallback decoder you supply.
    /// `APlay.Configuration().audioDecoderBuilder` is the framework default.
    public static func decoder(fallback: @escaping AudioDecoderBuilder) -> AudioDecoderBuilder {
        return { OpusDecoder(config: $0, fallback: fallback($0)) }
    }
}
