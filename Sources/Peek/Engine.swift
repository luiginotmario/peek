import AppKit
import ImageIO
import PeekCore
import UniformTypeIdentifiers

/// The engine: everything heavy, in its own process. The menu bar app starts it (`Peek serve`) when
/// the panel needs it, and it quits by itself a minute after the last request, or as soon as the
/// app goes away. While it runs it holds the index, the text model and the place list; once it
/// exits, all of that memory is back with macOS.
final class Engine {
    static let idleTimeout: Duration = .seconds(60)
    static let thumbnails = URL.cachesDirectory.appending(path: "Peek/Thumbnails")

    private let models = Commands.models
    private let indexFolder = Commands.indexFolder
    private var index: Index?
    private var encoder: TextEncoder?
    private var places: Places?
    private var indexing: Task<Void, Never>?
    private var behind = 0 // photos the running index pass still has to read
    private var idle: Task<Void, Never>?

    func serve() async {
        try? FileManager.default.createDirectory(at: Self.thumbnails, withIntermediateDirectories: true)
        scheduleExit()
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else { continue }
                idle?.cancel()
                Task { await handle(request) }
            }
        } catch {}
        quit() // stdin closed: the app is gone
    }

    private func handle(_ request: Request) async {
        switch request.operation {
        case .index:
            // the panel just opened: load the text model while the person types
            Task { _ = try? await loadedEncoder() }
            if indexing == nil {
                indexing = Task {
                    await bringIndexUpToDate()
                    indexing = nil
                    scheduleExit()
                }
            }
            return // the indexing task schedules the exit when it's done
        case .search:
            await search(request.query ?? "", id: request.id)
        case .export:
            await export(request.ids ?? [], id: request.id)
        }
        scheduleExit()
    }

    private func bringIndexUpToDate() async {
        guard await Library.requestAccess() != .denied else {
            send(Response(event: .denied))
            return
        }
        do {
            let fresh = try await Indexer(files: models, folder: indexFolder).run(from: try? loadedIndex()) { progress in
                Task { @MainActor in
                    self.behind = progress.total - progress.done
                    self.send(Response(event: .progress, done: progress.done, total: progress.total))
                }
            }
            index = fresh
            send(Response(event: .indexed, count: fresh.count))
        } catch {
            send(Response(event: .failed))
        }
    }

    private func search(_ text: String, id: Int) async {
        do {
            let index = try loadedIndex()
            let places = try loadedPlaces()
            let query = Query.parse(text, places: places)
            let include = { (item: Item) in query.includes(item, places: places) }
            let count = query.isFiltered ? index.count(where: include) : index.count
            send(Response(event: .looking, id: id, count: count, filters: query.labels))

            let hits = query.text.isEmpty
                ? index.newest(limit: Self.candidates, where: include) // only filters: newest first
                : index.search(try await loadedEncoder().encode(query.text), limit: Self.candidates, where: include)
            let best = hits.first?.cosine ?? 0
            let thumbnails = await writeThumbnails(for: hits.map(\.item.id))
            let results = hits.enumerated().map { position, hit in
                Result(id: hit.item.id, kind: Result.Kind(rawValue: hit.item.kind.rawValue) ?? .photo, time: hit.time,
                       cosine: hit.cosine,
                       isMatch: position < Self.maxMatches && (query.text.isEmpty || hit.cosine >= best - Self.matchMargin),
                       thumbnail: thumbnails[hit.item.id]?.path)
            }
            send(Response(event: .results, id: id, count: count, filters: query.labels, results: results))
        } catch {
            send(Response(event: .failed, id: id))
        }
    }

    private func export(_ ids: [String], id: Int) async {
        let assets = Library.assets(withIDs: ids)
        var files: [String] = []
        for assetID in ids {
            guard let asset = assets[assetID], let file = try? await Library.export(asset) else { continue }
            files.append(file.path)
        }
        send(Response(event: .files, id: id, files: files))
    }

    // MARK: Search tuning

    /// How many candidates fill the grid, and the most that can count as matches.
    static let candidates = 24
    static let maxMatches = 8
    /// A candidate is a match when it's this close to the best one. SigLIP's cosines sit in a narrow
    /// band, so a gap from the top separates "this" from "sort of like this" better than a fixed cutoff.
    static let matchMargin: Float = 0.012

    // MARK: Plumbing

    private func send(_ response: Response) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private func scheduleExit() {
        idle?.cancel()
        idle = Task {
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, indexing == nil else { return }
            quit()
        }
    }

    private func quit() {
        try? FileManager.default.removeItem(at: Self.thumbnails)
        exit(0)
    }

    private func loadedIndex() throws -> Index {
        // during a big first read, the copy on disk (saved every few hundred photos) is the freshest
        let reread = indexing != nil && behind > 500
        if let index, !reread { return index }
        let meta = try SiglipMeta(contentsOf: models.folder.appending(path: "siglip.json"))
        let fresh = try Index.load(from: indexFolder, dimensions: meta.dimensions)
        if !reread { index = fresh }
        return fresh
    }

    private func loadedEncoder() async throws -> TextEncoder {
        if let encoder { return encoder }
        let fresh = try await TextEncoder(files: models)
        encoder = fresh
        return fresh
    }

    private func loadedPlaces() throws -> Places {
        if let places { return places }
        let fresh = try Places(contentsOf: Commands.places)
        places = fresh
        return fresh
    }

    /// Small jpegs the panel reads straight from disk, so the app itself never touches photos.
    private func writeThumbnails(for ids: [String]) async -> [String: URL] {
        let assets = Library.assets(withIDs: ids)
        return await withTaskGroup(of: (String, URL?).self) { group in
            for (id, asset) in assets {
                let file = Self.thumbnails.appending(path: id.replacing("/", with: "_") + ".jpg")
                group.addTask {
                    if FileManager.default.fileExists(atPath: file.path) { return (id, file) }
                    guard let image = await Library.thumbnail(for: asset, side: 360),
                          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                    else { return (id, nil) }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                    return (id, CGImageDestinationFinalize(destination) ? file : nil)
                }
            }
            var files: [String: URL] = [:]
            for await (id, file) in group {
                files[id] = file
            }
            return files
        }
    }
}
