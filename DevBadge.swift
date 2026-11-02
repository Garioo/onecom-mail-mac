// Marks the developer build's icon: an amber "DEV" band across the bottom of the tile, drawn over
// the normal icon (AppIcon.swift) so the two apps are easy to tell apart in the Dock.
// Usage: devbadge icon_1024.png
import AppKit

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("usage: devbadge icon.png") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))

// Same tile shape as AppIcon.swift, so the band follows its rounded bottom corners.
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).addClip()
NSColor(srgbRed: 1, green: 0.62, blue: 0.1, alpha: 1).setFill()
NSRect(x: 100, y: 100, width: 824, height: 190).fill()

let label = NSAttributedString(string: "DEV", attributes: [
    .font: NSFont.systemFont(ofSize: 130, weight: .heavy),
    .foregroundColor: NSColor.white,
    .kern: 10,
])
let size = label.size()
label.draw(at: NSPoint(x: 512 - size.width / 2, y: 195 - size.height / 2))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
