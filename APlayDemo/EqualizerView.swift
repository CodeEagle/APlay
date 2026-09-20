//
//  EqualizerView.swift
//  APlayDemo
//
//  The built-in 8-band equalizer: presets apply in one tap, sliders edit
//  individual bands live, and the values shown are read straight back from the
//  player so the UI can never disagree with the engine.
//

import SwiftUI
import APlay

struct EqualizerView: View {
    @ObservedObject var player: DemoPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Equalizer · \(player.bandFrequencies.count) bands",
                         symbol: "slider.vertical.3")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(player.presets, id: \.name) { preset in
                        Button {
                            player.applyPreset(preset)
                        } label: {
                            Text(preset.name)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.08), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(player.bandFrequencies.enumerated()), id: \.offset) { index, hz in
                    VStack(spacing: 6) {
                        Slider(value: Binding(
                            get: { index < player.bandGains.count ? player.bandGains[index] : 0 },
                            set: { player.setBandGain(at: index, to: $0) }
                        ), in: -12...12)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30, height: 130)
                        .tint(Color(uiColor: player.coverPalette.accent))

                        Text(TimeFormat.frequency(hz))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .cardStyle()
    }
}
