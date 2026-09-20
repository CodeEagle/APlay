//
//  AirPlayRoutePicker.swift
//  APlayDemo
//
//  An in-app AirPlay route picker (`AVRoutePickerView`) so the demo can hand
//  playback to an AirPlay 2 receiver without dropping into Control Center.
//  The system lock-screen / Control Center picker keeps working too — this
//  just surfaces the same route table inside NowPlayingView, which also makes
//  the AirPlay path obvious to anyone reading the demo.
//

import AVFAudio
import AVKit
import SwiftUI

/// The system AirPlay button, bridged to SwiftUI.
struct AirPlayRoutePicker: UIViewRepresentable {
    var tint: Color = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(tint)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(tint)
        uiView.activeTintColor = UIColor(tint)
    }
}

/// Human-readable name of the active output route, refreshed whenever the
/// audio session route changes (AirPlay connect / disconnect, headset plug…).
struct AirPlayRouteLabel: View {
    @State private var name = AirPlayRouteLabel.current()

    var body: some View {
        Text(name)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
            .onReceive(
                NotificationCenter.default.publisher(
                    for: AVAudioSession.routeChangeNotification)
            ) { _ in
                name = AirPlayRouteLabel.current()
            }
    }

    static func current() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let output = outputs.first else { return "No output route" }
        if output.portType == .airPlay {
            return "AirPlay · \(output.portName)"
        }
        return output.portName
    }
}
