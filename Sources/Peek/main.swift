import Foundation
import PeekCore

// for now peek is driven from the terminal so we can judge search quality before building the
// panel. macos only shows the photos prompt to a real .app, so scripts/peek.sh runs it via `open`.

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
let models = ModelFiles(folder: ProcessInfo.processInfo.environment["PEEK_MODELS"].map { URL(filePath: $0) }
    ?? Bundle.main.resourceURL!.appending(path: "Models"))
let indexFolder = URL.applicationSupportDirectory.appending(path: "Peek/Index")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("peek: \(message)\n".utf8))
    exit(1)
}

func requireAccess() async {
    switch await Library.requestAccess() {
    case .full: break
    case .limited: print("note: Photos access is limited to the photos you picked; allow Full Access to search everything")
    case .denied: fail("no Photos access. Allow it in System Settings → Privacy & Security → Photos")
    }
}

switch arguments.first {
case "index":
    await requireAccess()
    let started = Date.now
    let index = try await Indexer(files: models, folder: indexFolder).run { progress in
        print("indexing \(progress.done)/\(progress.total)")
    }
    print(String(format: "✓ %d items, %d vectors in %.0fs → %@",
                 index.count, index.entries.count, Date.now.timeIntervalSince(started), indexFolder.path))

case "search":
    let words = arguments.dropFirst().prefix { !$0.hasPrefix("--") }
    guard !words.isEmpty else { fail("usage: peek search <query> [--limit n] [--sheet out.jpg]") }
    let query = words.joined(separator: " ")
    let limit = arguments.firstIndex(of: "--limit").flatMap { Int(arguments[$0 + 1]) } ?? 24
    let sheet = arguments.firstIndex(of: "--sheet").map { URL(filePath: arguments[$0 + 1]) }

    let meta = try SiglipMeta(contentsOf: models.folder.appending(path: "siglip.json"))
    let loading = Date.now
    let index = try Index.load(from: indexFolder, dimensions: meta.dimensions)
    guard index.count > 0 else { fail("the index is empty: run `peek index` first") }
    let encoder = try await TextEncoder(files: models)
    let loaded = Date.now
    let matches = index.search(try encoder.encode(query), limit: limit)
    let searched = Date.now

    print(String(format: "%@ — %d items, load %.0f ms, search %.0f ms",
                 query, index.count, loaded.timeIntervalSince(loading) * 1000, searched.timeIntervalSince(loaded) * 1000))
    for (rank, match) in matches.enumerated() {
        let item = match.item
        let date = item.created?.formatted(date: .abbreviated, time: .omitted) ?? "—"
        let place = item.latitude.map { String(format: "%.3f,%.3f", $0, item.longitude ?? 0) } ?? "—"
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

case "tokens":
    let encoder = try await TextEncoder(files: models)
    print(encoder.tokens(for: arguments.dropFirst().joined(separator: " ")).prefix { $0 != 0 })

default:
    print("""
    peek index                                   embed every photo and video not yet indexed
    peek search <query> [--limit n] [--sheet f]  best matches, optionally as a contact sheet image
    peek tokens <text>                           the token ids siglip sees
    """)
}
