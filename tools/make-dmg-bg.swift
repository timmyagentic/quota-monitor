#!/usr/bin/env swift
// Render the DMG installer background.
//
// Usage: tools/make-dmg-bg.swift <output-png-path> [brand-display-name]
//
// The optional brand display name fills the "Drag <name> into your
// Applications folder" title. When omitted it is read from the single source
// of truth in QuotaMonitor/Core/Branding.swift (falling back to
// "Quota Monitor"), so renaming the app there flows through to the installer
// window automatically. make-dmg.sh regenerates this PNG from the current
// branding on every build; the committed Resources/dmg-background.png is just
// a fallback for environments without `swift`.
//
// Output is a 540×380 PNG showing:
//   - Drop-shadow placeholder for the app icon (left)
//   - Big arrow pointing right
//   - Drop-shadow placeholder for the /Applications folder (right)
//   - One-line instruction at the top

import AppKit
import CoreGraphics
import CoreText
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-bg.swift <out.png>\n".utf8))
    exit(2)
}
let outPath = CommandLine.arguments[1]

/// Resolve the brand display name used in the installer title.
/// Precedence: explicit CLI arg → `appDisplayName` in Branding.swift →
/// the "Quota Monitor" default. Keeps this generator in lockstep with the
/// rest of the build, which reads the same source of truth.
func resolveBrandDisplayName() -> String {
    if CommandLine.arguments.count >= 3 {
        let arg = CommandLine.arguments[2].trimmingCharacters(in: .whitespaces)
        if !arg.isEmpty { return arg }
    }
    // Branding.swift lives two levels up from this script (tools/ → repo root).
    let brandingURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // tools/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("QuotaMonitor/Core/Branding.swift")
    if let text = try? String(contentsOf: brandingURL, encoding: .utf8),
       let r = text.range(of: #"appDisplayName\s*=\s*""#,
                          options: .regularExpression) {
        let after = text[r.upperBound...]
        if let end = after.firstIndex(of: "\"") {
            let name = String(after[..<end]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
    }
    return "Quota Monitor"
}
let brandDisplayName = resolveBrandDisplayName()

let width: CGFloat = 540
let height: CGFloat = 380

let cs = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: bitmapInfo) else {
    FileHandle.standardError.write(Data("failed to create CGContext\n".utf8))
    exit(1)
}

// ---- background gradient (light, slightly cool) ---------------------------

let bgTop    = CGColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1.0)
let bgBottom = CGColor(red: 0.90, green: 0.91, blue: 0.94, alpha: 1.0)
let gradient = CGGradient(colorsSpace: cs,
                          colors: [bgTop, bgBottom] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: height),
                       end: CGPoint(x: 0, y: 0),
                       options: [])

// ---- title text (top) -----------------------------------------------------

// Driven by Branding.swift (or the optional CLI arg) so the installer
// instruction matches a rebranded DMG filename / volume title.
let title = "Drag \(brandDisplayName) into your Applications folder"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 16, weight: .medium),
    .foregroundColor: NSColor(white: 0.18, alpha: 1.0)
]
let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
let titleLine = CTLineCreateWithAttributedString(titleStr)
let titleBounds = CTLineGetImageBounds(titleLine, ctx)
ctx.textPosition = CGPoint(x: (width - titleBounds.width) / 2,
                           y: height - 50)
CTLineDraw(titleLine, ctx)

// ---- subtitle (small hint, below title) -----------------------------------

let subtitle = "Signed and notarized for direct launch"
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor(white: 0.45, alpha: 1.0)
]
let subStr = NSAttributedString(string: subtitle, attributes: subAttrs)
let subLine = CTLineCreateWithAttributedString(subStr)
let subBounds = CTLineGetImageBounds(subLine, ctx)
ctx.textPosition = CGPoint(x: (width - subBounds.width) / 2,
                           y: height - 75)
CTLineDraw(subLine, ctx)

// ---- arrow (middle, pointing right) ---------------------------------------
//
// The Finder will overlay the actual app icon (left) and the Applications
// alias (right) on top of this background, so the arrow lives BETWEEN their
// expected positions (which are set in osascript / make-dmg.sh).

let arrowColor = CGColor(red: 0.32, green: 0.36, blue: 0.45, alpha: 0.55)
ctx.setStrokeColor(arrowColor)
ctx.setFillColor(arrowColor)
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let arrowY: CGFloat = 180        // bottom-up coordinate; matches icon row
let arrowStartX: CGFloat = 215
let arrowEndX: CGFloat = 325
ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
ctx.strokePath()

// arrowhead — small filled triangle
ctx.beginPath()
ctx.move(to: CGPoint(x: arrowEndX + 18, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX, y: arrowY + 12))
ctx.addLine(to: CGPoint(x: arrowEndX, y: arrowY - 12))
ctx.closePath()
ctx.fillPath()

// ---- footnote (bottom) ----------------------------------------------------

let foot = "Developer ID signed · Sparkle updates stay automatic"
let footAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 10, weight: .regular),
    .foregroundColor: NSColor(white: 0.55, alpha: 1.0)
]
let footStr = NSAttributedString(string: foot, attributes: footAttrs)
let footLine = CTLineCreateWithAttributedString(footStr)
let footBounds = CTLineGetImageBounds(footLine, ctx)
ctx.textPosition = CGPoint(x: (width - footBounds.width) / 2, y: 30)
CTLineDraw(footLine, ctx)

// ---- save -----------------------------------------------------------------

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("ctx.makeImage failed\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG encode failed\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
FileHandle.standardError.write(Data("wrote \(outPath) (\(Int(width))×\(Int(height)))\n".utf8))
