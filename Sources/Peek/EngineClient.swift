import Foundation

/// Starts the engine when the panel needs it and talks to it over pipes. If the engine has quit
/// (it does, a minute after it was last used) the next request simply starts it again.
final class EngineClient {
    /// Every event the engine sends, for progress and the like.
    var onEvent: (Response) -> Void = { _ in }

    private var process: Process?
    private var input: FileHandle?
    private var waiting: [Int: CheckedContinuation<Response, Never>] = [:]
    private var nextID = 1

    var isRunning: Bool { process?.isRunning == true }

    /// Fire and forget: `index`.
    func send(_ request: Request) {
        guard let input = launchIfNeeded(), let data = try? JSONEncoder().encode(request) else { return }
        try? input.write(contentsOf: data + Data("\n".utf8))
    }

    /// A request with an answer: waits for the engine's `results`, `files` or `failed` for it.
    func ask(_ operation: Request.Operation, query: String? = nil, ids: [String]? = nil) async -> Response {
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            send(Request(operation: operation, id: id, query: query, ids: ids))
        }
    }

    private func launchIfNeeded() -> FileHandle? {
        if isRunning, let input { return input }
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["serve"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        self.process = process
        input = stdin.fileHandleForWriting

        Task {
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    guard let response = try? JSONDecoder().decode(Response.self, from: Data(line.utf8)) else { continue }
                    receive(response)
                }
            } catch {}
        }
        return input
    }

    private func receive(_ response: Response) {
        onEvent(response)
        switch response.event {
        case .results, .files, .failed:
            waiting.removeValue(forKey: response.id)?.resume(returning: response)
        default:
            break
        }
    }

    private func ended() {
        process = nil
        input = nil
        // anything still waiting would hang forever; answer it
        for continuation in waiting.values {
            continuation.resume(returning: Response(event: .failed))
        }
        waiting.removeAll()
    }
}
