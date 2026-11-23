#!/usr/bin/env swift
// Draws the Code[Relay] DMG window background: the same black body, orange signal
// and engraved labels as the app icon (and Code[Dock]'s installer, which it follows).
// Usage: swift Scripts/ci/dmg-background.swift <out-dir>   → <out-dir>/background.png
// Coordinates are window points with a top-left origin, the same space Finder uses for
// icon positions, so the layout constants below match make-dmg.sh.
import AppKit

let width: CGFloat = 660, height: CGFloat = 400
let appCenter = CGPoint(x: 165, y: 215), appsCenter = CGPoint(x: 495, y: 215)   // make-dmg.sh uses these

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let body = rgb(0x0b0b0c), bodyLow = rgb(0x000000), engrave = rgb(0x8c8c92), engraveLight = rgb(0x2b2b30)
let display = rgb(0x0d0d0f), lit = rgb(0xf2f2f0), ghost = rgb(0x2b2b30), signal = rgb(0xff5a1f)

func text(_ s: String, _ ctx: CGContext, at p: CGPoint, size: CGFloat, weight: NSFont.Weight = .medium,
          color: CGColor, kern: CGFloat = 1.2, align: NSTextAlignment = .left) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color)!, .kern: kern]
    let str = NSAttributedString(string: s, attributes: attrs)
    let w = str.size().width
    let x = align == .center ? p.x - w / 2 : align == .right ? p.x - w : p.x
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    str.draw(at: CGPoint(x: x, y: p.y))
    NSGraphicsContext.restoreGraphicsState()
}

func draw(_ ctx: CGContext) {
    // Black body (like the icon's lower half): a soft top-to-bottom falloff, then a faint horizontal grain.
    let grad = CGGradient(colorsSpace: nil, colors: [body, bodyLow] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    var seed: UInt64 = 0x5eed
    for y in stride(from: CGFloat(0), to: height, by: 1) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let a = CGFloat(seed >> 59) / 31 * 0.02
        ctx.setFillColor(rgb(seed & 1 == 0 ? 0xffffff : 0x000000, a))
        ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
    }

    // Display window: the black LCD strip across the top, like the device's screen.
    let screen = CGRect(x: 24, y: 22, width: width - 48, height: 64)
    ctx.addPath(CGPath(roundedRect: screen.insetBy(dx: -0.5, dy: -0.5), cornerWidth: 8.5, cornerHeight: 8.5, transform: nil))
    ctx.setFillColor(engraveLight); ctx.fillPath()                                      // hairline bezel
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.setFillColor(display); ctx.fillPath()
    text("CODE[RELAY]", ctx, at: CGPoint(x: screen.minX + 20, y: screen.minY + 13), size: 20, weight: .semibold,
         color: lit, kern: 2.4)
    text("DRAG THE APP ONTO APPLICATIONS", ctx, at: CGPoint(x: screen.minX + 20, y: screen.minY + 41), size: 9.5,
         color: signal, kern: 1.6)
    // Status lamps: one lit, the rest ghosted, like an unlit LCD segment row.
    for i in 0..<5 {
        let c = CGPoint(x: screen.maxX - 24 - CGFloat(i) * 14, y: screen.midY)
        ctx.setFillColor(i == 0 ? signal : ghost)
        ctx.fillEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
    }
    text("INSTALL", ctx, at: CGPoint(x: screen.maxX - 21, y: screen.minY + 12), size: 7.5, color: rgb(0x8c8c92),
         kern: 1.4, align: .right)

    // Drag path: a dashed orange run from the app to Applications, ending in a solid head.
    let y = appCenter.y, x0 = appCenter.x + 84, x1 = appsCenter.x - 92
    ctx.setStrokeColor(signal); ctx.setLineWidth(3); ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [0.1, 11])
    ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x1 - 6, y: y)); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.move(to: CGPoint(x: x1 + 10, y: y)); ctx.addLine(to: CGPoint(x: x1 - 4, y: y - 12))
    ctx.addLine(to: CGPoint(x: x1 - 4, y: y + 12)); ctx.closePath()
    ctx.setFillColor(signal); ctx.fillPath()

    // White label blocks under the icons: Finder draws item names in black, so they need a light
    // plate on the black body (like the keys in the icon).
    for c in [appCenter, appsCenter] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: c.x - 62, y: c.y + 72, width: 124, height: 22), cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.setFillColor(rgb(0xefefec)); ctx.fillPath()
    }

    // Bracket legends under each icon (below Finder's own name label).
    func bracket(_ cx: CGFloat, _ label: String) {
        let by: CGFloat = 330, half: CGFloat = 70
        ctx.setStrokeColor(engrave); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: cx - half, y: by - 6)); ctx.addLine(to: CGPoint(x: cx - half, y: by))
        ctx.addLine(to: CGPoint(x: cx + half, y: by)); ctx.addLine(to: CGPoint(x: cx + half, y: by - 6))
        ctx.strokePath()
        text(label, ctx, at: CGPoint(x: cx, y: by + 7), size: 8.5, color: engrave, kern: 1.6, align: .center)
    }
    bracket(appCenter.x, "01  DRAG")
    bracket(appsCenter.x, "02  DROP")

    // Grille: a small dot field in the bottom-right corner, plus the model line on the left.
    for r in 0..<4 { for c in 0..<8 {
        ctx.setFillColor(rgb(0xffffff, 0.14))
        ctx.fillEllipse(in: CGRect(x: width - 128 + CGFloat(c) * 12, y: height - 52 + CGFloat(r) * 9, width: 3.4, height: 3.4))
    } }
    text("CODING AGENTS · ANY DEVICE · macOS 14+", ctx, at: CGPoint(x: 26, y: height - 30), size: 7.5, color: engrave, kern: 1.4)
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.translateBy(x: 0, y: height * scale); ctx.scaleBy(x: scale, y: -scale)   // top-left origin
    draw(ctx)
    return rep
}

guard CommandLine.arguments.count >= 2 else { fputs("usage: dmg-background.swift <out-dir>\n", stderr); exit(1) }
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
// One PNG at 1x, 72 dpi. Finder on macOS 26 draws a DMG background at its pixel size (it
// ignores the 2x image of a multi-resolution TIFF and the dpi of a 2x PNG).
let out = dir.appendingPathComponent("background.png")
try render(scale: 1).representation(using: .png, properties: [:])!.write(to: out)
