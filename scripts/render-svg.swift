// renders an svg to square pngs: swift scripts/render-svg.swift in.svg out-prefix 16 32 …
import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 3, let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) else {
    FileHandle.standardError.write(Data("usage: render-svg.swift in.svg out-prefix size…\n".utf8))
    exit(1)
}
for size in arguments[3...].compactMap(Int.init) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(arguments[2])-\(size).png"))
}
