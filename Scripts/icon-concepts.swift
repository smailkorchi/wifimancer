#!/usr/bin/env swift
// Renders polished Wifi Mancer app-icon candidates as 1024×1024 PNGs into
// Resources/icon-previews/. Round 2 — bigger hero elements, gradient bases,
// proper shadows + highlights, real lighting. Run from project root:
//   swift Scripts/icon-concepts.swift

import AppKit
import CoreGraphics

let projectRoot = FileManager.default.currentDirectoryPath
let outDir = "\(projectRoot)/Resources/icon-previews"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let S: CGFloat = 1024

// Brand palette — exact values from App/Theme/BrandColor.swift.
let dark    = NSColor(red: 0x14/255.0, green: 0x14/255.0, blue: 0x13/255.0, alpha: 1).cgColor
let darker  = NSColor(red: 0x05/255.0, green: 0x05/255.0, blue: 0x04/255.0, alpha: 1).cgColor
let surface = NSColor(red: 0x1c/255.0, green: 0x1b/255.0, blue: 0x19/255.0, alpha: 1).cgColor
let surfaceHi = NSColor(red: 0x2c/255.0, green: 0x2a/255.0, blue: 0x26/255.0, alpha: 1).cgColor
let light   = NSColor(red: 0xfa/255.0, green: 0xf9/255.0, blue: 0xf5/255.0, alpha: 1).cgColor
let cream   = NSColor(red: 0xf2/255.0, green: 0xee/255.0, blue: 0xe2/255.0, alpha: 1).cgColor
let creamHi = NSColor(red: 0xff/255.0, green: 0xfd/255.0, blue: 0xf6/255.0, alpha: 1).cgColor
let cut     = NSColor(red: 0xd9/255.0, green: 0x77/255.0, blue: 0x57/255.0, alpha: 1).cgColor
let cutHi   = NSColor(red: 0xf2/255.0, green: 0x9c/255.0, blue: 0x76/255.0, alpha: 1).cgColor
let cutLo   = NSColor(red: 0x8a/255.0, green: 0x44/255.0, blue: 0x2c/255.0, alpha: 1).cgColor
let trust   = NSColor(red: 0x88/255.0, green: 0x9d/255.0, blue: 0x6b/255.0, alpha: 1).cgColor

let cs = CGColorSpaceCreateDeviceRGB()

func a(_ c: CGColor, _ alpha: CGFloat) -> CGColor { c.copy(alpha: alpha)! }

// MARK: - canvas helpers

/// Paint a layered, lit dark background. Subtle radial light from upper
/// center suggests overhead studio lighting; vignette darkens the corners.
/// This is what makes the icon feel "lifted" instead of pasted on flat black.
func paintBackdrop(_ ctx: CGContext) {
    // Base dark vertical gradient (slightly lighter at top)
    let base = CGGradient(colorsSpace: cs,
                          colors: [surfaceHi, dark, darker] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(base,
                           start: CGPoint(x: S/2, y: S),
                           end:   CGPoint(x: S/2, y: 0),
                           options: [])
    // Soft radial light bloom from upper third
    let bloom = CGGradient(colorsSpace: cs,
                           colors: [a(creamHi, 0.10), a(creamHi, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(bloom,
                           startCenter: CGPoint(x: S/2, y: S * 0.78), startRadius: 0,
                           endCenter:   CGPoint(x: S/2, y: S * 0.78), endRadius:   S * 0.65,
                           options: [])
    // Inner edge vignette — darkens the squircle perimeter
    let vignette = CGGradient(colorsSpace: cs,
                              colors: [a(darker, 0), a(darker, 0.55)] as CFArray,
                              locations: [0.55, 1])!
    ctx.drawRadialGradient(vignette,
                           startCenter: CGPoint(x: S/2, y: S/2), startRadius: 0,
                           endCenter:   CGPoint(x: S/2, y: S/2), endRadius:   S * 0.72,
                           options: [])
}

/// Adds the diagonal "shine" line many premium app icons have — a thin
/// bright line top-left to bottom-right inside the squircle, suggesting
/// reflected light. Drawn last so it's above the foreground hero.
func paintShine(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.setStrokeColor(a(creamHi, 0.06))
    ctx.setLineWidth(1.5)
    ctx.move(to: CGPoint(x: S * 0.06, y: S * 0.94))
    ctx.addLine(to: CGPoint(x: S * 0.94, y: S * 0.06))
    ctx.strokePath()
    ctx.restoreGState()
}

func makeIcon(name: String, draw: (CGContext) -> Void) {
    guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }

    // Apple-style squircle clip — close approximation with a 22.37% rounded rect.
    let r = S * 0.2237
    let clipPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                          cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(clipPath)
    ctx.clip()

    paintBackdrop(ctx)
    draw(ctx)
    paintShine(ctx)

    guard let img = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: img)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("✓ \(name).png")
}

// MARK: - Concept 1 — BOLT  (refined "Bolt Through Wave")
// Hero is a single bold orange lightning bolt, centered, with a faint
// Wi-Fi pulse rendered behind it. The bolt has a vertical highlight
// gradient, a soft outer glow, and a darker inner shadow that gives
// real 3D dimension. Wi-Fi arcs are subtle so the bolt dominates.
makeIcon(name: "1_BOLT") { ctx in
    let cx = S/2, cy = S/2

    // Wi-Fi arcs faded in the background — concentric, cream low-alpha,
    // facing outward in a standard Wi-Fi grammar.
    ctx.setStrokeColor(a(cream, 0.32))
    ctx.setLineWidth(S * 0.045)
    ctx.setLineCap(.round)
    for i in 1...3 {
        let radius = CGFloat(i) * S * 0.115
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                   startAngle: .pi * 0.30, endAngle: .pi * 0.70, clockwise: false)
        ctx.strokePath()
    }
    // Wi-Fi origin dot (cream)
    let dotR = S * 0.028
    ctx.setFillColor(a(cream, 0.55))
    ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR*2, height: dotR*2))

    // Bolt path — bold zigzag, top-right to bottom-left, large enough to
    // dominate the canvas. Coordinates trace the outline of a stylized
    // lightning glyph.
    let bolt = CGMutablePath()
    bolt.move(to:    CGPoint(x: S * 0.72, y: S * 0.86))
    bolt.addLine(to: CGPoint(x: S * 0.36, y: S * 0.51))
    bolt.addLine(to: CGPoint(x: S * 0.55, y: S * 0.49))
    bolt.addLine(to: CGPoint(x: S * 0.28, y: S * 0.14))
    bolt.addLine(to: CGPoint(x: S * 0.66, y: S * 0.49))
    bolt.addLine(to: CGPoint(x: S * 0.47, y: S * 0.51))
    bolt.addLine(to: CGPoint(x: S * 0.85, y: S * 0.86))
    bolt.closeSubpath()

    // Outer drop shadow / glow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.018),
                  blur: S * 0.06, color: a(cutLo, 0.85))
    ctx.setFillColor(cut)
    ctx.addPath(bolt)
    ctx.fillPath()
    ctx.restoreGState()

    // Vertical highlight gradient on the bolt
    let boltGrad = CGGradient(colorsSpace: cs,
                              colors: [cutHi, cut, cutLo] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.saveGState()
    ctx.addPath(bolt)
    ctx.clip()
    ctx.drawLinearGradient(boltGrad,
                           start: CGPoint(x: 0, y: S),
                           end:   CGPoint(x: 0, y: 0),
                           options: [])
    ctx.restoreGState()

    // Bolt rim — soft cream stroke gives definition
    ctx.addPath(bolt)
    ctx.setStrokeColor(a(creamHi, 0.6))
    ctx.setLineWidth(S * 0.005)
    ctx.strokePath()

    // Bolt inner highlight along the upper-left edge — single bright stroke
    // along the path's "lit" side, hinting at sculpted depth.
    let hl = CGMutablePath()
    hl.move(to:    CGPoint(x: S * 0.30, y: S * 0.18))
    hl.addLine(to: CGPoint(x: S * 0.59, y: S * 0.49))
    ctx.addPath(hl)
    ctx.setStrokeColor(a(creamHi, 0.55))
    ctx.setLineWidth(S * 0.012)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

// MARK: - Concept 2 — SLASH  (minimalist Wi-Fi with single severance line)
// Three big bold cream Wi-Fi arcs, then a single thick orange slash going
// diagonally from upper-left to lower-right. The slash visually breaks the
// arcs (rendered as gaps in the cream where the slash crosses). Far more
// minimal than the bolt — pure geometry.
makeIcon(name: "2_SLASH") { ctx in
    let cx = S * 0.43, cy = S/2

    // Big bold Wi-Fi arcs in cream — much heavier than the previous
    // version so they dominate at small sizes.
    ctx.setStrokeColor(cream)
    ctx.setLineWidth(S * 0.075)
    ctx.setLineCap(.round)
    for i in 1...3 {
        let radius = CGFloat(i) * S * 0.135
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                   startAngle: -.pi/3, endAngle: .pi/3, clockwise: false)
        ctx.strokePath()
    }
    // Origin dot
    let dotR = S * 0.040
    ctx.setFillColor(cream)
    ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR*2, height: dotR*2))

    // Slash mask — punch out the arcs along the slash band so the slash
    // visibly severs them. Achieved by drawing the slash as an opaque
    // background-colored band BEFORE drawing the slash itself.
    let slashAngle: CGFloat = -.pi / 4   // upper-left to lower-right
    let slashLen   = S * 1.4
    let slashThick = S * 0.18
    let mid = CGPoint(x: S * 0.55, y: S/2)
    let dx = cos(slashAngle) * slashLen / 2
    let dy = sin(slashAngle) * slashLen / 2
    let a1 = CGPoint(x: mid.x - dx, y: mid.y - dy)
    let a2 = CGPoint(x: mid.x + dx, y: mid.y + dy)

    // 1) cut a "trench" in the wave by overpainting with backdrop tone
    ctx.saveGState()
    ctx.setStrokeColor(dark)
    ctx.setLineWidth(slashThick * 1.5)
    ctx.setLineCap(.butt)
    ctx.move(to: a1)
    ctx.addLine(to: a2)
    ctx.strokePath()
    ctx.restoreGState()
    // re-paint the backdrop where we just punched, so the trench has the
    // proper gradient again rather than flat dark
    ctx.saveGState()
    let trench = CGMutablePath()
    let nx = cos(slashAngle + .pi/2), ny = sin(slashAngle + .pi/2)
    trench.move(to:    CGPoint(x: a1.x + nx * slashThick * 0.75, y: a1.y + ny * slashThick * 0.75))
    trench.addLine(to: CGPoint(x: a2.x + nx * slashThick * 0.75, y: a2.y + ny * slashThick * 0.75))
    trench.addLine(to: CGPoint(x: a2.x - nx * slashThick * 0.75, y: a2.y - ny * slashThick * 0.75))
    trench.addLine(to: CGPoint(x: a1.x - nx * slashThick * 0.75, y: a1.y - ny * slashThick * 0.75))
    trench.closeSubpath()
    ctx.addPath(trench)
    ctx.clip()
    paintBackdrop(ctx)
    ctx.restoreGState()

    // 2) draw the slash itself, slightly thinner than the trench, with
    // a gradient and outer glow.
    let slash = CGMutablePath()
    slash.move(to:    CGPoint(x: a1.x + nx * slashThick/2, y: a1.y + ny * slashThick/2))
    slash.addLine(to: CGPoint(x: a2.x + nx * slashThick/2, y: a2.y + ny * slashThick/2))
    slash.addLine(to: CGPoint(x: a2.x - nx * slashThick/2, y: a2.y - ny * slashThick/2))
    slash.addLine(to: CGPoint(x: a1.x - nx * slashThick/2, y: a1.y - ny * slashThick/2))
    slash.closeSubpath()

    // shadow / glow
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.05, color: a(cutLo, 0.9))
    ctx.setFillColor(cut)
    ctx.addPath(slash)
    ctx.fillPath()
    ctx.restoreGState()

    // gradient body
    let slashGrad = CGGradient(colorsSpace: cs,
                               colors: [cutHi, cut, cutLo] as CFArray,
                               locations: [0, 0.5, 1])!
    ctx.saveGState()
    ctx.addPath(slash)
    ctx.clip()
    ctx.drawLinearGradient(slashGrad,
                           start: CGPoint(x: a1.x, y: a1.y + slashThick),
                           end:   CGPoint(x: a2.x, y: a2.y - slashThick),
                           options: [])
    ctx.restoreGState()

    // top-edge highlight
    ctx.saveGState()
    let hi = CGMutablePath()
    hi.move(to:    CGPoint(x: a1.x + nx * slashThick * 0.42, y: a1.y + ny * slashThick * 0.42))
    hi.addLine(to: CGPoint(x: a2.x + nx * slashThick * 0.42, y: a2.y + ny * slashThick * 0.42))
    ctx.addPath(hi)
    ctx.setStrokeColor(a(creamHi, 0.45))
    ctx.setLineWidth(S * 0.006)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Concept 3 — SIGIL  (custom mancer monogram)
// A bold "M" sigil where the three peaks are rounded Wi-Fi-style arcs,
// and a single horizontal cut-orange bar slashes through the M's waist.
// Premium typographic mark — reads as a brand letterform from any size.
makeIcon(name: "3_SIGIL") { ctx in
    // Cut-orange aura behind the mark, soft and centered.
    let aura = CGGradient(colorsSpace: cs,
                          colors: [a(cut, 0.42), a(cut, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(aura,
                           startCenter: CGPoint(x: S/2, y: S/2), startRadius: 0,
                           endCenter:   CGPoint(x: S/2, y: S/2), endRadius:   S * 0.42,
                           options: [])

    // Build the M as a single closed path, pulled from a parametric layout.
    // The peaks are smoothed with addQuadCurve so they read as "Wi-Fi-style
    // arcs at the top of an M letterform" rather than sharp serifs.
    let cx = S/2, cy = S/2
    let halfW: CGFloat = S * 0.32
    let height: CGFloat = S * 0.40
    let stroke: CGFloat = S * 0.090
    let topY = cy + height/2
    let botY = cy - height/2
    let midY = cy + height * 0.05

    let m = CGMutablePath()
    // outer outline of the M letterform (clockwise)
    m.move(to:    CGPoint(x: cx - halfW,             y: botY))
    m.addLine(to: CGPoint(x: cx - halfW,             y: topY - stroke))
    m.addQuadCurve(to: CGPoint(x: cx - halfW + stroke*1.5, y: topY),
                   control: CGPoint(x: cx - halfW + stroke*0.5, y: topY))
    m.addQuadCurve(to: CGPoint(x: cx,                y: midY),
                   control: CGPoint(x: cx - halfW * 0.30, y: midY + height * 0.30))
    m.addQuadCurve(to: CGPoint(x: cx + halfW - stroke*1.5, y: topY),
                   control: CGPoint(x: cx + halfW * 0.30, y: midY + height * 0.30))
    m.addQuadCurve(to: CGPoint(x: cx + halfW,        y: topY - stroke),
                   control: CGPoint(x: cx + halfW - stroke*0.5, y: topY))
    m.addLine(to: CGPoint(x: cx + halfW,             y: botY))
    m.addLine(to: CGPoint(x: cx + halfW - stroke,    y: botY))
    m.addLine(to: CGPoint(x: cx + halfW - stroke,    y: topY - stroke * 1.5))
    m.addQuadCurve(to: CGPoint(x: cx,                y: midY + stroke * 0.6),
                   control: CGPoint(x: cx + halfW * 0.32, y: midY + height * 0.20))
    m.addQuadCurve(to: CGPoint(x: cx - halfW + stroke, y: topY - stroke * 1.5),
                   control: CGPoint(x: cx - halfW * 0.32, y: midY + height * 0.20))
    m.addLine(to: CGPoint(x: cx - halfW + stroke,    y: botY))
    m.closeSubpath()

    // Shadow + cream fill with vertical highlight gradient
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.015),
                  blur: S * 0.04, color: a(darker, 0.9))
    ctx.setFillColor(cream)
    ctx.addPath(m)
    ctx.fillPath()
    ctx.restoreGState()

    let mGrad = CGGradient(colorsSpace: cs,
                           colors: [creamHi, cream] as CFArray,
                           locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(m)
    ctx.clip()
    ctx.drawLinearGradient(mGrad,
                           start: CGPoint(x: 0, y: topY),
                           end:   CGPoint(x: 0, y: botY),
                           options: [])
    ctx.restoreGState()

    // Horizontal cut bar slashing through the waist of the M
    let barH: CGFloat = S * 0.038
    let barW: CGFloat = S * 0.78
    let barY = cy - height * 0.12
    let bar = CGRect(x: (S - barW)/2, y: barY - barH/2, width: barW, height: barH)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.03, color: a(cutLo, 1.0))
    ctx.setFillColor(cut)
    let barPath = CGPath(roundedRect: bar, cornerWidth: barH/2, cornerHeight: barH/2, transform: nil)
    ctx.addPath(barPath)
    ctx.fillPath()
    ctx.restoreGState()

    // bar gradient body
    let barGrad = CGGradient(colorsSpace: cs,
                             colors: [cutHi, cut] as CFArray,
                             locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(barPath)
    ctx.clip()
    ctx.drawLinearGradient(barGrad,
                           start: CGPoint(x: 0, y: bar.maxY),
                           end:   CGPoint(x: 0, y: bar.minY),
                           options: [])
    ctx.restoreGState()
}

// MARK: - Concept 4 — HEX  (radial network with severed spokes)
// A central hexagonal gem with three trust-green spokes on the left and
// three cut-orange spokes on the right. Far cleaner than the previous
// constellation: bold spokes, glowing nodes, no thin lines anywhere.
makeIcon(name: "4_HEX") { ctx in
    let cx = S/2, cy = S/2
    let centerR = S * 0.115
    let armLen = S * 0.34
    let nodeR  = S * 0.058

    // Spokes first (so the central gem covers their inner ends)
    for i in 0..<6 {
        let angle = CGFloat(i) * .pi / 3 + .pi / 6 // 30°, 90°, 150°, 210°, 270°, 330°
        let nx = cx + cos(angle) * armLen
        let ny = cy + sin(angle) * armLen

        // 30° (right-down), 330° (right-up): cut
        // 90° (top): cut    (top-most goes orange to balance vertically)
        // 150° (left-up), 210° (left-down): trust
        // 270° (bottom): trust (bottom-most goes green)
        let cutSide = (i == 0 || i == 5 || i == 1)
        let color = cutSide ? cut : trust
        let colorHi = cutSide ? cutHi : trust

        // Spoke
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.02, color: a(color, 0.6))
        ctx.setStrokeColor(color)
        ctx.setLineWidth(S * 0.036)
        ctx.setLineCap(.round)
        if cutSide {
            ctx.setLineDash(phase: 0, lengths: [S * 0.045, S * 0.030])
        }
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx + cos(angle) * (centerR + S*0.005),
                             y: cy + sin(angle) * (centerR + S*0.005)))
        ctx.addLine(to: CGPoint(x: nx - cos(angle) * (nodeR + S*0.005),
                                y: ny - sin(angle) * (nodeR + S*0.005)))
        ctx.strokePath()
        ctx.restoreGState()

        // Node
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.025, color: a(color, 0.8))
        let nodeRect = CGRect(x: nx - nodeR, y: ny - nodeR, width: nodeR*2, height: nodeR*2)
        ctx.setFillColor(a(color, 0.20))
        ctx.fillEllipse(in: nodeRect)
        ctx.setStrokeColor(colorHi)
        ctx.setLineWidth(S * 0.012)
        ctx.strokeEllipse(in: nodeRect)
        // inner pin
        let pinR = nodeR * 0.42
        ctx.setFillColor(colorHi)
        ctx.fillEllipse(in: CGRect(x: nx - pinR, y: ny - pinR, width: pinR*2, height: pinR*2))
        ctx.restoreGState()
    }

    // Central hexagonal gem
    let hex = CGMutablePath()
    for i in 0..<6 {
        let angle = CGFloat(i) * .pi / 3
        let p = CGPoint(x: cx + cos(angle) * centerR, y: cy + sin(angle) * centerR)
        if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
    }
    hex.closeSubpath()

    // gem shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.015),
                  blur: S * 0.04, color: a(darker, 0.9))
    ctx.setFillColor(cream)
    ctx.addPath(hex)
    ctx.fillPath()
    ctx.restoreGState()

    // gem gradient body (cream highlight top)
    let hexGrad = CGGradient(colorsSpace: cs,
                             colors: [creamHi, cream, NSColor(red: 0xc8/255.0, green: 0xc4/255.0, blue: 0xb6/255.0, alpha: 1).cgColor] as CFArray,
                             locations: [0, 0.4, 1])!
    ctx.saveGState()
    ctx.addPath(hex)
    ctx.clip()
    ctx.drawLinearGradient(hexGrad,
                           start: CGPoint(x: cx, y: cy + centerR),
                           end:   CGPoint(x: cx, y: cy - centerR),
                           options: [])
    ctx.restoreGState()

    // gem rim
    ctx.addPath(hex)
    ctx.setStrokeColor(a(darker, 0.4))
    ctx.setLineWidth(S * 0.005)
    ctx.strokePath()

    // tiny inner Wi-Fi mark on gem
    let pulseR = centerR * 0.40
    ctx.setStrokeColor(a(cut, 0.85))
    ctx.setLineWidth(S * 0.008)
    ctx.setLineCap(.round)
    for i in 1...2 {
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: pulseR * CGFloat(i),
                   startAngle: .pi * 0.30, endAngle: .pi * 0.70, clockwise: false)
        ctx.strokePath()
    }
    let coreR = pulseR * 0.30
    ctx.setFillColor(cut)
    ctx.fillEllipse(in: CGRect(x: cx - coreR, y: cy - coreR, width: coreR*2, height: coreR*2))
}

print("\nWrote 4 polished concepts to: \(outDir)")
