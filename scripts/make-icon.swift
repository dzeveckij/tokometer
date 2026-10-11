// Draws the app icon and writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    // Tile on Apple's icon grid: 824pt body centered in 1024, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.16, green: 0.12, blue: 0.36, alpha: 1).cgColor,
        NSColor(srgbRed: 0.05, green: 0.06, blue: 0.16, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Gauge: 240° arc, colored from cool to hot, with ticks and a needle.
    let center = CGPoint(x: 512, y: 470)
    let radius: CGFloat = 270
    let startDeg: CGFloat = 210, endDeg: CGFloat = -30   // counter-clockwise degrees, 0 = east
    func point(_ deg: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(deg * .pi / 180) * r, y: center.y + sin(deg * .pi / 180) * r)
    }

    // Faint track
    ctx.setLineCap(.round)
    ctx.setLineWidth(56)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: startDeg * .pi / 180, endAngle: endDeg * .pi / 180, clockwise: true)
    ctx.strokePath()

    // Colored arc, drawn in short segments to blend hues along it.
    let fraction: CGFloat = 0.78
    let steps = 120
    let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.20, 0.85, 0.95), (0.45, 0.55, 1.00), (0.95, 0.35, 0.75)]
    func mix(_ t: CGFloat) -> NSColor {
        let x = t * CGFloat(colors.count - 1), i = min(Int(x), colors.count - 2), f = x - CGFloat(i)
        let a = colors[i], b = colors[i + 1]
        return NSColor(srgbRed: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f, alpha: 1)
    }
    ctx.setLineCap(.butt)
    for k in 0..<steps {
        let t0 = CGFloat(k) / CGFloat(steps) * fraction, t1 = CGFloat(k + 1) / CGFloat(steps) * fraction
        let a0 = startDeg + (endDeg - startDeg) * t0, a1 = startDeg + (endDeg - startDeg) * t1 - 0.3
        ctx.setStrokeColor(mix(t0 / fraction).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: true)
        ctx.strokePath()
    }
    // Round cap at the start
    ctx.setFillColor(mix(0).cgColor)
    let cap = point(startDeg, radius)
    ctx.fillEllipse(in: CGRect(x: cap.x - 28, y: cap.y - 28, width: 56, height: 56))

    // Ticks
    ctx.setLineCap(.round)
    for k in 0...8 {
        let deg = startDeg + (endDeg - startDeg) * CGFloat(k) / 8
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(k % 2 == 0 ? 0.85 : 0.45).cgColor)
        ctx.setLineWidth(k % 2 == 0 ? 14 : 9)
        ctx.move(to: point(deg, radius - 62)); ctx.addLine(to: point(deg, radius - (k % 2 == 0 ? 112 : 96)))
        ctx.strokePath()
    }

    // Needle
    let needleDeg = startDeg + (endDeg - startDeg) * fraction
    let tip = point(needleDeg, radius - 40)
    let perp = (needleDeg + 90) * .pi / 180
    let base = CGPoint(x: center.x + cos(perp) * 22, y: center.y + sin(perp) * 22)
    let base2 = CGPoint(x: center.x - cos(perp) * 22, y: center.y - sin(perp) * 22)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: NSColor.white.withAlphaComponent(0.35).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.move(to: base); ctx.addLine(to: tip); ctx.addLine(to: base2); ctx.closePath(); ctx.fillPath()
    ctx.fillEllipse(in: CGRect(x: center.x - 52, y: center.y - 52, width: 104, height: 104))
    ctx.restoreGState()
    ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.09, blue: 0.25, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44))

    // Label
    let font = NSFont.systemFont(ofSize: 112, weight: .heavy)
    let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: 112) ?? font
    let text = NSAttributedString(string: "t/s", attributes: [
        .font: rounded, .foregroundColor: NSColor.white.withAlphaComponent(0.92), .kern: 2,
    ])
    let ts = text.size()
    text.draw(at: CGPoint(x: 512 - ts.width / 2, y: 190))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! draw(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("docs/icon.png"))
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
