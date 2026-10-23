import Foundation

// the menu bar app and its engine talk in json lines over the engine's stdin and stdout.
// the app never loads photos, core ml or the index itself: that all lives in the engine, which
// quits a minute after its last request so nothing stays in memory while peek isn't being used.

struct Request: Codable {
    enum Operation: String, Codable {
        case index    // bring the index up to date; streams progress, ends with `indexed`
        case search   // ends with `results`
        case export   // originals to temporary files for sharing; ends with `files`
    }

    var operation: Operation
    var id = 0
    var query: String?
    var ids: [String]?
}

struct Response: Codable {
    enum Event: String, Codable {
        case denied, progress, indexed, looking, results, files, failed
    }

    var event: Event
    var id = 0
    var done: Int?
    var total: Int?
    var count: Int?
    var filters: [String]?
    var results: [Result]?
    var files: [String]?
}

/// One thumbnail in the panel. The engine writes the image to `thumbnail`; the app just reads the file.
struct Result: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case photo, video, livePhoto, screenshot, portrait, panorama
    }

    let id: String
    let kind: Kind
    let time: Double
    let cosine: Float
    var isMatch: Bool
    var thumbnail: String?
}
