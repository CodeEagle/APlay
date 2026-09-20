//
//  NowPlayingView.swift
//  APlayDemo
//

import SwiftUI
import APlay

struct NowPlayingView: View {
    @ObservedObject var player: DemoPlayer
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 18) {
            cover
            titleBlock
            progress
            transport
            airPlay
            loopChips
        }
        .cardStyle()
    }

    private var cover: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: player.coverPalette.primary).opacity(0.5))
                .frame(width: 208, height: 208)
                .blur(radius: 46)

            Image(uiImage: player.cover ?? CoverArt.image(forSeed: "APlay"))
                .resizable()
                .scaledToFill()
                .frame(width: 208, height: 208)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 22, y: 14)
        }
        .scaleEffect(player.state.isPlaying ? 1.0 : 0.94)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.state.isPlaying)
    }

    private var titleBlock: some View {
        VStack(spacing: 5) {
            Text(player.nowPlayingTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text([player.nowPlayingArtist, player.nowPlayingAlbum]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(1)
        }
        .id(player.nowPlayingTitle + player.nowPlayingArtist)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.35), value: player.nowPlayingTitle)
    }

    private var progress: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { min(player.currentTime, max(player.duration, 1)) },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { isScrubbing = $0 }
            )
            .tint(Color(uiColor: player.coverPalette.accent))
            .disabled(!player.isSeekable && player.duration <= 0)

            HStack {
                Text(TimeFormat.string(from: player.currentTime))
                Spacer()
                if let buffering = player.buffering {
                    Label("buffering \(Int(buffering * 100))%",
                          systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Text(TimeFormat.string(from: player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var transport: some View {
        HStack(spacing: 34) {
            Button(action: player.previous) {
                Image(systemName: "backward.fill")
                    .font(.title)
            }
            .accessibilityLabel("Previous track")

            Button(action: player.toggle) {
                Image(systemName: player.state.isPlaying
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64, weight: .regular))
            }
            .accessibilityLabel(player.state.isPlaying ? "Pause" : "Play")

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
            .accessibilityLabel("Next track")
        }
        .foregroundStyle(.white)
        .symbolRenderingMode(.hierarchical)
    }

    private var loopChips: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(player.supportedLoopPatterns.enumerated()), id: \.offset) { _, pattern in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            player.loopPattern = pattern
                        }
                    } label: {
                        Text(label(for: pattern))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                player.loopPattern == pattern
                                ? Color.accentColor.opacity(0.9)
                                : Color.white.opacity(0.08),
                                in: Capsule()
                            )
                            .foregroundStyle(player.loopPattern == pattern
                                             ? .black : .white)
                    }
                }
            }

            Button {
                withAnimation(.spring(response: 0.3)) {
                    player.gaplessEnabled.toggle()
                }
            } label: {
                Label(player.gaplessEnabled ? "Gapless on" : "Gapless off",
                      systemImage: player.gaplessEnabled
                      ? "infinity.circle.fill" : "infinity.circle")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(player.gaplessEnabled
                                ? Color.green.opacity(0.28)
                                : Color.white.opacity(0.08),
                                in: Capsule())
                    .foregroundStyle(player.gaplessEnabled ? .green : .white)
            }
        }
    }

    private var airPlay: some View {
        HStack(spacing: 8) {
            AirPlayRoutePicker()
                .frame(width: 30, height: 30)
            AirPlayRouteLabel()
            Spacer()
        }
    }

    private func label(for pattern: PlayList.LoopPattern) -> String {
        switch pattern {
        case .single: return "Single"
        case .order: return "Order"
        case .random: return "Random"
        case .stopWhenAllPlayed: return "Stop at end"
        }
    }
}
