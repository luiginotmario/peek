import Foundation

/// What someone typed, split into the part SigLIP should see and the part the metadata answers:
/// "me on a boat in goa last summer" → text "me on a boat", place Goa, June–August of last summer.
public struct Query: Sendable {
    public var text: String
    public var area: Places.Area?
    public var dates: DateInterval?
    public var datesLabel: String?
    public var kinds: Set<Item.Kind> = []
    public var favorites = false

    /// The filters in words, for the panel: ["goa", "summer 2025", "videos"].
    public var labels: [String] {
        var labels: [String] = []
        if let area { labels.append(area.name.lowercased()) }
        if let datesLabel { labels.append(datesLabel) }
        if kinds.contains(.video) { labels.append("videos") }
        if kinds.contains(.screenshot) { labels.append("screenshots") }
        if kinds.contains(.livePhoto) { labels.append("live photos") }
        if kinds.contains(.panorama) { labels.append("panoramas") }
        if favorites { labels.append("favorites") }
        return labels
    }

    public var isFiltered: Bool { area != nil || dates != nil || !kinds.isEmpty || favorites }

    public func includes(_ item: Item, places: Places?) -> Bool {
        if favorites, !item.favorite { return false }
        if !kinds.isEmpty, !kinds.contains(item.kind) { return false }
        if let dates {
            guard let created = item.created, dates.contains(created) else { return false }
        }
        if let area {
            guard let places, let latitude = item.latitude, let longitude = item.longitude,
                  places.contains(area, latitude: latitude, longitude: longitude) else { return false }
        }
        return true
    }

    // MARK: Parsing

    private static let filler: Set<String> = [
        "find", "show", "search", "get", "photos", "photo", "pictures", "picture", "pics", "pic", "images", "image",
        "of", "my", "all", "the", "from", "in", "at", "some", "a", "any", "taken", "during", "with",
    ]
    private static let prepositions: Set<String> = ["in", "at", "from", "near", "around", "to"]
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                                 "september", "october", "november", "december"]
    private static let monthShort = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let seasons: [String: (start: Int, months: Int)] = [ // start month, length
        "spring": (3, 3), "summer": (6, 3), "autumn": (9, 3), "fall": (9, 3), "winter": (12, 3),
    ]

    public static func parse(_ raw: String, places: Places?, now: Date = .now, calendar: Calendar = .current) -> Query {
        var words = raw.lowercased()
            .replacing(/[^\p{L}\p{N}'\- ]/, with: " ")
            .split(separator: " ").map(String.init)
        var query = Query(text: "")

        // media types and favorites
        let kindWords: [String: Item.Kind] = [
            "video": .video, "videos": .video, "clip": .video, "clips": .video,
            "screenshot": .screenshot, "screenshots": .screenshot,
            "panorama": .panorama, "panoramas": .panorama, "pano": .panorama,
        ]
        words = words.enumerated().compactMap { position, word in
            if let kind = kindWords[word] { query.kinds.insert(kind); return nil }
            if ["favorite", "favorites", "favourite", "favourites", "faves", "starred"].contains(word) {
                query.favorites = true
                return nil
            }
            if word == "live", position + 1 < words.count, words[position + 1].hasPrefix("photo") {
                query.kinds.insert(.livePhoto)
                return nil
            }
            return word
        }

        query.findDates(in: &words, now: now, calendar: calendar)
        if let places { query.findPlace(in: &words, places: places) }

        let rest = words.filter { !$0.isEmpty }
        query.text = rest.allSatisfy(filler.contains) ? "" : rest.joined(separator: " ")
        return query
    }

    private mutating func findPlace(in words: inout [String], places: Places) {
        // "in goa", "at the eiffel tower" (towns only), or a famous name on its own: "tokyo at night"
        // where the phrase's lead-in starts: "in the usa" loses "in the" along with "usa"
        func leadIn(_ start: Int) -> Int {
            var from = start
            if from > 0, words[from - 1] == "the" { from -= 1 }
            if from > 0, Self.prepositions.contains(words[from - 1]) { from -= 1 }
            return from
        }
        for requirePreposition in [true, false] {
            for start in words.indices {
                let from = leadIn(start)
                if requirePreposition, from == start || !Self.prepositions.contains(words[from]) { continue }
                for length in stride(from: min(3, words.count - start), through: 1, by: -1) {
                    let phrase = words[start ..< start + length].joined(separator: " ")
                    guard phrase.count >= 2, places.isSpecific(phrase), let area = places.area(named: phrase),
                          requirePreposition || places.isProminent(area) else { continue }
                    self.area = area
                    words.removeSubrange(from ..< start + length)
                    return
                }
            }
        }
    }

    private mutating func findDates(in words: inout [String], now: Date, calendar: Calendar) {
        let year = calendar.component(.year, from: now)
        func interval(year: Int, month: Int, months: Int) -> DateInterval? {
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let end = calendar.date(byAdding: .month, value: months, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        func explicitYear(after index: Int) -> Int? {
            guard index < words.count, let value = Int(words[index]), (1990...2100).contains(value) else { return nil }
            return value
        }

        for position in words.indices {
            let word = words[position]
            let previous = position > 0 ? words[position - 1] : ""
            let relative = previous == "last" || previous == "this"
            var consumed = position ..< position + 1
            var found: (DateInterval, String)?

            switch word {
            case "today":
                found = (calendar.dateInterval(of: .day, for: now)!, "today")
            case "yesterday":
                found = (calendar.dateInterval(of: .day, for: calendar.date(byAdding: .day, value: -1, to: now)!)!, "yesterday")
            case _ where relative && ["week", "month", "year"].contains(word): // a where on a multi-pattern case guards only its last pattern
                let unit: Calendar.Component = word == "week" ? .weekOfYear : word == "month" ? .month : .year
                let shift = previous == "last" ? -1 : 0
                let anchor = calendar.date(byAdding: unit, value: shift, to: now)!
                found = (calendar.dateInterval(of: unit, for: anchor)!, "\(previous) \(word)")
                consumed = position - 1 ..< position + 1
            case _ where Self.seasons[word] != nil:
                let season = Self.seasons[word]!
                var seasonYear: Int
                if let given = explicitYear(after: position + 1) {
                    seasonYear = given
                    consumed = position ..< position + 2
                } else {
                    // the most recent one that has started, or the one before it for "last"
                    seasonYear = year
                    if let this = interval(year: year, month: season.start, months: season.months), this.start > now { seasonYear -= 1 }
                    if previous == "last", let this = interval(year: seasonYear, month: season.start, months: season.months),
                       this.end > now { seasonYear -= 1 }
                }
                if relative { consumed = position - 1 ..< consumed.upperBound }
                // winter starts in december and is named for the year it started
                if let dates = interval(year: seasonYear, month: season.start, months: season.months) {
                    found = (dates, "\(word) \(seasonYear)")
                }
            case _ where Self.months.contains(word) || (Self.monthShort.contains(word) && word != "may" && word.count == 3):
                let month = (Self.months.firstIndex(of: word) ?? Self.monthShort.firstIndex(of: word)!) + 1
                var monthYear = year
                if let given = explicitYear(after: position + 1) {
                    monthYear = given
                    consumed = position ..< position + 2
                } else {
                    if month > calendar.component(.month, from: now) { monthYear -= 1 }
                    if previous == "last", month == calendar.component(.month, from: now) { monthYear -= 1 }
                }
                if relative { consumed = position - 1 ..< consumed.upperBound }
                if let dates = interval(year: monthYear, month: month, months: 1) {
                    found = (dates, "\(Self.months[month - 1]) \(monthYear)")
                }
            case _ where Int(word).map { (1990...2100).contains($0) } ?? false:
                if let dates = interval(year: Int(word)!, month: 1, months: 12) { found = (dates, word) }
            default:
                break
            }

            if let (dates, label) = found {
                self.dates = dates
                datesLabel = label
                var from = consumed.lowerBound
                if from > 0, ["in", "from", "during", "of", "on"].contains(words[from - 1]) { from -= 1 }
                words.removeSubrange(from ..< min(consumed.upperBound, words.count))
                return
            }
        }
    }
}
