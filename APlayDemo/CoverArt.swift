//
//  CoverArt.swift
//  APlayDemo
//
//  Generated cover art: the demo ships no artwork, so every track gets a
//  deterministic gradient drawn from its name. The same palette also drives
//  the ambient background glow, so the whole screen re-tints per track.
//

import UIKit

enum CoverArt {

    /// A three-colour palette derived deterministically from a seed string.
    struct Palette: Equatable, Sendable {
        let base: UIColor
        let primary: UIColor
        let accent: UIColor
    }

    /// Stable hash (djb2) so a track keeps its artwork across launches.
    private static func hash(_ seed: String) -> UInt64 {
        var value: UInt64 = 5381
        for byte in seed.utf8 {
            value = ((value << 5) &+ value) &+ UInt64(byte)
        }
        return value
    }

    static func palette(forSeed seed: String) -> Palette {
        let h = hash(seed)
        let hue = CGFloat((h % 360)) / 360.0
        let hue2 = CGFloat(((h >> 9) % 360)) / 360.0
        return Palette(
            base: UIColor(hue: hue, saturation: 0.34, brightness: 0.10, alpha: 1),
            primary: UIColor(hue: hue, saturation: 0.72, brightness: 0.62, alpha: 1),
            accent: UIColor(hue: hue2, saturation: 0.62, brightness: 0.78, alpha: 1)
        )
    }

    /// Draws the cover: a dark base, two overlapping radial glows and a soft
    /// diagonal streak — enough to look intentional at lock-screen size.
    static func image(forSeed seed: String,
                      size: CGSize = CGSize(width: 720, height: 720)) -> UIImage {
        let palette = palette(forSeed: seed)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let ctx = context.cgContext
            let rect = CGRect(origin: .zero, size: size)

            ctx.setFillColor(palette.base.cgColor)
            ctx.fill(rect)

            // Large primary glow anchored off-centre top-left.
            drawRadial(in: rect,
                       center: CGPoint(x: size.width * 0.32, y: size.height * 0.28),
                       radius: size.width * 0.72,
                       color: palette.primary, ctx: ctx)

            // Smaller accent glow bottom-right for depth.
            drawRadial(in: rect,
                       center: CGPoint(x: size.width * 0.74, y: size.height * 0.80),
                       radius: size.width * 0.5,
                       color: palette.accent, ctx: ctx)

            // Diagonal streak.
            ctx.saveGState()
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: -.pi / 5)
            let streak = CGRect(x: -size.width, y: -size.height * 0.06,
                                width: size.width * 2, height: size.height * 0.12)
            let streakColors = [UIColor.white.withAlphaComponent(0.16).cgColor,
                                UIColor.white.withAlphaComponent(0.0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: streakColors,
                                         locations: [0, 1]) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: streak.minX, y: streak.midY),
                                       end: CGPoint(x: streak.maxX, y: streak.midY),
                                       options: [])
            }
            ctx.restoreGState()

            // Inner vignette so the edges read as a frame.
            drawRadial(in: rect,
                       center: CGPoint(x: size.width / 2, y: size.height / 2),
                       radius: size.width * 0.62,
                       color: UIColor.black.withAlphaComponent(0.28), ctx: ctx)
        }
    }

    private static func drawRadial(in rect: CGRect, center: CGPoint, radius: CGFloat,
                                   color: UIColor, ctx: CGContext) {
        let colors = [color.withAlphaComponent(0.55).cgColor,
                      color.withAlphaComponent(0.0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors,
                                        locations: [0, 1]) else { return }
        ctx.drawRadialGradient(gradient,
                               startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius,
                               options: [.drawsAfterEndLocation])
    }
}
