// Cadence app-icon generator. Renders the flat black tile + clean white geometric C
// deterministically so builds from source need no binary artwork blobs.
// Usage: xcrun swiftc macos/Assets/GenerateAppIcon.swift -o /tmp/cadence-icon-gen -framework AppKit
//        /tmp/cadence-icon-gen flat macos/Assets/AppIcon.png
// Variants: flat (ships), round (rounded terminals), charcoal (softer tile).
import AppKit
import Foundation

func cPath(cx: CGFloat, cy: CGFloat, rMid: CGFloat, half: CGFloat, a0: CGFloat, a1: CGFloat) -> CGPath {
    let m = CGMutablePath()
    let n = 256
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)
        let a = (a0 + (a1 - a0) * t) * .pi / 180
        let p = CGPoint(x: cx + (rMid + half) * cos(a), y: cy + (rMid + half) * sin(a))
        i == 0 ? m.move(to: p) : m.addLine(to: p)
    }
    for i in (0...n).reversed() {
        let t = CGFloat(i) / CGFloat(n)
        let a = (a0 + (a1 - a0) * t) * .pi / 180
        m.addLine(to: CGPoint(x: cx + (rMid - half) * cos(a), y: cy + (rMid - half) * sin(a)))
    }
    m.closeSubpath()
    return m
}

func draw(variant: String, out: String) {
    let S: CGFloat = 1024
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)

    let tile = CGRect(x: 82, y: 82, width: 860, height: 860)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 225, cornerHeight: 225, transform: nil))
    ctx.clip()

    let top: NSColor, bottom: NSColor
    if variant == "charcoal" {
        top = NSColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1)
        bottom = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    } else {
        top = NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        bottom = NSColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
    }
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 942), end: CGPoint(x: 512, y: 82), options: [])
    let light = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor(white: 1, alpha: 0.07).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(light, start: CGPoint(x: 512, y: 942), end: CGPoint(x: 512, y: 560), options: [])

    let cx: CGFloat = 512, cy: CGFloat = 512, rMid: CGFloat = 205, half: CGFloat = 62
    let a0: CGFloat = 36, a1: CGFloat = 324
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(cPath(cx: cx, cy: cy, rMid: rMid, half: half, a0: a0, a1: a1))
    ctx.fillPath()

    if variant == "round" {
        for aDeg in [a0, a1] {
            let a = aDeg * .pi / 180
            let mx = cx + rMid * cos(a), my = cy + rMid * sin(a)
            ctx.fillEllipse(in: CGRect(x: mx - half, y: my - half, width: half * 2, height: half * 2))
        }
    }

    img.unlockFocus()
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode") }
    try! png.write(to: URL(fileURLWithPath: out))
    print("WROTE \(out)")
}

let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "flat"
let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".build/icon/icon.png"
draw(variant: variant, out: out)
