import AVFoundation
import CoreGraphics
import Foundation
import Photos

/// Walks the Photos library and embeds whatever the index hasn't seen yet. Re-running it is cheap:
/// only new photos are encoded, and deleted ones are dropped.
public struct Indexer {
    public struct Progress: Sendable {
        public var done: Int
        public var total: Int
    }

    /// Seconds between the frames sampled from a video, and the most frames one video gets.
    static let frameInterval = 2.0
    static let maxFrames = 30
    static let batchSize = 32

    public let files: ModelFiles
    public let folder: URL

    public init(files: ModelFiles, folder: URL) {
        self.files = files
        self.folder = folder
    }

    @concurrent
    public func run(progress: @Sendable (Progress) -> Void) async throws -> Index {
        let meta = try SiglipMeta(contentsOf: files.meta)
        var index = try Index.load(from: folder, dimensions: meta.dimensions)
        let assets = Library.assets()
        index.keep(only: Set(assets.map(\.localIdentifier)))

        let pending = assets.filter { !index.contains($0.localIdentifier) }
        let encoder = try ImageEncoder(files: files)
        progress(Progress(done: 0, total: pending.count))

        var done = 0
        for start in stride(from: 0, to: pending.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = Array(pending[start ..< min(start + Self.batchSize, pending.count)])
            for (asset, frames) in await Self.frames(for: batch, side: meta.imageSize) where !frames.isEmpty {
                let vectors = try encoder.encode(frames.map(\.image))
                index.add(Library.item(for: asset), vectors: zip(frames, vectors).map { ($0.time, $1) })
            }
            done += batch.count
            progress(Progress(done: done, total: pending.count))
            if start / Self.batchSize % 10 == 9 { try index.save(to: folder) } // keep progress if interrupted
        }
        try index.save(to: folder)
        return index
    }

    /// Fetches a batch's images a few at a time: photos give one frame, videos one every two seconds.
    private static func frames(for assets: [PHAsset], side: Int) async -> [(PHAsset, [(time: Double, image: CGImage)])] {
        await withTaskGroup { group in
            for (position, asset) in assets.enumerated() {
                group.addTask { (position, await frames(for: asset, side: side)) }
            }
            var results = [[(time: Double, image: CGImage)]](repeating: [], count: assets.count)
            for await (position, frames) in group {
                results[position] = frames
            }
            return Array(zip(assets, results))
        }
    }

    private static func frames(for asset: PHAsset, side: Int) async -> [(time: Double, image: CGImage)] {
        if asset.mediaType == .video, let frames = await videoFrames(for: asset, side: side), !frames.isEmpty {
            return frames
        }
        // photos, and videos whose file is only in icloud: the poster frame stands in for the clip
        guard let image = await Library.thumbnail(for: asset, side: side) else { return [] }
        return [(0, image)]
    }

    private static func videoFrames(for asset: PHAsset, side: Int) async -> [(time: Double, image: CGImage)]? {
        guard let file = await Library.localVideo(for: asset) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side * 2, height: side * 2)
        generator.requestedTimeToleranceBefore = .positiveInfinity // nearest keyframe is plenty
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let count = min(Self.maxFrames, max(1, Int(asset.duration / Self.frameInterval)))
        let step = asset.duration / Double(count)
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * step, preferredTimescale: 600) }

        var frames: [(time: Double, image: CGImage)] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                frames.append((result.requestedTime.seconds, image))
            }
        }
        return frames
    }
}
