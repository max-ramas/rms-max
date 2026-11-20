import AppKit
// RMS MAKS app icon — original artwork: a chat bubble shaped like a padlock (private messaging).
// usage: swift render-icon.swift <out.png> <ios|mac>
let out = CommandLine.arguments[1]
let mode = CommandLine.arguments[2]
let N: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(N), height: Int(N), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

// Tile: full bleed on iOS (the system masks it), inset rounded square with a shadow on macOS.
let tile: CGRect = mode == "mac" ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: N, height: N)
let tilePath: CGPath = mode == "mac"
    ? CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    : CGPath(rect: tile, transform: nil)
if mode == "mac" {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: hex(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(hex(0x0F172A)); ctx.fillPath()
    ctx.restoreGState()
}
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [hex(0x0B1220), hex(0x123A5A), hex(0x0E7C86), hex(0x14B8A6)] as CFArray,
                    locations: [0, 0.35, 0.75, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [hex(0x5EEAD4, 0.35), hex(0x5EEAD4, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.maxX - tile.width * 0.2, y: tile.minY + tile.height * 0.2), startRadius: 0,
                       endCenter: CGPoint(x: tile.maxX - tile.width * 0.2, y: tile.minY + tile.height * 0.2), endRadius: tile.width * 0.7, options: [])

// Geometry in a 1000-unit design space mapped onto the tile.
let u = tile.width / 1000
func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: tile.minX + x * u, y: tile.minY + y * u, width: w * u, height: h * u)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * u, y: tile.minY + y * u) }

// Padlock shackle (behind the bubble).
ctx.setStrokeColor(hex(0xFFFFFF))
ctx.setLineWidth(70 * u)
ctx.setLineCap(.round)
let shackle = CGMutablePath()
shackle.move(to: P(330, 520))
shackle.addLine(to: P(330, 640))
shackle.addArc(center: P(500, 640), radius: 170 * u, startAngle: .pi, endAngle: 0, clockwise: true)
shackle.addLine(to: P(670, 520))
ctx.addPath(shackle); ctx.strokePath()

// Chat bubble = lock body, with a tail at the bottom left.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 36 * u, color: hex(0x020617, 0.45))
let body = CGMutablePath()
body.addRoundedRect(in: R(200, 230, 600, 380), cornerWidth: 120 * u, cornerHeight: 120 * u)
let tail = CGMutablePath()
tail.move(to: P(270, 260))
tail.addQuadCurve(to: P(215, 150), control: P(260, 190))
tail.addQuadCurve(to: P(390, 240), control: P(320, 200))
tail.closeSubpath()
ctx.addPath(body); ctx.addPath(tail)
ctx.setFillColor(hex(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()

// Keyhole.
ctx.setFillColor(hex(0x0E7C86))
ctx.fillEllipse(in: R(450, 440, 100, 100))
let slot = CGMutablePath()
slot.move(to: P(478, 455)); slot.addLine(to: P(522, 455)); slot.addLine(to: P(540, 320)); slot.addLine(to: P(460, 320)); slot.closeSubpath()
ctx.addPath(slot); ctx.fillPath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
