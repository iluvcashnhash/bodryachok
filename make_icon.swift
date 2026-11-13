import Cocoa

// Renders icon_1024.png: macOS-style squircle, warm espresso→amber gradient,
// white cup with steam and a small lightning bolt.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Apple icon grid: 824×824 body, centred, corner radius ~185, soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill(); shape.fill()
ctx.restoreGState()

ctx.saveGState()
shape.addClip()
NSGradient(colors: [
    NSColor(red: 0.18, green: 0.08, blue: 0.05, alpha: 1),   // espresso
    NSColor(red: 0.62, green: 0.20, blue: 0.08, alpha: 1),
    NSColor(red: 1.00, green: 0.58, blue: 0.16, alpha: 1)    // amber
], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: 70)

// Warm glow behind the cup
NSGradient(colors: [NSColor(red: 1, green: 0.8, blue: 0.4, alpha: 0.45), .clear])!
    .draw(fromCenter: NSPoint(x: 512, y: 470), radius: 0, toCenter: NSPoint(x: 512, y: 470), radius: 380, options: [])

// Glossy top highlight
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), .clear])!
    .draw(in: NSRect(x: 100, y: 600, width: 824, height: 324), angle: -90)
ctx.restoreGState()

// Cup + saucer
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = cup.size
    let r = NSRect(x: 512 - s.width / 2, y: 330 - s.height / 2 + 120, width: s.width, height: s.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    cup.draw(in: r)
    ctx.restoreGState()
}

// Steam: three wavy strokes
NSColor.white.withAlphaComponent(0.85).setStroke()
for (i, x) in [430.0, 512.0, 594.0].enumerated() {
    let p = NSBezierPath()
    let base: CGFloat = 640, top: CGFloat = i == 1 ? 820 : 780
    p.move(to: NSPoint(x: x, y: base))
    p.curve(to: NSPoint(x: x, y: top),
            controlPoint1: NSPoint(x: x + 45, y: base + (top - base) * 0.35),
            controlPoint2: NSPoint(x: x - 45, y: base + (top - base) * 0.65))
    p.lineWidth = 26; p.lineCapStyle = .round
    p.stroke()
}

// Lightning bolt on the cup
let bolt = NSBezierPath()
let pts: [(CGFloat, CGFloat)] = [(528, 560), (462, 455), (505, 455), (482, 368), (556, 480), (512, 480), (528, 560)]
bolt.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
for p in pts.dropFirst() { bolt.line(to: NSPoint(x: p.0, y: p.1)) }
bolt.close()
NSColor(red: 1.0, green: 0.62, blue: 0.15, alpha: 1).setFill()
bolt.fill()

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote", out)
