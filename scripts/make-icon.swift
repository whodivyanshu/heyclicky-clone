#!/usr/bin/env swift
// Draws the Jarvis logo as vector art at every macOS icon size, then builds Resources/AppIcon.icns.
// Run from the project root: swift scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
        green: CGFloat(hex >> 8 & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// A superellipse, which gives the smooth continuous corners of a macOS icon.
func squircle(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let exponent = 5.0
    let a = rect.width / 2, b = rect.height / 2
    for step in 0...720 {
        let t = Double(step) / 720 * 2 * .pi
        let x = rect.midX + a * CGFloat(copysign(pow(abs(cos(t)), 2 / exponent), cos(t)))
        let y = rect.midY + b * CGFloat(copysign(pow(abs(sin(t)), 2 / exponent), sin(t)))
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(_ context: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(in: tile)

    // The black tile, with the soft drop shadow macOS icons carry.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.38))
    context.addPath(tilePath)
    context.setFillColor(color(0x000000))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.setFillColor(color(0x000000))
    context.fill(tile)
    // A faint sheen at the top, so the tile has some depth without looking gray.
    context.drawLinearGradient(
        gradient([color(0xFFFFFF, 0.09), color(0xFFFFFF, 0)], [0, 1]),
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 560),
        options: []
    )
    context.addPath(tilePath)
    context.setLineWidth(5)
    context.setStrokeColor(color(0xFFFFFF, 0.22))
    context.strokePath()
    context.restoreGState()

    // The J.
    let letter = CGMutablePath()
    letter.move(to: CGPoint(x: 610, y: 540))
    letter.addLine(to: CGPoint(x: 610, y: 410))
    letter.addArc(center: CGPoint(x: 490, y: 410), radius: 120, startAngle: 0, endAngle: .pi, clockwise: true)
    context.saveGState()
    context.addPath(letter)
    context.setLineCap(.round)
    context.setLineWidth(118)
    context.setStrokeColor(color(0xFFFFFF))
    context.strokePath()
    context.restoreGState()

    // The spark that dots it, and that animates inside the island.
    let center = CGPoint(x: 610, y: 735)
    let reach: CGFloat = 92, waist: CGFloat = 20
    let spark = CGMutablePath()
    spark.move(to: CGPoint(x: center.x, y: center.y + reach))
    spark.addQuadCurve(to: CGPoint(x: center.x + reach, y: center.y), control: CGPoint(x: center.x + waist, y: center.y + waist))
    spark.addQuadCurve(to: CGPoint(x: center.x, y: center.y - reach), control: CGPoint(x: center.x + waist, y: center.y - waist))
    spark.addQuadCurve(to: CGPoint(x: center.x - reach, y: center.y), control: CGPoint(x: center.x - waist, y: center.y - waist))
    spark.addQuadCurve(to: CGPoint(x: center.x, y: center.y + reach), control: CGPoint(x: center.x - waist, y: center.y + waist))
    context.saveGState()
    context.addPath(spark)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()
}

func renderPNG(pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(context)
    graphics.flushGraphics()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let manager = FileManager.default
let iconset = manager.temporaryDirectory.appendingPathComponent("Jarvis-\(UUID().uuidString).iconset")
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: iconset) }

for size in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try renderPNG(pixels: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try renderPNG(pixels: 1024, to: URL(fileURLWithPath: "Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
