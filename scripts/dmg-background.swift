// draws App/dmg/background.tiff: paper white, a fine ink arrow from peek to applications.
// icon positions match App/dmg/settings.py. swift scripts/dmg-background.swift App/dmg
import AppKit

let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/dmg"
let size = NSSize(width: 640, height: 440)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(srgbRed: 0.984, green: 0.984, blue: 0.98, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    // finder's y runs down, appkit's up: icons sit at y 190 from the top
    let y = size.height - 190
    let ink = NSColor(srgbRed: 0.067, green: 0.067, blue: 0.063, alpha: 1)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 258, y: y + 10))
    arrow.curve(to: NSPoint(x: 382, y: y + 10), controlPoint1: NSPoint(x: 290, y: y + 56), controlPoint2: NSPoint(x: 350, y: y + 56))
    arrow.lineWidth = 1.6
    arrow.lineCapStyle = .round
    ink.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 372, y: y + 24))
    head.line(to: NSPoint(x: 383, y: y + 9))
    head.line(to: NSPoint(x: 366, y: y + 6))
    head.lineWidth = 1.6
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let caption = NSAttributedString(string: "drag peek into applications", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.41, alpha: 1),
    ])
    caption.draw(at: NSPoint(x: (size.width - caption.size().width) / 2, y: 72))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
try! image.tiffRepresentation(using: .lzw, factor: 1)!.write(to: URL(fileURLWithPath: "\(folder)/background.tiff"))
print("✓ \(folder)/background.tiff")
