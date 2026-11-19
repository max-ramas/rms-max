import AppKit
// usage: render <out.png> <ios|mac>
let out = CommandLine.arguments[1]; let mode = CommandLine.arguments[2]
let N: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(N), height: Int(N), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat((h>>16)&255)/255, green: CGFloat((h>>8)&255)/255, blue: CGFloat(h&255)/255, alpha: a) }
// tile rect (CG origin bottom-left)
let tile: CGRect = mode == "mac" ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: N, height: N)
let s = tile.width / N
let tilePath: CGPath = mode == "mac" ? CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil) : CGPath(rect: tile, transform: nil)
if mode == "mac" {
  ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: hex(0x000000, 0.35))
  ctx.addPath(tilePath); ctx.setFillColor(hex(0x4060F8)); ctx.fillPath(); ctx.restoreGState()
}
ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
let g = CGGradient(colorsSpace: cs, colors: [hex(0x00CBFD), hex(0x1C7CFC), hex(0x5552F8), hex(0x9744EE), hex(0xA34BED)] as CFArray, locations: [0, 0.3, 0.55, 0.85, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.minY + tile.height*0.75), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// soft top-left blue glow like the original
let rg = CGGradient(colorsSpace: cs, colors: [hex(0x3A4BF8, 0.55), hex(0x3A4BF8, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(rg, startCenter: CGPoint(x: tile.minX + tile.width*0.25, y: tile.maxY - tile.height*0.2), startRadius: 0, endCenter: CGPoint(x: tile.minX + tile.width*0.25, y: tile.maxY - tile.height*0.2), endRadius: tile.width*0.55, options: [])
// logo: svg 108 viewBox, inner transform scale .68 about 54; map svg -> tile (flip y)
let k = tile.width / 108; let LS: CGFloat = 0.95
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
  let sx = 54 + (x - 54) * LS, sy = 50 + (y - 54) * LS
  return CGPoint(x: tile.minX + sx * k, y: tile.maxY - sy * k)
}
ctx.setFillColor(hex(0xFFFFFF)); ctx.setStrokeColor(hex(0xFFFFFF))
// ring
let c = P(54, 54.1365); let rx = 25.5 * LS * k, ry = 25.3633 * LS * k
ctx.setLineWidth(15 * LS * k)
ctx.strokeEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: rx*2, height: ry*2))
func ear(_ pts: [CGFloat]) {
  let p = CGMutablePath(); p.move(to: P(pts[0], pts[1]))
  var i = 2
  while i + 5 < pts.count { p.addCurve(to: P(pts[i+4], pts[i+5]), control1: P(pts[i], pts[i+1]), control2: P(pts[i+2], pts[i+3])); i += 6 }
  p.closeSubpath(); ctx.addPath(p); ctx.setLineWidth(1 * LS * k); ctx.drawPath(using: .fillStroke)
}
ear([22.3915,55.3724, 22.3915,55.3724,22.2564,47.3297,25.3431,39.0233, 28.4297,30.717,27.7587,23.2017,29.3691,21.6194, 30.9795,20.0372,38.9522,21.5956,42.7906,25.0474])
ear([85.691,56.0431, 85.691,56.0431,85.825,47.8434,82.7643,39.375, 79.7036,30.9066,80.369,23.2446,78.7721,21.6315, 77.1752,20.0184,69.2695,21.6072,65.4633,25.1264])
ctx.restoreGState()
// RMS badge, bottom-right inside tile safe area
let bw: CGFloat = 400 * s, bh: CGFloat = 176 * s
let inset: CGFloat = (mode == "mac" ? 60 : 92) * s
let badge = CGRect(x: tile.maxX - inset - bw, y: tile.minY + inset, width: bw, height: bh)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -6*s), blur: 24*s, color: hex(0x000000, 0.35))
let bp = CGPath(roundedRect: badge, cornerWidth: bh/2, cornerHeight: bh/2, transform: nil)
ctx.addPath(bp); ctx.setFillColor(hex(0x0F1226)); ctx.fillPath(); ctx.restoreGState()
ctx.addPath(bp); ctx.setStrokeColor(hex(0xFFFFFF, 0.9)); ctx.setLineWidth(10*s); ctx.strokePath()
let ns = NSGraphicsContext(cgContext: ctx, flipped: false); NSGraphicsContext.current = ns
var font = NSFont.systemFont(ofSize: 118*s, weight: .black)
if let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: 118*s)! }
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: 6*s]
let str = NSAttributedString(string: "RMS", attributes: attrs); let sz = str.size()
str.draw(at: CGPoint(x: badge.midX - sz.width/2 + 3*s, y: badge.midY - sz.height/2 + 2*s))
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
