//
//  APlayExtras.swift
//  APlayExtras
//
//  The optional companion library for APlay: support for formats the framework's
//  built-in streaming decoder cannot open, delivered through the same
//  `audioDecoderBuilder` injection seam. Add this product only when you need it;
//  apps that never touch CAF/AIFF/AIFF-C can stay on `APlay` alone.
//

import APlay
import Foundation

public enum APlayExtras {

    /// Builds an `audioDecoderBuilder` that routes local CAF/AIFF/AIFF-C files
    /// through `SeekableFileDecoder` and everything else through a fallback
    /// decoder you supply.
    ///
    /// Pass the framework's own default to keep every other format behaving
    /// exactly as before. `audioDecoderBuilder` is read-only after init, so the
    /// builder goes through the configuration initializer:
    /// ```swift
    /// let config = APlay.Configuration(
    ///     audioDecoderBuilder: APlayExtras.fileDecoder(fallback: APlay.Configuration().audioDecoderBuilder))
    /// ```
    ///
    /// The fallback is a builder rather than a fixed decoder so an app that
    /// already injects its own decoder (a custom codec, for example) can wrap it
    /// instead of the built-in one.
    ///
    /// - Parameter fallback: the decoder to use for every URL the file decoder
    ///   does not handle. `APlay.Configuration().audioDecoderBuilder` is the
    ///   framework default.
    /// - Returns: A builder suitable for `Configuration.audioDecoderBuilder`.
    public static func fileDecoder(fallback: @escaping (ConfigurationCompatible) -> AudioDecoderCompatible) -> AudioDecoderBuilder {
        return { FileFallbackDecoder(config: $0, fallback: fallback) }
    }
}
