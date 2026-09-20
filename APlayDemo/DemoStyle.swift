//
//  DemoStyle.swift
//  APlayDemo
//
//  Shared presentation helpers so every section of the demo reads as one
//  designed page rather than a column of stock lists.
//

import SwiftUI

extension View {
    /// The frosted card every section sits in.
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
    }

    /// Small label above a card's contents.
    func sectionTitle(_ text: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// Badges used by the format matrix and the capability list.
struct Badge: View {
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
