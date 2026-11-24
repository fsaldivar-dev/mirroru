// Draws the Mirroru app icon (1024x1024 PNG).
// Usage: swift scripts/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a,
    ])!
}

func gradient(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// --- Background tile (macOS icon grid: 824pt tile inside 1024 canvas) ---
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 186)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x1B1464))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
gradient([color(0x5B3DF5), color(0x2A1B8F), color(0x120B45)],
         from: CGPoint(x: tile.minX, y: tile.maxY), to: CGPoint(x: tile.maxX, y: tile.minY))
// soft glow, top-left
let glow = CGGradient(colorsSpace: space, colors: [color(0x7DE3FF, 0.40), color(0x7DE3FF, 0)] as CFArray, locations: nil)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 760), startRadius: 0,
                       endCenter: CGPoint(x: 330, y: 760), endRadius: 520, options: [])
ctx.restoreGState()

// --- Phones ---
let phoneW: CGFloat = 250, phoneH: CGFloat = 500, radius: CGFloat = 54
let midX = size / 2, baseY: CGFloat = 262
let gap: CGFloat = 46

// Real phone (left)
let left = CGRect(x: midX - gap - phoneW, y: baseY, width: phoneW, height: phoneH)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.45))
ctx.addPath(rounded(left, radius))
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

let screen = left.insetBy(dx: 18, dy: 18)
ctx.saveGState()
ctx.addPath(rounded(screen, radius - 16))
ctx.clip()
gradient([color(0x35E0FF), color(0x4F7CFF), color(0x8A4DFF)],
         from: CGPoint(x: screen.minX, y: screen.maxY), to: CGPoint(x: screen.maxX, y: screen.minY))
ctx.restoreGState()
// island
ctx.addPath(rounded(CGRect(x: left.midX - 38, y: screen.maxY - 44, width: 76, height: 22), 11))
ctx.setFillColor(color(0x0E0A33, 0.85))
ctx.fillPath()
// record dot on the screen
ctx.setFillColor(color(0xFFFFFF, 0.95))
ctx.fillEllipse(in: CGRect(x: left.midX - 46, y: left.midY - 46, width: 92, height: 92))
ctx.setFillColor(color(0xFF3B5C))
ctx.fillEllipse(in: CGRect(x: left.midX - 28, y: left.midY - 28, width: 56, height: 56))

// Mirrored phone (right): outlined, translucent
let right = CGRect(x: midX + gap, y: baseY, width: phoneW, height: phoneH)
ctx.saveGState()
ctx.addPath(rounded(right, radius))
ctx.clip()
gradient([color(0xFFFFFF, 0.30), color(0xFFFFFF, 0.06)],
         from: CGPoint(x: right.minX, y: right.maxY), to: CGPoint(x: right.maxX, y: right.minY))
ctx.restoreGState()
ctx.addPath(rounded(right.insetBy(dx: 7, dy: 7), radius - 7))
ctx.setStrokeColor(color(0xFFFFFF, 0.85))
ctx.setLineWidth(14)
ctx.strokePath()
ctx.addPath(rounded(CGRect(x: right.midX - 38, y: right.maxY - 62, width: 76, height: 22), 11))
ctx.setFillColor(color(0xFFFFFF, 0.55))
ctx.fillPath()
ctx.setStrokeColor(color(0xFFFFFF, 0.75))
ctx.setLineWidth(12)
ctx.strokeEllipse(in: CGRect(x: right.midX - 40, y: right.midY - 40, width: 80, height: 80))

// Mirror line between them
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineWidth(10)
ctx.setLineDash(phase: 0, lengths: [2, 30])
ctx.setStrokeColor(color(0xFFFFFF, 0.9))
ctx.move(to: CGPoint(x: midX, y: baseY - 26))
ctx.addLine(to: CGPoint(x: midX, y: baseY + phoneH + 26))
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print("icon -> \(out)")
