// Draws the app icon (an open envelope with a letter and a coral new-mail dot on an indigo tile)
// to a 1024×1024 PNG.
import AppKit

let size = 1024
guard CommandLine.arguments.count > 1,
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("usage: makeicon out.png") }

func rgb(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func polygon(_ points: [NSPoint]) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: points[0])
    points.dropFirst().forEach { p.line(to: $0) }
    p.close()
    return p
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Tile (inset like standard macOS icons), lighter at the top
let tile = rounded(100, 100, 824, 824, 185)
NSGradient(starting: rgb(0x5B6CFF), ending: rgb(0x262B86))!.draw(in: tile, angle: -90)

let envBack = rgb(0xC9CEFF)
let envFront = rgb(0xEEF0FF)

// Envelope back with the open flap
envBack.setFill()
rounded(262, 300, 500, 300, 40).fill()
NSRect(x: 262, y: 520, width: 500, height: 80).fill()
polygon([NSPoint(x: 262, y: 596), NSPoint(x: 512, y: 770), NSPoint(x: 762, y: 596)]).fill()

// Letter sticking out
NSColor.white.setFill()
rounded(332, 400, 360, 320, 28).fill()
rgb(0xB8BFF5).setFill()
for (i, right) in [620, 600, 560].enumerated() {
    let top = CGFloat(650 - i * 58)
    rounded(392, top - 22, CGFloat(right) - 392, 22, 11).fill()
}

// Front pocket
envFront.setFill()
polygon([NSPoint(x: 262, y: 560), NSPoint(x: 512, y: 420), NSPoint(x: 762, y: 560),
         NSPoint(x: 762, y: 340), NSPoint(x: 262, y: 340)]).fill()
rounded(262, 300, 500, 80, 40).fill()

// New-mail dot
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 740 - 74, y: 742 - 74, width: 148, height: 148)).fill()
rgb(0xFF6B5B).setFill()
NSBezierPath(ovalIn: NSRect(x: 740 - 58, y: 742 - 58, width: 116, height: 116)).fill()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
