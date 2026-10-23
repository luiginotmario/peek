// draws App/dmg/background.tiff in the site's language: paper white, tight display type, the
// install drawing's ink arrow, and a strip of the black-and-white mosaic with one found tile lifted.
// icon positions match App/dmg/settings.py. swift scripts/dmg-background.swift App/dmg
import AppKit

let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/dmg"
let size = NSSize(width: 640, height: 440)

let paper = NSColor(srgbRed: 0.984, green: 0.984, blue: 0.98, alpha: 1)
let ink = NSColor(srgbRed: 0.067, green: 0.067, blue: 0.063, alpha: 1)
let muted = NSColor(srgbRed: 0.435, green: 0.435, blue: 0.416, alpha: 1)

/// Finder measures from the top, AppKit from the bottom.
func top(_ y: CGFloat) -> CGFloat { size.height - y }

func centred(_ text: String, y: CGFloat, font: NSFont, color: NSColor, kern: CGFloat) {
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    string.draw(at: NSPoint(x: (size.width - string.size().width) / 2, y: top(y) - string.size().height))
}

/// A row of tiles that reads like a strip of a black-and-white photo: sky light at the top,
/// ground darker below, fading out towards both edges.
func mosaic() {
    let tile: CGFloat = 15, gap: CGFloat = 3, rows = 4
    let columns = Int((size.width + gap) / (tile + gap))
    let width = CGFloat(columns) * (tile + gap) - gap
    let left = (size.width - width) / 2
    var seed: UInt64 = 7
    func random() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(1 << 31)
    }
    let found = (column: columns / 2 + 6, row: 1)

    for row in 0..<rows {
        for column in 0..<columns {
            let x = left + CGFloat(column) * (tile + gap)
            let y = top(354 + CGFloat(row) * (tile + gap)) - tile
            let fromCentre = abs(CGFloat(column) - CGFloat(columns - 1) / 2) / (CGFloat(columns) / 2)
            let fade = max(0, 1 - pow(fromCentre, 2.2))
            // a horizon-ish wave: lighter left of centre, a dark ridge to the right
            let ridge = 0.5 + 0.5 * sin(CGFloat(column) * 0.31 + CGFloat(row) * 0.9)
            let tone = 0.9 - CGFloat(row) * 0.11 - ridge * 0.12 + (random() - 0.5) * 0.06
            let rect = NSRect(x: x, y: y, width: tile, height: tile)
            if column == found.column, row == found.row { continue }
            NSColor(white: min(0.95, tone), alpha: 0.85 * fade).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
    }

    // the match, lifted out of the grid like the icon's centre tile
    let x = left + CGFloat(found.column) * (tile + gap)
    let y = top(354 + CGFloat(found.row) * (tile + gap)) - tile
    NSColor(white: 0, alpha: 0.06).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: tile, height: tile), xRadius: 3, yRadius: 3).fill()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -3)
    shadow.shadowBlurRadius = 4
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let lifted = NSAffineTransform()
    lifted.translateX(by: x + tile / 2 - 1.5, yBy: y + tile / 2 + 3)
    lifted.rotate(byDegrees: 4)
    let path = NSBezierPath(roundedRect: NSRect(x: -tile / 2, y: -tile / 2, width: tile, height: tile), xRadius: 3, yRadius: 3)
    path.transform(using: lifted as AffineTransform)
    ink.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// The same fine ink arrow as the "drag it to applications" drawing on the site.
func arrow() {
    let y = top(190)
    let curve = NSBezierPath()
    curve.move(to: NSPoint(x: 256, y: y + 16))
    curve.curve(to: NSPoint(x: 384, y: y + 14), controlPoint1: NSPoint(x: 292, y: y + 62), controlPoint2: NSPoint(x: 350, y: y + 62))
    let head = NSBezierPath()
    let tip = NSPoint(x: 385, y: y + 12)
    let angle = atan2(-46.0, 34.0) // the curve's direction as it lands
    for side in [CGFloat.pi * 0.78, -CGFloat.pi * 0.78] {
        head.move(to: NSPoint(x: tip.x + cos(angle + side) * 10, y: tip.y + sin(angle + side) * 10))
        head.line(to: tip)
    }
    for path in [curve, head] {
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        ink.setStroke()
        path.stroke()
    }
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    paper.setFill()
    NSRect(origin: .zero, size: size).fill()

    centred("drag peek into applications.", y: 40, font: .systemFont(ofSize: 24, weight: .semibold), color: ink, kern: -0.7)
    centred("then click the mosaic in your menu bar.", y: 76, font: .systemFont(ofSize: 13.5), color: muted, kern: -0.1)
    arrow()
    mosaic()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
try! image.tiffRepresentation(using: .lzw, factor: 1)!.write(to: URL(fileURLWithPath: "\(folder)/background.tiff"))
print("✓ \(folder)/background.tiff")
