#!/usr/bin/env swift
// Generate the full Wifi Mancer icon asset set from a single 1024×1024
// master PNG. Applies an Apple-style squircle (continuous-curvature
// rounded square) mask so corners are transparent — the system displays
// the result as the macOS app icon, the Dock icon, the Cmd-Tab tile, and
// the dock-bouncer indicator with proper rounded edges.
//
// Inputs:  Resources/icon-master.png            (1024×1024 full-bleed)
// Outputs: Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png
//          Resources/icon-rendered-1024.png     (squircled master, for
//          DMG volume icon + onboarding hero)
//          Resources/menubar-template-32.png    (monochrome template
//          used by MenuBarExtra so the system tints it correctly with
//          the menubar foreground color)
//
// Run from project root:  swift Scripts/generate-icons.swift

import AppKit
import CoreGraphics

let projectRoot = FileManager.default.currentDirectoryPath
let masterPath  = "\(projectRoot)/Resources/icon-master.png"
let appIconDir  = "\(projectRoot)/Resources/Assets.xcassets/AppIcon.appiconset"
let renderedOut = "\(projectRoot)/Resources/icon-rendered-1024.png"
let templateOut = "\(projectRoot)/Resources/menubar-template-32.png"

guard let master = NSImage(contentsOfFile: masterPath),
      let masterCG = master.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("master not loadable: \(masterPath)") }
print("loaded master: \(masterCG.width)×\(masterCG.height)")

let cs = CGColorSpaceCreateDeviceRGB()

/// macOS icon mask: the canvas is divided into a 1024-unit grid, the
/// rounded-rect corner radius is 22.37% of the side. We use a regular
/// rounded rect (circular-arc corners) — the visual difference from
/// Apple's true continuous-curvature squircle is sub-pixel at every
/// shipping size and indistinguishable in the Dock.
func squircleClipPath(size: Int) -> CGPath {
    let s = CGFloat(size)
    let r = s * 0.2237
    return CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                  cornerWidth: r, cornerHeight: r, transform: nil)
}

/// Draw `master` into a `size×size` PNG with the squircle mask applied.
/// High-quality downscaling: CG `interpolationQuality = .high` is Lanczos
/// with appropriate prefilter for these resolution drops.
func renderAt(size: Int, to outPath: String) {
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("ctx create failed at \(size)") }

    ctx.interpolationQuality = .high

    // Apply squircle mask before drawing the master so the corners stay
    // transparent in the output PNG.
    ctx.addPath(squircleClipPath(size: size))
    ctx.clip()

    ctx.draw(masterCG, in: CGRect(x: 0, y: 0, width: size, height: size))

    guard let img = ctx.makeImage() else { fatalError("makeImage failed at \(size)") }
    let rep = NSBitmapImageRep(cgImage: img)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outPath))
    print("✓ \(URL(fileURLWithPath: outPath).lastPathComponent) (\(size)×\(size))")
}

// AppIcon set — every size macOS asks for, both 1× and 2×.
let appIconSizes: [(name: String, px: Int)] = [
    ("icon_16x16",      16),
    ("icon_16x16@2x",   32),
    ("icon_32x32",      32),
    ("icon_32x32@2x",   64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x", 1024),
]
for (name, px) in appIconSizes {
    renderAt(size: px, to: "\(appIconDir)/\(name).png")
}

// Rendered 1024 master with squircle applied — used by:
//   • OnboardingView hero
//   • DMG volume-icon generator
renderAt(size: 1024, to: renderedOut)

// Menubar template — a 32×32 monochrome version where the cream
// foreground (antenna + waves) becomes opaque white pixels and
// everything else is transparent. macOS treats template images as a
// shape mask and tints them automatically based on light/dark menubar
// theme — that's the only way to get a proper-looking menubar icon
// instead of the orange tile shrunk to 18px.
//
// We approximate the silhouette by taking a 32×32 downscale, keeping
// only pixels brighter than ~0.55 luminance (the cream foreground),
// and writing white-with-alpha for those pixels.
do {
    let target = 32
    let scale = 4    // render at 128×128 then downsample for cleaner edges
    let big = target * scale

    guard let bigCtx = CGContext(data: nil, width: big, height: big,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("bigCtx") }
    bigCtx.interpolationQuality = .high
    bigCtx.draw(masterCG, in: CGRect(x: 0, y: 0, width: big, height: big))
    guard let bigImg = bigCtx.makeImage() else { fatalError("bigImg") }

    // Sample pixels — extract a luminance-keyed mask
    guard let dataProvider = bigImg.dataProvider,
          let pixelData = dataProvider.data,
          let ptr = CFDataGetBytePtr(pixelData)
    else { fatalError("pixel access") }
    let bytesPerRow = bigImg.bytesPerRow

    guard let outCtx = CGContext(data: nil, width: big, height: big,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("outCtx") }
    let outPtr = outCtx.data!.bindMemory(to: UInt8.self, capacity: big * outCtx.bytesPerRow)
    let outBPR = outCtx.bytesPerRow

    for y in 0..<big {
        for x in 0..<big {
            let off = y * bytesPerRow + x * 4
            let r = Int(ptr[off + 0])
            let g = Int(ptr[off + 1])
            let b = Int(ptr[off + 2])
            // Cream tones in the artwork are bright on all 3 channels;
            // the orange tile is high-red, low-green/blue. Threshold on
            // green channel — the antenna+waves in the source are white
            // with green > 200; orange tile has green ≈ 100.
            let isForeground = g > 175 && b > 140
            let outOff = y * outBPR + x * 4
            if isForeground {
                outPtr[outOff + 0] = 255
                outPtr[outOff + 1] = 255
                outPtr[outOff + 2] = 255
                outPtr[outOff + 3] = 255
            } else {
                outPtr[outOff + 0] = 0
                outPtr[outOff + 1] = 0
                outPtr[outOff + 2] = 0
                outPtr[outOff + 3] = 0
            }
        }
    }
    guard let bigMask = outCtx.makeImage() else { fatalError("bigMask") }

    // Downsample 128 → 32 with high-quality interpolation for clean edges
    guard let smallCtx = CGContext(data: nil, width: target, height: target,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("smallCtx") }
    smallCtx.interpolationQuality = .high
    smallCtx.draw(bigMask, in: CGRect(x: 0, y: 0,
                                      width: target, height: target))
    guard let small = smallCtx.makeImage() else { fatalError("small") }
    let rep = NSBitmapImageRep(cgImage: small)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: templateOut))
    print("✓ menubar-template-32.png (32×32 alpha-keyed silhouette)")
}

print("\ndone — all icon assets generated")
