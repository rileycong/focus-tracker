// Regenerates the app icon: sources/FocusTracker/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// (issue #48). Run from the repo root:  swift scripts/generate-icon.swift
//
// The design = the #24 countdown language, re-inked in the #35/#48 countdown
// red: full-bleed dark square (the system applies the macOS squircle mask),
// a 10%-white track, and a 265° progress arc with round caps in the EXACT
// focus-ring color — DesignTokens.focusRing = (1.0, 0.45, 0.42). Keep the
// literals in sync with DesignTokens.swift when they change.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// DesignTokens parity (do not change independently):
let backgroundGray: CGFloat = 0.12            // DesignTokens.background (white: 0.12)
let trackAlpha: CGFloat = 0.10                // 10% white track
let focusRingRed: CGFloat = 1.0               // DesignTokens.focusRing
let focusRingGreen: CGFloat = 0.45            //   (1.0, 0.45, 0.42)
let focusRingBlue: CGFloat = 0.42             //

let size: CGFloat = 1024
let radius: CGFloat = 330
let lineWidth: CGFloat = 72
let progressDegrees: CGFloat = 265            // the countdown language from #24

let context = CGContext(
    data: nil,
    width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Background: full-bleed dark square.
context.setFillColor(CGColor(srgbRed: backgroundGray, green: backgroundGray, blue: backgroundGray, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

let center = CGPoint(x: size / 2, y: size / 2)
context.setLineCap(.round)
context.setLineWidth(lineWidth)

// Track: 10% white, full circle.
context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: trackAlpha))
context.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
context.strokePath()

// Progress: the focus-ring red. The 95° gap sits in the FIRST quarter
// (12→3 o'clock), like the #24 original (user-confirmed): the arc starts at
// 3 o'clock and sweeps 265° clockwise — in CoreGraphics, 0° = 3 o'clock,
// clockwise = decreasing angle, so the end is 0° − 265° ≡ 95° (just past 12).
context.setStrokeColor(CGColor(srgbRed: focusRingRed, green: focusRingGreen, blue: focusRingBlue, alpha: 1))
context.addArc(
    center: center, radius: radius,
    startAngle: 0,
    endAngle: -progressDegrees * .pi / 180,
    clockwise: true)
context.strokePath()

// Write the PNG over the AppIcon.appiconset slot.
let image = context.makeImage()!
let output = URL(fileURLWithPath: "Sources/FocusTracker/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let destination = CGImageDestinationCreateWithURL(
    output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("Failed to write \(output.path)\n".data(using: .utf8)!)
    exit(1)
}
print("Icon written: \(output.path) (\(Int(size))×\(Int(size)), arc \(Int(progressDegrees))°, rgb(\(focusRingRed), \(focusRingGreen), \(focusRingBlue)))")