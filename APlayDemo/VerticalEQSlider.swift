//
//  VerticalEQSlider.swift
//  APlayDemo
//
//  A bespoke vertical slider for the equalizer bands. The stock `Slider`'s
//  capsule track reads as a plain white pill on the demo's dark cards, so this
//  draws the track and knob by hand: a gradient fill from the 0 dB midline up
//  (or down) to the knob, a tick at unity gain, and a knob that lifts when
//  dragged. Dragging anywhere on the track jumps the knob there.
//

import SwiftUI

struct VerticalEQSlider: View {
    let value: Float
    let range: ClosedRange<Float>
    let accent: Color
    let onChanged: (Float) -> Void

    @State private var isDragging = false

    private let trackWidth: CGFloat = 30
    private let knobSize: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let lower = Float(range.lowerBound)
            let upper = Float(range.upperBound)
            let span = upper - lower
            let knobY = position(of: value, height: height, lower: lower, span: span)
            let zeroY = position(of: 0, height: height, lower: lower, span: span)
            let fillTop = min(knobY, zeroY)
            let fillHeight = max(knobY, zeroY) - fillTop

            ZStack {
                // Track
                Capsule()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 6)

                // Gain fill, from the 0 dB line to the knob
                if fillHeight > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.55), accent],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 6, height: fillHeight)
                        .offset(y: fillTop - height / 2 + fillHeight / 2)
                }

                // 0 dB tick
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 12, height: 1.5)
                    .offset(y: zeroY - height / 2)

                // Knob
                ZStack {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
                    Circle()
                        .stroke(accent.opacity(0.9), lineWidth: 2.5)
                        .scaleEffect(0.62)
                }
                .frame(width: knobSize, height: knobSize)
                .scaleEffect(isDragging ? 1.14 : 1)
                .animation(.easeOut(duration: 0.12), value: isDragging)
                .offset(y: knobY - height / 2)
            }
            .frame(width: trackWidth)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let clamped = min(max(0, drag.location.y), height)
                        let normalized = 1 - Float(clamped / height)
                        onChanged(lower + normalized * span)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(width: trackWidth + 8)
    }

    /// Maps a gain value onto a vertical offset within a track of `height`,
    /// clamped to the track's ends.
    private func position(of value: Float, height: CGFloat, lower: Float, span: Float) -> CGFloat {
        let normalized = min(max(0, (value - lower) / span), 1)
        return height * CGFloat(1 - normalized)
    }
}
