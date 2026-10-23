import Accelerate
import Foundation

/// The searchable index: one vector per photo, and one per sampled frame of a video.
///
/// On disk it's two files: `entries.json` (which item and moment each vector belongs to, plus the
/// items' metadata) and `vectors.f16` (the vectors back to back as half floats, ~1.5 KB each).
public struct Index: Sendable {
    /// What a vector describes: a photo, or the frame of a video at `time` seconds.
    public struct Entry: Codable, Hashable, Sendable {
        public var id: String
        public var time: Double
    }

    public struct Match: Sendable {
        public var item: Item
        public var time: Double      // the best-matching moment, 0 for photos
        public var cosine: Float
    }

    private struct Manifest: Codable {
        var dimensions: Int
        var entries: [Entry]
        var items: [String: Item]
    }

    public let dimensions: Int
    public private(set) var entries: [Entry] = []
    public private(set) var items: [String: Item] = [:]
    private var vectors: [Float] = []   // entries.count × dimensions, row-major

    public init(dimensions: Int) {
        self.dimensions = dimensions
    }

    public var count: Int { items.count }

    public func contains(_ id: String) -> Bool { items[id] != nil }

    public mutating func add(_ item: Item, vectors itemVectors: [(time: Double, vector: [Float])]) {
        precondition(itemVectors.allSatisfy { $0.vector.count == dimensions }, "vector size doesn't match the index")
        items[item.id] = item
        for (time, vector) in itemVectors {
            entries.append(Entry(id: item.id, time: time))
            vectors += vector
        }
    }

    /// Drops everything that's no longer in the library.
    public mutating func keep(only ids: Set<String>) {
        let kept = entries.indices.filter { ids.contains(entries[$0].id) }
        guard kept.count < entries.count else { return }
        vectors = kept.flatMap { vectors[$0 * dimensions ..< ($0 + 1) * dimensions] }
        entries = kept.map { entries[$0] }
        items = items.filter { ids.contains($0.key) }
    }

    /// The items closest to `query`, best first, each counted once at its best moment.
    public func search(_ query: [Float], limit: Int, where include: (Item) -> Bool = { _ in true }) -> [Match] {
        precondition(query.count == dimensions, "query size doesn't match the index")
        guard !entries.isEmpty else { return [] }

        // every vector is unit length, so one matrix × vector gives all the cosines at once
        var scores = [Float](repeating: 0, count: entries.count)
        vDSP_mmul(vectors, 1, query, 1, &scores, 1, vDSP_Length(entries.count), 1, vDSP_Length(dimensions))

        var best: [String: (time: Double, cosine: Float)] = [:]
        for (entry, score) in zip(entries, scores) where score > best[entry.id]?.cosine ?? -.infinity {
            best[entry.id] = (entry.time, score)
        }
        return best
            .compactMap { id, hit in
                guard let item = items[id], include(item) else { return nil }
                return Match(item: item, time: hit.time, cosine: hit.cosine)
            }
            .sorted { $0.cosine > $1.cosine }
            .prefix(limit)
            .map(\.self)
    }

    // MARK: Persistence

    public static func load(from folder: URL, dimensions: Int) throws -> Index {
        var index = Index(dimensions: dimensions)
        let manifestURL = folder.appending(path: "entries.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return index }

        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.dimensions == dimensions else { return index } // a different model: start over
        let halves = try Data(contentsOf: folder.appending(path: "vectors.f16"))
        guard halves.count == manifest.entries.count * dimensions * 2 else { return index }

        index.entries = manifest.entries
        index.items = manifest.items
        index.vectors = halves.withUnsafeBytes { widen($0) }
        return index
    }

    public func save(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = Manifest(dimensions: dimensions, entries: entries, items: items)
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: "entries.json"), options: .atomic)
        try narrow(vectors).write(to: folder.appending(path: "vectors.f16"), options: .atomic)
    }
}

// half floats on disk, full floats in memory. vImage converts both ways on intel and apple silicon.

private func narrow(_ floats: [Float]) -> Data {
    var halves = Data(count: floats.count * 2)
    floats.withUnsafeBufferPointer { source in
        halves.withUnsafeMutableBytes { destination in
            var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: 1,
                                     width: vImagePixelCount(floats.count), rowBytes: floats.count * 4)
            var to = vImage_Buffer(data: destination.baseAddress, height: 1,
                                   width: vImagePixelCount(floats.count), rowBytes: floats.count * 2)
            vImageConvert_PlanarFtoPlanar16F(&from, &to, 0)
        }
    }
    return halves
}

private func widen(_ halves: UnsafeRawBufferPointer) -> [Float] {
    let count = halves.count / 2
    return [Float](unsafeUninitializedCapacity: count) { floats, initialized in
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: halves.baseAddress), height: 1,
                                 width: vImagePixelCount(count), rowBytes: count * 2)
        var to = vImage_Buffer(data: floats.baseAddress, height: 1,
                               width: vImagePixelCount(count), rowBytes: count * 4)
        vImageConvert_Planar16FtoPlanarF(&from, &to, 0)
        initialized = count
    }
}
