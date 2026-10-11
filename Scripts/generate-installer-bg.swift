#!/usr/bin/env swift
// One-shot generator for the macOS Installer.app background image. The
// installer renders this behind the welcome / license / install /
// conclusion panes (as long as productbuild is invoked with this
// resource via --resources). Apple's recommended size for a modern
// Installer.app pane is roughly 620×418; we render at 2× and let the
// Installer downscale.
//
// Composition: brand-dark vertical gradient + a soft cut-orange radial
// glow centered low-left + the rendered AppLogo at low opacity bottom
// right, plus a thin diagonal scan line. Subtle enough that it doesn't
// fight the welcome text rendered on top, branded enough that it reads
// as Wifi Mancer.

import AppKit
import CoreGraphics

let projectRoot = FileManager.default.currentDirectoryPath
let masterPath  = "\(projectRoot)/Resources/icon-rendered-1024.png"
let outPath     = "\(projectRoot)/Resources/installer-bg.png"

guard let logoNS = NSImage(contentsOfFile: masterPath),
      let logoCG = logoNS.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("missing \(masterPath) — run Scripts/generate-icons.swift first") }

let cs = CGColorSpaceCreateDeviceRGB()

// 1240×836 = 2× of 620×418 — Installer.app picks @1x or @2x at render time.
let W = 1240, H = 836
guard let ctx = CGContext(data: nil, width: W, height: H,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("ctx") }

let dark    = NSColor(red: 0x14/255.0, green: 0x14/255.0, blue: 0x13/255.0, alpha: 1).cgColor
let darker  = NSColor(red: 0x05/255.0, green: 0x05/255.0, blue: 0x04/255.0, alpha: 1).cgColor
let surface = NSColor(red: 0x1c/255.0, green: 0x1b/255.0, blue: 0x19/255.0, alpha: 1).cgColor
let cut     = NSColor(red: 0xd9/255.0, green: 0x77/255.0, blue: 0x57/255.0, alpha: 1).cgColor
func a(_ c: CGColor, _ alpha: CGFloat) -> CGColor { c.copy(alpha: alpha)! }

// Vertical gradient base: lighter at top, deep dark at bottom.
let base = CGGradient(colorsSpace: cs,
                      colors: [surface, dark, darker] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(base,
                       start: CGPoint(x: 0, y: H),
                       end:   CGPoint(x: 0, y: 0),
                       options: [])

// Radial cut-orange glow off the bottom-left — establishes the brand
// without dominating the canvas. Low alpha so welcome text reads cleanly.
let glow = CGGradient(colorsSpace: cs,
                      colors: [a(cut, 0.32), a(cut, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: CGFloat(W) * 0.18, y: CGFloat(H) * 0.18),
                       startRadius: 0,
                       endCenter:   CGPoint(x: CGFloat(W) * 0.18, y: CGFloat(H) * 0.18),
                       endRadius:   CGFloat(W) * 0.55,
                       options: [])

// Diagonal scan line — same "shine" mark as the app icon, ties the
// installer pane visually back to the icon.
ctx.setStrokeColor(a(NSColor(red: 0xff/255.0, green: 0xfd/255.0, blue: 0xf6/255.0, alpha: 1).cgColor, 0.05))
ctx.setLineWidth(1.5)
ctx.move(to: CGPoint(x: 0, y: CGFloat(H) * 0.95))
ctx.addLine(to: CGPoint(x: CGFloat(W), y: CGFloat(H) * 0.05))
ctx.strokePath()

// AppLogo watermark bottom-right, low opacity so it doesn't compete with
// the installer's left-aligned step content.
let logoSize: CGFloat = CGFloat(H) * 0.45  // ~376pt at 2×
let logoX = CGFloat(W) - logoSize - CGFloat(W) * 0.06
let logoY = CGFloat(H) * 0.10
ctx.saveGState()
ctx.setAlpha(0.55)
ctx.draw(logoCG, in: CGRect(x: logoX, y: logoY, width: logoSize, height: logoSize))
ctx.restoreGState()

guard let img = ctx.makeImage() else { fatalError("makeImage") }
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(W)×\(H))")
