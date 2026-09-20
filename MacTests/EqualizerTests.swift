//
//  EqualizerTests.swift
//  APlayTests
//
//  Pins the equalizer wiring: the AVAudioUnitEQ node is built from
//  `Configuration.equalizerBandFrequencies` with every band unbypassed, band
//  gains reach the audio unit, and presets apply atomically.
//

import AVFoundation
import XCTest
@testable import APlay

final class EqualizerTests: XCTestCase {

    /// The default `Configuration.equalizerBandFrequencies`.
    private let frequencies: [Float] = [50, 100, 200, 400, 800, 1600, 2600, 16000]
    private func makeConfig(_ frequencies: [Float]? = nil) -> APlay.Configuration {
        if let frequencies {
            return APlay.Configuration(logPolicy: .disable, equalizerBandFrequencies: frequencies)
        }
        return APlay.Configuration(logPolicy: .disable)
    }

    // MARK: - Band layout

    func testEqualizerBandsFollowTheConfiguration() {
        let player = APlayer(config: makeConfig())
        let bands = player.equalizerBands
        XCTAssertEqual(bands.count, frequencies.count)
        XCTAssertEqual(bands.map { $0.frequency }, frequencies)
        // AVAudioUnitEQ ships every band bypassed, which would make the whole
        // node a no-op; the player unbypasses each one.
        XCTAssertTrue(bands.allSatisfy { $0.bypass == false })
        XCTAssertEqual(bands.first?.filterType, .lowShelf)
        XCTAssertEqual(bands.last?.filterType, .highShelf)
        XCTAssertTrue(bands.dropFirst().dropLast().allSatisfy { $0.filterType == .parametric })
    }

    func testEqualizerHonoursACustomBandLayout() {
        let custom: [Float] = [60, 250, 1000, 4000, 12000]
        let player = APlayer(config: makeConfig(custom))
        let bands = player.equalizerBands
        XCTAssertEqual(bands.count, custom.count)
        XCTAssertEqual(bands.map { $0.frequency }, custom)
        XCTAssertEqual(bands.first?.filterType, .lowShelf)
        XCTAssertEqual(bands.last?.filterType, .highShelf)
        XCTAssertTrue(bands.dropFirst().dropLast().allSatisfy { $0.filterType == .parametric })
    }

    // MARK: - Band gain

    func testSetEqualizerBandGainAppliesToTheAudioUnit() {
        let player = APlayer(config: makeConfig())
        player.setEqualizerBandGain(index: 2, gain: 3.5)
        XCTAssertEqual(player.equalizerBands[2].gain, 3.5)
        XCTAssertEqual(player.equalizerBandGains[2], 3.5)
        // Out-of-range indices are ignored rather than trapping.
        player.setEqualizerBandGain(index: 99, gain: 6)
        player.setEqualizerBandGain(index: -1, gain: 6)
        XCTAssertEqual(player.equalizerBandGains.filter { $0 != 0 }.count, 1)
    }

    func testSetEqualizerBandGainClampsToTheAudioUnitRange() {
        let player = APlayer(config: makeConfig())
        player.setEqualizerBandGain(index: 0, gain: 200)
        XCTAssertEqual(player.equalizerBands[0].gain, 24)
        player.setEqualizerBandGain(index: 0, gain: -200)
        XCTAssertEqual(player.equalizerBands[0].gain, -96)
    }

    func testBandGainSetThroughThePublicAPIIsReadableBack() {
        let player = APlay(configuration: makeConfig())
        player.setEqualizerBandGain(-4, at: 4)
        XCTAssertEqual(player.equalizerGains[4], -4)
    }

    // MARK: - Presets

    func testApplyEqualizerPresetSetsEveryBand() {
        let player = APlay(configuration: makeConfig())
        XCTAssertTrue(player.applyEqualizerPreset(.rock))
        XCTAssertEqual(player.equalizerGains, EqualizerPreset.rock.gains)
    }

    func testFlatPresetResetsPreviousGains() {
        let player = APlay(configuration: makeConfig())
        _ = player.applyEqualizerPreset(.bassBoost)
        XCTAssertEqual(player.equalizerGains, EqualizerPreset.bassBoost.gains)
        _ = player.applyEqualizerPreset(.flat)
        XCTAssertEqual(player.equalizerGains, EqualizerPreset.flat.gains)
    }

    func testPresetWithMismatchedBandCountIsIgnored() {
        let player = APlay(configuration: makeConfig())
        _ = player.applyEqualizerPreset(.rock)
        let stray = EqualizerPreset(name: "Stray", gains: [0, 0, 0])
        XCTAssertFalse(player.applyEqualizerPreset(stray))
        // The previously applied curve survives a mismatched preset.
        XCTAssertEqual(player.equalizerGains, EqualizerPreset.rock.gains)
    }

    func testBuiltInPresetsMatchTheDefaultBandCount() {
        // The library ships presets shaped for the default 8-band layout; a
        // configuration with a different band count needs a custom preset.
        for preset in EqualizerPreset.builtIn {
            XCTAssertEqual(preset.gains.count, frequencies.count, "\(preset.name) must match the default band count")
        }
    }
}
