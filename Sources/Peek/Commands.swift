import Foundation
import PeekCore

/// The terminal interface we use to judge search quality before the panel exists.
/// macOS only shows the Photos prompt to a real .app, so scripts/peek.sh runs these via `open`.
enum Commands {
    static let models = ModelFiles(folder: ProcessInfo.processInfo.environment["PEEK_MODELS"].map { URL(filePath: $0) }
        ?? Bundle.main.resourceURL!.appending(path: "Models"))
    static let indexFolder = URL.applicationSupportDirectory.appending(path: "Peek/Index")
    static let places = Bundle.main.resourceURL!.appending(path: "places.json")

    static func run(_ arguments: [String]) async throws {
        switch arguments.first {
        case "index": try await index()
        case "search": try await search(Array(arguments.dropFirst()))
        case "tokens": try await tokens(arguments.dropFirst().joined(separator: " "))
        case "serve": await Engine().serve() // the menu bar app's engine, spoken to over stdin/stdout
        default:
            print("""
            peek index                                   embed every photo and video not yet indexed
            peek search <query> [--limit n] [--sheet f]  best matches, optionally as a contact sheet image
            peek tokens <text>                           the token ids siglip sees
            """)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("peek: \(message)\n".utf8))
        exit(1)
    }

    private static func requireAccess() async {
        switch await Library.requestAccess() {
        case .full: break
        case .limited: print("note: Photos access is limited to the photos you picked; allow Full Access to search everything")
        case .denied: fail("no Photos access. Allow it in System Settings → Privacy & Security → Photos")
        }
    }

    private static func index() async throws {
        await requireAccess()
        let started = Date.now
        let index = try await Indexer(files: models, folder: indexFolder).run { progress in
            print("indexing \(progress.done)/\(progress.total)")
        }
        print(String(format: "✓ %d items, %d vectors in %.0fs → %@",
                     index.count, index.entries.count, Date.now.timeIntervalSince(started), indexFolder.path))
    }

    private static func search(_ arguments: [String]) async throws {
        let words = arguments.prefix { !$0.hasPrefix("--") }
        guard !words.isEmpty else { fail("usage: peek search <query> [--limit n] [--sheet out.jpg]") }
        let query = words.joined(separator: " ")
        let limit = value(of: "--limit", in: arguments).flatMap(Int.init) ?? 24
        let sheet = value(of: "--sheet", in: arguments).map { URL(filePath: $0) }

        let meta = try SiglipMeta(contentsOf: models.folder.appending(path: "siglip.json"))
        let loading = Date.now
        let index = try Index.load(from: indexFolder, dimensions: meta.dimensions)
        guard index.count > 0 else { fail("the index is empty: run `peek index` first") }
        let encoder = try await TextEncoder(files: models)
        let places = try Places(contentsOf: Self.places)
        let loaded = Date.now
        let parsed = Query.parse(query, places: places)
        let include = { (item: Item) in parsed.includes(item, places: places) }
        let matches = parsed.text.isEmpty
            ? index.newest(limit: limit, where: include)
            : index.search(try encoder.encode(parsed.text), limit: limit, where: include)
        let searched = Date.now

        print(String(format: "%@ — %d items, load %.0f ms, search %.0f ms", query, index.count,
                     loaded.timeIntervalSince(loading) * 1000, searched.timeIntervalSince(loaded) * 1000))
        print("  text: \"\(parsed.text)\"  filters: \(parsed.labels.isEmpty ? "none" : parsed.labels.joined(separator: " · "))"
              + "  (\(index.count(where: include)) items pass)")
        for (rank, match) in matches.enumerated() {
            let item = match.item
            let date = item.created?.formatted(date: .abbreviated, time: .omitted) ?? "—"
            let place = item.latitude.flatMap { places.nearest($0, item.longitude ?? 0)?.name } ?? "—"
            let moment = item.kind == .video ? String(format: " @%.0fs", match.time) : ""
            print(String(format: "%2d  %5.1f%%  cos %.3f  %-10@ %@  %@%@",
                         rank + 1, meta.probability(match.cosine) * 100, match.cosine,
                         item.kind.rawValue, date, place, moment))
        }
        if let sheet {
            await requireAccess()
            try await ContactSheet.write(matches, to: sheet)
            print("sheet → \(sheet.path)")
        }
    }

    private static func tokens(_ text: String) async throws {
        let encoder = try await TextEncoder(files: models)
        print(encoder.tokens(for: text).prefix { $0 != 0 })
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let position = arguments.firstIndex(of: flag), position + 1 < arguments.count else { return nil }
        return arguments[position + 1]
    }
}
