//
//  FormatMatrixView.swift
//  APlayDemo
//
//  The live format-compatibility matrix: every bundled container in one list,
//  each row badged with the decoder route that serves it and the result of
//  actually playing it on this device.
//

import APlay
import SwiftUI

struct FormatMatrixView: View {
    @ObservedObject var player: DemoPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Format matrix", symbol: "square.grid.2x2")

            HStack(spacing: 8) {
                Button {
                    player.playMatrix()
                } label: {
                    Label("Play all, gapless", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.black)
                }
                Text("\(TrackLibrary.local.count) files")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.trailing, 4)
            }

            VStack(spacing: 2) {
                ForEach(Array(TrackLibrary.local.enumerated()), id: \.element.id) { index, track in
                    row(for: track, at: index)
                    if index < TrackLibrary.local.count - 1 {
                        Divider().opacity(0.25)
                    }
                }
            }
        }
        .cardStyle()
    }

    private func row(for track: Track, at index: Int) -> some View {
        let status = index < player.trackStatuses.count ? player.trackStatuses[index] : .idle
        let isCurrent = index == player.playingIndex && player.source == .matrix

        return Button {
            player.playTrack(at: index)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(uiColor: player.coverPalette.primary).opacity(0.35))
                        .frame(width: 34, height: 34)
                    if isCurrent && player.state.isPlaying {
                        Image(systemName: "waveform")
                            .foregroundStyle(.white)
                            .font(.callout)
                    } else {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(track.format)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if track.route != .native {
                            Badge(text: track.route.badge, color: .orange)
                        }
                    }
                    Text(track.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(2)
                }
                .multilineTextAlignment(.leading)

                Spacer()

                Text(statusLabel(for: track, status: status))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(for: track, status: status))
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A format iOS cannot decode is not a framework bug — the matrix shows it
    /// as unsupported instead of letting the red `failed` badge mislead.
    private func statusLabel(for track: Track, status: TrackLibrary.Status) -> String {
        if status == .failed,
           TrackLibrary.iosUnsupportedFormats.contains(track.format) {
            return "iOS ✗"
        }
        return status.rawValue
    }

    private func statusColor(for track: Track, status: TrackLibrary.Status) -> Color {
        if status == .failed,
           TrackLibrary.iosUnsupportedFormats.contains(track.format) {
            return .white.opacity(0.4)
        }
        return color(for: status)
    }

    private func color(for status: TrackLibrary.Status) -> Color {
        switch status {
        case .idle: return .white.opacity(0.4)
        case .playing: return .green
        case .played: return .white.opacity(0.75)
        case .failed: return .red
        }
    }
}
