import CoreGraphics
import Foundation
import ImageIO
import Photos
import PeekCore
import UniformTypeIdentifiers

/// A grid of search results as one image, best match top left. A development aid for judging
/// search quality at a glance; it never leaves the Mac.
enum ContactSheet {
    static let columns = 6
    static let tile = 220

    static func write(_ matches: [Index.Match], to url: URL) async throws {
        let ids = matches.map(\.item.id)
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            assets[asset.localIdentifier] = asset
        }

        let rows = (matches.count + columns - 1) / columns
        guard rows > 0, let context = CGContext(
            data: nil, width: columns * tile, height: rows * tile, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: columns * tile, height: rows * tile))

        for (position, id) in ids.enumerated() {
            guard let asset = assets[id], let image = await Library.thumbnail(for: asset, side: tile * 2) else { continue }
            let column = position % columns, row = position / columns
            let cell = CGRect(x: column * tile, y: (rows - 1 - row) * tile, width: tile, height: tile).insetBy(dx: 2, dy: 2)
            context.saveGState()
            context.clip(to: cell)
            context.draw(image, in: aspectFill(image, in: cell))
            context.restoreGState()
        }

        guard let sheet = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, sheet, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private static func aspectFill(_ image: CGImage, in rect: CGRect) -> CGRect {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}
