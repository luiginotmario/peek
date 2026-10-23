import Foundation
import ImageIO
import Observation

/// Everything the panel shows. The work itself happens in the engine process (see Engine.swift);
/// this side only keeps the few thumbnails on screen, and lets go of those a minute after the
/// panel closes.
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
    /// The filters the last query was read as, like ["goa", "summer 2025"], shown next to the count.
    private(set) var filters: [String] = []
    /// Called when the panel has been put away long enough to let go of everything.
    var onRest: () -> Void = {}

    private let engine = EngineClient()
    private var rest: Task<Void, Never>?
    private var running: Task<Void, Never>?

    init() {
        engine.onEvent = { [weak self] response in self?.receive(response) }
    }

    private func receive(_ response: Response) {
        switch response.event {
        case .denied:
            status = .denied
        case .progress:
            status = .indexing(done: response.done ?? 0, total: response.total ?? 0)
        case .indexed:
            status = .ready(count: response.count ?? 0)
        case .looking:
            filters = response.filters ?? []
            if case .looking = phase { phase = .looking(response.count ?? 0) }
        default:
            break
        }
    }

    // MARK: Panel

    /// The panel opened: catch the index up on new photos (which also starts the engine, so the
    /// first search doesn't wait for it).
    func opened() {
        rest?.cancel()
        engine.send(Request(operation: .index))
    }

    /// The panel closed. A minute later the thumbnails go too; the engine quits on its own.
    func closed() {
        rest?.cancel()
        rest = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            running?.cancel()
            thumbnails = [:]
            phase = .idle
            query = ""
            onRest()
        }
    }

    // MARK: Search

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
        phase = .looking(status.count)
        let response = await engine.ask(.search, query: text)
        guard !Task.isCancelled else { return }
        guard response.event == .results, let results = response.results, !results.isEmpty else {
            phase = .nothing
            return
        }
        filters = response.filters ?? []
        thumbnails = await Self.load(results)
        guard !Task.isCancelled else { return }
        phase = .scanning(results, response.count ?? 0)
    }

    /// The view calls this when the scan line has passed the last row.
    func gather() {
        guard case .scanning(let results, _) = phase else { return }
        phase = .found(results.filter(\.isMatch))
    }

    /// Originals of the picked photos as files, ready for AirDrop or Messages.
    func export(_ ids: [String]) async -> [URL] {
        let response = await engine.ask(.export, ids: ids)
        return (response.files ?? []).map { URL(filePath: $0) }
    }

    @concurrent
    private static func load(_ results: [Result]) async -> [String: CGImage] {
        var images: [String: CGImage] = [:]
        for result in results {
            guard let path = result.thumbnail,
                  let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            images[result.id] = image
        }
        return images
    }
}

private extension Search.Status {
    var count: Int {
        switch self {
        case .indexing(let done, _): done
        case .ready(let count): count
        default: 0
        }
    }
}
