import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Photos

/// One photo or video in the user's Photos library, with the metadata search can filter on.
public struct Item: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case photo, video, livePhoto, screenshot, portrait, panorama
    }

    public var id: String                 // PHAsset.localIdentifier
    public var kind: Kind
    public var created: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var favorite: Bool
    public var duration: Double           // seconds, 0 for photos
    public var width: Int
    public var height: Int
}

/// Read-only access to the Photos library.
public enum Library {
    public enum Access: Sendable {
        case full, limited, denied
    }

    public static func requestAccess() async -> Access {
        switch await PHPhotoLibrary.requestAuthorization(for: .readWrite) {
        case .authorized: .full
        case .limited: .limited
        default: .denied
        }
    }

    /// Every image and video, newest first.
    public static func assets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    public static func item(for asset: PHAsset) -> Item {
        Item(
            id: asset.localIdentifier,
            kind: kind(of: asset),
            created: asset.creationDate,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            favorite: asset.isFavorite,
            duration: asset.duration,
            width: asset.pixelWidth,
            height: asset.pixelHeight
        )
    }

    /// A small rendition for the encoder. Tries the local cache first and only asks iCloud when the
    /// library keeps the original in the cloud and no thumbnail is on disk yet.
    public static func thumbnail(for asset: PHAsset, side: Int) async -> CGImage? {
        if let image = await requestImage(asset, side: side, network: false) { return image }
        return await requestImage(asset, side: side, network: true)
    }

    /// The video file, if it's on this Mac. Clips kept only in iCloud aren't downloaded just to index them.
    /// Slo-mo edits come back as compositions rather than files; those fall back to the poster frame.
    public static func localVideo(for asset: PHAsset) async -> URL? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, _ in
                continuation.resume(returning: (video as? AVURLAsset)?.url)
            }
        }
    }

    private static func requestImage(_ asset: PHAsset, side: Int, network: Bool) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat // exactly one callback
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network
        options.isSynchronous = false
        let target = CGSize(width: side, height: side)

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: target, contentMode: .aspectFill, options: options
            ) { image, _ in
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    private static func kind(of asset: PHAsset) -> Item.Kind {
        if asset.mediaType == .video { return .video }
        let subtypes = asset.mediaSubtypes
        if subtypes.contains(.photoScreenshot) { return .screenshot }
        if subtypes.contains(.photoLive) { return .livePhoto }
        if subtypes.contains(.photoDepthEffect) { return .portrait }
        if subtypes.contains(.photoPanorama) { return .panorama }
        return .photo
    }
}
