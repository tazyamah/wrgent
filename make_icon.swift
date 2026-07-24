#!/usr/bin/env swift
import AppKit
import CoreGraphics

let sz: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(sz), height: Int(sz),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("Failed to create context"); exit(1)
}

// ── Background: deep indigo/purple gradient ──────────────────────────────
let roundedRect = CGPath(roundedRect: CGRect(x: 0, y: 0, width: sz, height: sz),
                         cornerWidth: 210, cornerHeight: 210, transform: nil)
ctx.addPath(roundedRect)
ctx.clip()

let bgColors = [CGColor(red: 0.07, green: 0.03, blue: 0.28, alpha: 1.0),   // bottom: deep violet
                CGColor(red: 0.15, green: 0.07, blue: 0.48, alpha: 1.0)] as CFArray  // top: purple
let bgLocs: [CGFloat] = [0.0, 1.0]
let bgGrad = CGGradient(colorsSpace: cs, colors: bgColors, locations: bgLocs)!
ctx.drawLinearGradient(bgGrad,
                       start: CGPoint(x: sz / 2, y: 0),
                       end: CGPoint(x: sz / 2, y: sz), options: [])

// Subtle radial highlight at top-center
let hlColors = [CGColor(red: 0.55, green: 0.40, blue: 1.0, alpha: 0.28),
                CGColor(red: 0.55, green: 0.40, blue: 1.0, alpha: 0.0)] as CFArray
let hlGrad = CGGradient(colorsSpace: cs, colors: hlColors, locations: bgLocs)!
ctx.drawRadialGradient(hlGrad,
                       startCenter: CGPoint(x: sz * 0.5, y: sz * 0.85), startRadius: 0,
                       endCenter:   CGPoint(x: sz * 0.5, y: sz * 0.85), endRadius: sz * 0.5,
                       options: [])

// ── Sound waves (right side) ──────────────────────────────────────────────
// Three arcs emanating rightward from mic body edge, decreasing opacity
let waveCX: CGFloat = 620    // right edge of mic body
let waveCY: CGFloat = 650    // vertical midpoint of mic body
let waveStart = -CGFloat.pi / 3   // -60°  (down-right)
let waveEnd   =  CGFloat.pi / 3   //  60°  (up-right)
let waveRadii: [CGFloat] = [110, 195, 285]
let waveAlphas: [CGFloat] = [0.90, 0.58, 0.30]

for (r, a) in zip(waveRadii, waveAlphas) {
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: a))
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: waveCX, y: waveCY),
               radius: r, startAngle: waveStart, endAngle: waveEnd, clockwise: false)
    ctx.strokePath()
}

// ── Microphone body (white capsule) ──────────────────────────────────────
let micCX: CGFloat = 480
let micBodyW: CGFloat = 210
let micBodyH: CGFloat = 320
let micBodyBottom: CGFloat = 490
let micBodyTop    = micBodyBottom + micBodyH      // 810
let micBodyLeft   = micCX - micBodyW / 2          // 375

ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
ctx.addPath(CGPath(roundedRect: CGRect(x: micBodyLeft, y: micBodyBottom,
                                      width: micBodyW, height: micBodyH),
                  cornerWidth: micBodyW / 2, cornerHeight: micBodyW / 2, transform: nil))
ctx.fillPath()

// ── "W" letterform inside mic body ───────────────────────────────────────
// Five-point W path, drawn in translucent purple against the white mic body
ctx.setStrokeColor(CGColor(red: 0.15, green: 0.07, blue: 0.48, alpha: 0.30))
ctx.setLineWidth(26)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let wBottom: CGFloat = micBodyBottom + 85   // base of W
let wTop:    CGFloat = wBottom + 110         // top of W stems
let wL:      CGFloat = micBodyLeft + 38
let wR:      CGFloat = micBodyLeft + micBodyW - 38
let wML:     CGFloat = micCX - 30
let wMR:     CGFloat = micCX + 30
let wMid:    CGFloat = wBottom + 48          // inner V peak

ctx.move(to:    CGPoint(x: wL,   y: wTop))
ctx.addLine(to: CGPoint(x: wML,  y: wBottom))
ctx.addLine(to: CGPoint(x: micCX, y: wMid))
ctx.addLine(to: CGPoint(x: wMR,  y: wBottom))
ctx.addLine(to: CGPoint(x: wR,   y: wTop))
ctx.strokePath()

// Three subtle lines above W (suggesting transcript text)
ctx.setFillColor(CGColor(red: 0.15, green: 0.07, blue: 0.48, alpha: 0.15))
let lineL = micBodyLeft + 40
let lineWFull: CGFloat = micBodyW - 80
for i in 0..<3 {
    let y = wTop + 22 + CGFloat(i) * 44
    let w = i == 1 ? lineWFull * 0.7 : lineWFull
    ctx.fill(CGRect(x: lineL, y: y, width: w, height: 18))
}

// ── Mic stand arc (U below body) ─────────────────────────────────────────
let arcR: CGFloat = 158
let arcCY = micBodyBottom
ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
ctx.setLineWidth(44)
ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: micCX, y: arcCY),
           radius: arcR, startAngle: .pi, endAngle: 0, clockwise: true)
ctx.strokePath()

// Stand vertical
let arcBottom = arcCY - arcR   // 332
let baseY: CGFloat = 278
ctx.move(to: CGPoint(x: micCX, y: arcBottom))
ctx.addLine(to: CGPoint(x: micCX, y: baseY))
ctx.strokePath()

// Stand base
ctx.move(to: CGPoint(x: micCX - 135, y: baseY))
ctx.addLine(to: CGPoint(x: micCX + 135, y: baseY))
ctx.strokePath()

// ── Recording badge (red dot, top-right of mic body) ──────────────────────
let dotR: CGFloat = 64
let dotX = micBodyLeft + micBodyW + 6    // just outside right edge
let dotY = micBodyTop - 10
ctx.setFillColor(CGColor(red: 0.95, green: 0.22, blue: 0.25, alpha: 1.0))
ctx.addEllipse(in: CGRect(x: dotX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
ctx.fillPath()
// White ring
ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
ctx.setLineWidth(9)
ctx.addEllipse(in: CGRect(x: dotX - dotR + 15, y: dotY - dotR + 15,
                          width: (dotR - 15) * 2, height: (dotR - 15) * 2))
ctx.strokePath()

// ── Save PNG ──────────────────────────────────────────────────────────────
guard let cgImage = ctx.makeImage() else { print("makeImage failed"); exit(1) }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else {
    print("PNG encoding failed"); exit(1)
}
try! data.write(to: URL(fileURLWithPath: "AppIcon_1024.png"))
print("Saved: AppIcon_1024.png")
