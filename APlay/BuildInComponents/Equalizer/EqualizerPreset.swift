//
//  EqualizerPreset.swift
//  APlay
//
//  A named equalizer curve: one gain value per band, in the same order as
//  `Configuration.equalizerBandFrequencies`. Delivered as plain data so it can
//  be stored, compared and passed across concurrency boundaries; apply one with
//  `APlay.applyEqualizerPreset(_:)`, which takes effect on a running player
//  without restarting playback.
//

import Foundation

/// One equalizer curve: a name plus a gain per band.
public struct EqualizerPreset: Equatable, Sendable {

    /// Human-readable name, e.g. `"Rock"`.
    public let name: String

    /// Band gains in dB, one entry per band, ordered like
    /// `Configuration.equalizerBandFrequencies`. The audio unit clamps each
    /// value to `-96 ... 24` dB.
    public let gains: [Float]

    /// Creates a preset.
    ///
    /// - Parameters:
    ///   - name: Human-readable name.
    ///   - gains: Band gains in dB. `APlay.applyEqualizerPreset(_:)` ignores a
    ///     preset whose band count differs from the configuration's
    ///     `equalizerBandFrequencies`.
    public init(name: String, gains: [Float]) {
        self.name = name
        self.gains = gains
    }
}

public extension EqualizerPreset {

    // MARK: Built-in presets

    /// Neutral curve — every band at 0 dB.
    static let flat = EqualizerPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0])
    /// Classic smile curve: boosted lows and highs, slightly recessed mids.
    static let rock = EqualizerPreset(name: "Rock", gains: [4.5, 3.5, 2.0, 0.5, -1.0, -0.5, 1.5, 3.5])
    /// Presence curve: mids forward, lows and highs trimmed — suits vocals and
    /// lead instruments in a dense mix.
    static let pop = EqualizerPreset(name: "Pop", gains: [-1.0, 0.5, 2.5, 4.0, 3.5, 1.5, 0.0, -1.5])
    /// Warm tilt: a gentle mid/high rise with the lows trimmed slightly.
    static let jazz = EqualizerPreset(name: "Jazz", gains: [-1.5, -0.5, 0.5, 1.5, 2.5, 2.0, 1.0, 0.5])
    /// Mild lift at both ends with a flat midrange — adds air and room without
    /// colouring the mids.
    static let classical = EqualizerPreset(name: "Classical", gains: [2.0, 1.5, 0.5, 0.0, 0.0, 0.5, 1.5, 2.0])
    /// Low-frequency emphasis, everything else flat.
    static let bassBoost = EqualizerPreset(name: "Bass Boost", gains: [7.0, 5.5, 3.5, 1.5, 0.0, 0.0, 0.0, 0.0])
    /// High-frequency emphasis, everything else flat.
    static let trebleBoost = EqualizerPreset(name: "Treble Boost", gains: [0.0, 0.0, 0.0, 0.0, 1.0, 2.5, 4.5, 6.5])
    /// Midrange push with the extremes trimmed, pulling a lead vocal forward.
    static let vocal = EqualizerPreset(name: "Vocal", gains: [-2.5, -1.5, 0.0, 2.5, 4.0, 3.0, 0.5, -1.5])
    /// Dance/electronic V-curve: heavy lows, cut mids, bright tops.
    static let electronic = EqualizerPreset(name: "Electronic", gains: [4.0, 3.0, 1.0, 0.0, -1.0, 1.0, 2.0, 4.0])
    /// Acoustic lift: gentle lows and air, mids left alone.
    static let acoustic = EqualizerPreset(name: "Acoustic", gains: [3.0, 2.0, 1.0, 0.0, 0.0, 0.5, 1.5, 2.0])

    /// Every built-in preset, in the order shown above. Each matches the
    /// default `Configuration.equalizerBandFrequencies` (8 bands); a
    /// configuration with a different band count needs a custom preset.
    static let builtIn: [EqualizerPreset] = [
        .flat, .rock, .pop, .jazz, .classical, .bassBoost, .trebleBoost, .vocal, .electronic, .acoustic
    ]
}
