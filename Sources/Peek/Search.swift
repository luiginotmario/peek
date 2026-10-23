import CoreGraphics
import Foundation
import Observation
import PeekCore

/// One thumbnail in the panel.
struct Result: Identifiable, Hashable {
    let id: String
    let kind: Item.Kind
    let time: Double
    let cosine: Float
    var isMatch: Bool
}

/// Everything the panel shows, and the work behind it.
@Observable
final class Search {
    enum Phase: Equatable {
        case idle
        case looking(Int)             // the query is being compared against this many photos
        case scanning([Result], Int)  // candidates are on screen and the scan line is passing
        case found([Result])          // the matches, gathered into a row
        case nothing
    }

    enum Status: Equatable {
        case unknown
        case denied
        case indexing(done: Int, total: Int)
        case ready(count: Int)
    }

    var query = ""
    private(set) var phase: Phase = .idle
    private(set) var status: Status = .unknown
    private(set) var thumbnails: [String: CGImage] = [:]

    /// How many candidates fill the grid, and the most that can count as matches.
    static let candidates = 24
    static let maxMatches = 8
    /// A candidate is a match when it's this close to the best one. SigLIP's cosines sit in a narrow
    /// band, so a gap from the top separates "this" from "sort of like this" better than a fixed cutoff.
    static let matchMargin: Float = 0.012

    private let models = Commands.models
    private let indexFolder = Commands.indexFolder
    private var index: Index?
    private var encoder: TextEncoder?
    private var unload: Task<Void, Never>?
    private var running: Task<Void, Never>?


    // MARK: Library

    /// Asks for access the first time, then brings the index up to date in the background.
    func prepareLibrary() async {
        guard status == .unknown else { return }
        switch await Library.requestAccess() {
        case .denied:
            status = .denied
            return
        case .full, .limited:
            break
        }
        status = .indexing(done: 0, total: 0)
        do {
            let fresh = try await Indexer(files: models, folder: indexFolder).run { progress in
                Task { @MainActor [weak self] in self?.status = .indexing(done: progress.done, total: progress.total) }
            }
            index = fresh
            status = .ready(count: fresh.count)
        } catch {
            status = .ready(count: index?.count ?? 0)
        }
    }

    // MARK: Search

    /// The panel opened: load the text model now so the first search feels instant.
    func warmUp() {
        unload?.cancel()
        guard encoder == nil else { return }
        Task {
            encoder = try? await TextEncoder(files: models)
        }
    }

    /// The panel closed: give the memory back after a minute of not searching.
    func coolDown() {
        unload?.cancel()
        unload = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            encoder = nil
            if case .ready = status { index = nil }
        }
    }

    func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        running?.cancel()
        running = Task { await run(text) }
    }

    func clear() {
        running?.cancel()
        phase = .idle
    }

    private func run(_ text: String) async {
        do {
            let index = try loadedIndex()
            phase = .looking(index.count)
            let encoder = try await loadedEncoder()
            let query = try encoder.encode(text)
            let hits = index.search(query, limit: Self.candidates)
            guard let best = hits.first else {
                phase = .nothing
                return
            }

            var results = hits.map {
                Result(id: $0.item.id, kind: $0.item.kind, time: $0.time, cosine: $0.cosine, isMatch: false)
            }
            for i in results.indices.prefix(Self.maxMatches) where results[i].cosine >= best.cosine - Self.matchMargin {
                results[i].isMatch = true
            }
            await loadThumbnails(for: results.map(\.id))
            try Task.checkCancellation()
            phase = .scanning(results, index.count)
        } catch is CancellationError {
            return
        } catch {
            phase = .nothing
        }
    }

    /// The view calls this when the scan line has passed the last row.
    func gather() {
        guard case .scanning(let results, _) = phase else { return }
        phase = .found(results.filter(\.isMatch))
    }

    private func loadedEncoder() async throws -> TextEncoder {
        if let encoder { return encoder }
        let fresh = try await TextEncoder(files: models)
        encoder = fresh
        return fresh
    }

    private func loadedIndex() throws -> Index {
        if let index { return index }
        let meta = try SiglipMeta(contentsOf: models.folder.appending(path: "siglip.json"))
        let fresh = try Index.load(from: indexFolder, dimensions: meta.dimensions)
        if case .ready = status { index = fresh } // while indexing, reload each time to see new photos
        return fresh
    }

    private func loadThumbnails(for ids: [String]) async {
        let missing = ids.filter { thumbnails[$0] == nil }
        let assets = Library.assets(withIDs: missing)
        let loaded = await withTaskGroup(of: (String, CGImage?).self) { group in
            for (id, asset) in assets {
                group.addTask { (id, await Library.thumbnail(for: asset, side: 360)) }
            }
            var loaded: [String: CGImage] = [:]
            for await (id, image) in group {
                loaded[id] = image
            }
            return loaded
        }
        thumbnails.merge(loaded.compactMapValues(\.self)) { $1 }
        if thumbnails.count > 400 { thumbnails = thumbnails.filter { ids.contains($0.key) } }
    }
}
