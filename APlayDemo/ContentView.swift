//
//  ContentView.swift
//  APlayDemo
//
//  One curated scroll: now playing on top, then every capability the library
//  ships, in the order a would-be adopter wants to see them.
//

import SwiftUI
import APlay

struct ContentView: View {
    @StateObject private var player = DemoPlayer()
    @State private var showEventLog = false

    var body: some View {
        ZStack {
            AmbientBackground(palette: player.coverPalette)

            ScrollView {
                VStack(spacing: 20) {
                    header
                    NowPlayingView(player: player)
                    FormatMatrixView(player: player)
                    EqualizerView(player: player)
                    FilePlaybackView(player: player)
                    IcyStreamTestView(player: player)
                    RemoteSourceView(player: player)
                    CapabilitiesView(player: player)
                    EventLogView(player: player, isExpanded: $showEventLog)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("APlay")
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(.white)
            Text("every playback capability, one demo")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.top, 8)
    }
}

/// The tinted, blurred backdrop that re-colours itself with the current cover.
struct AmbientBackground: View {
    let palette: CoverArt.Palette

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(uiColor: palette.base), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(uiColor: palette.primary).opacity(0.42))
                .frame(width: 380, height: 380)
                .blur(radius: 110)
                .offset(x: -90, y: -240)

            Circle()
                .fill(Color(uiColor: palette.accent).opacity(0.30))
                .frame(width: 320, height: 320)
                .blur(radius: 100)
                .offset(x: 120, y: 300)
        }
        .animation(.easeInOut(duration: 0.9), value: palette)
    }
}
