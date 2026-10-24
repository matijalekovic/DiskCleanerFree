// Renders the app icon (a rainbow disk map on a squircle) to a 1024×1024 PNG.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background with the standard macOS icon inset.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [NSColor(red: 0.16, green: 0.18, blue: 0.30, alpha: 1).cgColor,
                                     NSColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1).cgColor] as CFArray,
                            locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Rings: deterministic pseudo-random wedge sizes so the map looks organic.
let center = CGPoint(x: size / 2, y: size / 2)
var seed: UInt64 = 0x5eed
func random() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) % 1000) / 1000
}

func wedge(depth: Int, start: CGFloat, end: CGFloat) {
    let radii: [CGFloat] = [118, 196, 262, 318, 360]
    guard depth < radii.count - 1 else { return }
    let r0 = radii[depth] + 3, r1 = radii[depth + 1] - 3
    let mid = (start + end) / 2
    let hue = (mid / (2 * .pi)).truncatingRemainder(dividingBy: 1)
    let color = NSColor(hue: hue, saturation: max(0.4, 0.9 - CGFloat(depth) * 0.12),
                        brightness: min(1, 0.86 + CGFloat(depth) * 0.04), alpha: 1)
    let a0 = .pi / 2 - start, a1 = .pi / 2 - end
    let path = CGMutablePath()
    path.addArc(center: center, radius: r1, startAngle: a0, endAngle: a1, clockwise: true)
    path.addArc(center: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: false)
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()

    var angle = start
    let span = end - start
    while angle < end - 0.02 {
        let piece = min(end - angle, span * (0.25 + random() * 0.5))
        if piece > 0.06, random() > 0.18 {
            wedge(depth: depth + 1, start: angle + 0.012, end: angle + piece - 0.012)
        }
        angle += piece
    }
}

var angle: CGFloat = 0
for share in [0.34, 0.22, 0.16, 0.12, 0.09, 0.07] as [CGFloat] {
    let span = share * 2 * .pi
    wedge(depth: 0, start: angle + 0.015, end: angle + span - 0.015)
    angle += span
}

// Frosted center disc.
let disc = CGRect(x: center.x - 104, y: center.y - 104, width: 208, height: 208)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
ctx.fillEllipse(in: disc)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
ctx.setLineWidth(6)
ctx.strokeEllipse(in: disc.insetBy(dx: -8, dy: -8))

// Top sheen.
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
