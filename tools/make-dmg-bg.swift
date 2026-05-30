#!/usr/bin/env swift
// Render the DMG installer background.
//
// Usage: tools/make-dmg-bg.swift <output-png-path>
//
// Output is a 540×380 PNG showing:
//   - Drop-shadow placeholder for the app icon (left)
//   - Big arrow pointing right
//   - Drop-shadow placeholder for the /Applications folder (right)
//   - One-line instruction at the top
//
// Re-run if you change wording or layout. The generated PNG is committed to
// Resources/dmg-background.png; we don't regenerate it during every release.

import AppKit
import CoreGraphics
import CoreText
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-bg.swift <out.png>\n".utf8))
    exit(2)
}
let outPath = CommandLine.arguments[1]

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

// NOTE: when changing the app brand (QuotaMonitor/Core/Branding.swift),
// update this title string and re-run this script to regenerate the PNG.
let title = "Drag QuotaMonitor into your Applications folder"
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

let subtitle = "First launch: right-click → Open"
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

let foot = "ad-hoc signed · macOS will ask once on first launch"
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
