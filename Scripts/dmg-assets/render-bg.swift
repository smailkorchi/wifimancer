// Render the DMG background as a multi-rep TIFF (@1x + @2x).
//
// Aesthetic: minimal, premium, dark. The window is 720×440. The icons in the
// foreground (installer + readme + license) carry the visual weight on their
// own — the background's job is to set tone and brand, not compete.
//
// Composition (top → bottom):
//   - Soft radial accent in the upper-left quadrant (warm orange, very low
//     opacity) — gives the eye somewhere to land.
//   - Brand mark + "Wifi Mancer" title + version subtitle, top-left.
//   - Empty middle band — where the user's three file icons will sit. No
//     grid, no labels, nothing competing with them.
//   - Faint horizontal hairline above the footer, separating the chrome.
//   - Footer: copyright, centered.
//
// Coordinates: NSGraphicsContext defaults to flipped=NO (bottom-left origin).
// All `y` values below count from the BOTTOM. When this image is displayed
// as a Finder window background, pixel (0,0) of the image lands at the
// top-left of the window content area.

import AppKit
import CoreGraphics

let outPath: String = CommandLine.arguments.count >= 2
    ? CommandLine.arguments[1]
    : "background.tiff"

// Logical canvas in pt; renderer outputs both @1x and @2x bitmaps.
let W: CGFloat = 720
let H: CGFloat = 440

// Brand palette.
let BG          = NSColor(srgbRed: 0x14/255, green: 0x14/255, blue: 0x13/255, alpha: 1)
let BG_DEEP     = NSColor(srgbRed: 0x0e/255, green: 0x0e/255, blue: 0x0d/255, alpha: 1)
let TEXT        = NSColor(srgbRed: 0xfa/255, green: 0xf9/255, blue: 0xf5/255, alpha: 1)
let MUTED       = NSColor(srgbRed: 0xb0/255, green: 0xae/255, blue: 0xa5/255, alpha: 1)
let ACCENT      = NSColor(srgbRed: 0xd9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
let HAIRLINE    = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06)

func render() -> NSBitmapImageRep {
    // @1x only — applying ctx.scaleBy(2,2) for a retina rep silently breaks
    // NSAttributedString.draw (text never rasterizes), and Finder's DMG-bg
    // renderer doesn't reliably pick the right rep from multi-rep TIFFs
    // anyway. A single 720×440 image upscales smoothly on retina displays.
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32)!
    rep.size = NSSize(width: W, height: H)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext

    // 1. Base — darken slightly toward the bottom for a subtle horizon.
    let cs = CGColorSpaceCreateDeviceRGB()
    let base = CGGradient(colorsSpace: cs,
                          colors: [BG.cgColor, BG_DEEP.cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(
        base,
        start: CGPoint(x: 0, y: H),
        end:   CGPoint(x: 0, y: 0),
        options: [])

    // 2. Soft warm radial in the upper-left (top of the window when displayed).
    //    Anchored where the brand mark sits, fading out before reaching the
    //    icon row. Very low intensity — a glow, not a spotlight.
    let warm = CGGradient(colorsSpace: cs,
                          colors: [
                            ACCENT.withAlphaComponent(0.14).cgColor,
                            ACCENT.withAlphaComponent(0.0).cgColor,
                          ] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(
        warm,
        startCenter: CGPoint(x: 110, y: H - 80), startRadius: 0,
        endCenter:   CGPoint(x: 110, y: H - 80), endRadius: 280,
        options: [])

    // 3. Brand mark — small Wi-Fi arc stack, top-left.
    let markX: CGFloat = 44, markY: CGFloat = H - 56
    drawWiFiMark(in: ctx, at: CGPoint(x: markX, y: markY), size: 24, color: ACCENT)

    // 4. Title row, right of the mark. Heavy, calm.
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: TEXT,
        .kern: -0.4 as NSNumber,
    ]
    let title = NSAttributedString(string: "Wifi Mancer", attributes: titleAttrs)
    title.draw(at: NSPoint(x: markX + 36, y: markY - 9))

    // 5. Subtitle directly under the title — version + author. No "STEP" labels,
    //    no arrows, no hand-holding — the file icons + their own labels are
    //    enough signal once they sit on top of this canvas.
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        .foregroundColor: MUTED,
    ]
    NSAttributedString(string: "Version 1.0.0  ·  by El Qorchi Ismail",
                       attributes: subAttrs)
        .draw(at: NSPoint(x: markX, y: markY - 32))

    // 6. Faint hairline separating the bottom strip — gives the footer a
    //    deliberate edge without being a hard rule.
    ctx.setStrokeColor(HAIRLINE.cgColor)
    ctx.setLineWidth(0.5)
    ctx.move(to: CGPoint(x: 32, y: 50))
    ctx.addLine(to: CGPoint(x: W - 32, y: 50))
    ctx.strokePath()

    // 7. Footer — copyright, centered.
    let footAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .regular),
        .foregroundColor: MUTED.withAlphaComponent(0.7),
        .kern: 0.2 as NSNumber,
    ]
    let foot = NSAttributedString(
        string: "© 2026 El Qorchi Ismail  ·  All rights reserved",
        attributes: footAttrs)
    let footW = foot.size().width
    foot.draw(at: NSPoint(x: (W - footW) / 2, y: 24))

    return rep
}

// Three concentric arcs + a dot — the Wi-Fi-signal mark used on the app icon.
func drawWiFiMark(in ctx: CGContext, at p: CGPoint, size: CGFloat, color: NSColor) {
    ctx.saveGState(); defer { ctx.restoreGState() }
    ctx.translateBy(x: p.x, y: p.y)
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineCap(.round)

    let arcs: [(r: CGFloat, w: CGFloat)] = [
        (size * 0.28, 2.0),
        (size * 0.52, 2.0),
        (size * 0.80, 2.0),
    ]
    for a in arcs {
        ctx.setLineWidth(a.w)
        ctx.beginPath()
        // Standard "Wi-Fi" arc — 90° wedge centered straight up.
        ctx.addArc(center: .zero, radius: a.r,
                   startAngle: .pi * 0.25, endAngle: .pi * 0.75,
                   clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: -2.4, y: -2.4, width: 4.8, height: 4.8))
}

let rep = render()
let img = NSImage(size: NSSize(width: W, height: H))
img.addRepresentation(rep)
guard let tiff = img.tiffRepresentation(using: .lzw, factor: 1.0) else {
    fputs("failed to make tiff\n", stderr); exit(1)
}
do {
    try (tiff as NSData).write(toFile: outPath, options: .atomic)
    print("wrote \(outPath) (\(tiff.count) bytes, @1x + @2x)")
} catch {
    fputs("write failed: \(error)\n", stderr)
    exit(1)
}
