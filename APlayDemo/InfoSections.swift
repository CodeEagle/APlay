//
//  InfoSections.swift
//  APlayDemo
//
//  Remote streaming, the capability/config overview, and the live event log —
//  grouped here because each is a single card with no shared state.
//

import SwiftUI
import APlay

// MARK: - Remote source

struct RemoteSourceView: View {
    @ObservedObject var player: DemoPlayer
    @State private var input = TrackLibrary.remoteURL.absoluteString
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Remote streaming", symbol: "antenna.radiowaves.left.and.right")

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.white.opacity(0.55))
                TextField("HTTP audio URL", text: $input)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(.white)
                    .focused($isFocused)
            }
            .padding(12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))

            Button {
                guard let url = URL(string: input.trimmingCharacters(in: .whitespaces)) else { return }
                isFocused = false
                player.playRemote(url)
            } label: {
                Label("Stream", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.black)
            }

            Text("Plays through the same engine as local files — HTTP range requests, "
                 + "reconnect-on-server-error and the cache policy all apply.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
        .cardStyle()
    }
}

// MARK: - Capabilities

struct CapabilitiesView: View {
    @ObservedObject var player: DemoPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("What the library handles", symbol: "checkmark.seal.fill")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 8) {
                ForEach(capabilities, id: \.title) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }

            Divider().opacity(0.25)

            configSummary
        }
        .cardStyle()
    }

    private var configSummary: some View {
        let cfg = player.config
        return VStack(alignment: .leading, spacing: 5) {
            Text("Active configuration")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            summaryRow("Cache policy", cachePolicyText(cfg))
            summaryRow("Decoder chain", "APlayExtras file router → streaming decoder")
            summaryRow("Equalizer bands", "\(cfg.equalizerBandFrequencies.count)")
            summaryRow("Gapless", cfg.isGaplessPlaybackEnabled ? "enabled" : "disabled")
            summaryRow("Remote commands", cfg.isEnabledRemoteCommandHandling ? "on" : "off")
            summaryRow("Volume mixer", cfg.isEnabledVolumeMixer ? "on" : "off")
            summaryRow("Interrupt handling", cfg.isAutoHandlingInterruptEvent ? "automatic" : "manual")
            summaryRow("User agent", cfg.userAgent)
        }
    }

    private func summaryRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.caption2.weight(.medium).monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func cachePolicyText(_ cfg: APlay.Configuration) -> String {
        switch cfg.cachePolicy {
        case .disable: return "disabled"
        case .enable: return "enabled"
        @unknown default: return "custom"
        }
    }

    private struct Item { let title: String }
    private let capabilities: [Item] = [
        .init(title: "Lock screen, Control Center & AirPlay 2 remote commands"),
        .init(title: "Now Playing info injection (cover art included)"),
        .init(title: "Background audio task management"),
        .init(title: "Automatic audio-session & interruption handling"),
        .init(title: "Gapless track handoffs with preloading"),
        .init(title: "HTTP streaming with reconnect & retry"),
        .init(title: "ID3/FLAC metadata parsing"),
        .init(title: "Pluggable streamer, decoder, parser & logger"),
        .init(title: "Disk cache with size & naming policies"),
        .init(title: "Volume mixer built into the audio graph"),
        .init(title: "Proxy, custom headers & user agent"),
        .init(title: "8-band equalizer with presets"),
    ]
}

// MARK: - Event log

struct EventLogView: View {
    @ObservedObject var player: DemoPlayer
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack {
                    sectionTitle("Event pipeline", symbol: "dot.radiowaves.left.and.right")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(player.entries.suffix(120)) { entry in
                            Text(entry.text)
                                .font(.caption2.monospaced())
                                .foregroundStyle(entry.isFramework
                                                 ? .white.opacity(0.5)
                                                 : .white.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 260)

                HStack {
                    Text("\(player.entries.count) entries")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Button("Clear", role: .destructive) {
                        player.clearLog()
                    }
                    .font(.caption2)
                }
            } else {
                Text(player.entries.last?.text ?? "Events and internal log lines land here…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .cardStyle()
    }
}
