import Foundation

/// Offline place names: every town over 15,000 people, plus regions and countries, from GeoNames.
/// Turns "goa" into an area, and a photo's GPS into the town it was taken near. Nothing is looked up
/// online. Loaded only while searching.
public final class Places: Sendable {
    public struct City: Sendable {
        public let name: String
        public let latitude: Double
        public let longitude: Double
        public let country: String
        public let region: String?
        public let population: Int
    }

    public enum Area: Sendable {
        case city(City)
        case region(code: String, name: String)
        case country(code: String, name: String)

        public var name: String {
            switch self {
            case .city(let city): city.name
            case .region(_, let name), .country(_, let name): name
            }
        }
    }

    private struct File: Decodable {
        let countries: [String: String]
        let regions: [String: String]
        let cities: [Row]
    }

    // [name, lat, lon, country, region, population]
    private struct Row: Decodable {
        let city: City
        init(from decoder: any Decoder) throws {
            var row = try decoder.unkeyedContainer()
            city = City(name: try row.decode(String.self), latitude: try row.decode(Double.self),
                        longitude: try row.decode(Double.self), country: try row.decode(String.self),
                        region: try row.decodeIfPresent(String.self), population: try row.decode(Int.self))
        }
    }

    /// What people call places that GeoNames spells differently.
    private static let aliases: [String: String] = [
        "usa": "united states", "us": "united states", "america": "united states", "the us": "united states",
        "uk": "united kingdom", "britain": "united kingdom", "nyc": "new york city", "new york": "new york city",
        "la": "los angeles", "sf": "san francisco", "dubai city": "dubai", "holland": "netherlands",
    ]

    private struct Named: Sendable {
        let code: String
        let name: String
    }

    private let cities: [String: City]      // lowercased name → the most populous town by that name
    private let regions: [String: Named]
    private let countries: [String: Named]
    private let grid: [Int: [City]]          // 1° cells, for nearest-town lookups

    public init(contentsOf url: URL) throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        countries = Dictionary(file.countries.map { ($1.lowercased(), Named(code: $0, name: $1)) }) { first, _ in first }
        regions = Dictionary(file.regions.map { ($1.lowercased(), Named(code: $0, name: $1)) }) { first, _ in first }
        cities = Dictionary(file.cities.map { ($0.city.name.lowercased(), $0.city) }) { a, b in a.population >= b.population ? a : b }
        grid = Dictionary(grouping: file.cities.map(\.city)) { Self.cell($0.latitude, $0.longitude) }
    }

    /// The place a phrase names, if it names one. Countries win over regions over towns, so "georgia"
    /// is the country and "goa" is the state rather than a village called Goa.
    public func area(named phrase: String) -> Area? {
        let key = Self.aliases[phrase] ?? phrase
        if let country = countries[key] { return .country(code: country.code, name: country.name) }
        if let region = regions[key] { return .region(code: region.code, name: region.name) }
        if let city = cities[key] { return .city(city) }
        return nil
    }

    /// Place names that are also everyday words. They only count after "in", "at" or "from".
    private static let everyday: Set<String> = [
        "turkey", "china", "chad", "jordan", "georgia", "guinea", "niger", "jersey", "japan", "cuba", "panama",
        "nice", "reading", "mobile", "orange", "phoenix", "victoria", "florence", "york", "bath", "split", "sale",
        "male", "batman", "hope", "paris",
    ]
    /// Region names too generic to mean one place even after "in": "in central park", "on the coast".
    private static let generic: Set<String> = [
        "central", "north", "south", "east", "west", "northern", "southern", "eastern", "western", "capital",
        "coast", "island", "islands", "lake", "lakes", "river", "mountain", "mountains", "valley", "upper", "lower",
        "centre", "center", "city", "district", "highlands", "red", "black", "white", "green", "park", "beach",
        "harbour", "harbor", "port", "bay", "sea", "ocean", "forest", "desert", "garden", "lagoon",
    ]

    /// Whether a place is famous and unambiguous enough to be meant without an "in" in front of it:
    /// "tokyo at night" yes, "turkey dinner" no.
    public func isProminent(_ area: Area) -> Bool {
        guard !Self.everyday.contains(area.name.lowercased()) else { return false }
        switch area {
        case .country: return true
        case .region(_, let name): return (cities[name.lowercased()]?.population ?? 0) >= 1_000_000 // tokyo, dubai
        case .city(let city): return city.population >= 1_000_000
        }
    }

    /// Whether a phrase after "in" can name a place at all.
    public func isSpecific(_ phrase: String) -> Bool {
        !Self.generic.contains(phrase)
    }

    public func contains(_ area: Area, latitude: Double, longitude: Double) -> Bool {
        switch area {
        case .city(let city):
            // a city's photos spread past its centre; big cities more so
            let radius = city.population >= 1_000_000 ? 40.0 : 20.0
            return Self.kilometres(latitude, longitude, city.latitude, city.longitude) <= radius
        case .region(let code, _):
            return nearest(latitude, longitude)?.region == code
        case .country(let code, _):
            return nearest(latitude, longitude)?.country == code
        }
    }

    /// The closest town over 15,000 people, within about 150 km.
    public func nearest(_ latitude: Double, _ longitude: Double) -> City? {
        var best: (city: City, distance: Double)?
        let row = Int(floor(latitude)), column = Int(floor(longitude))
        for dy in -1...1 {
            for dx in -1...1 {
                for city in grid[(row + dy) * 1000 + (column + dx)] ?? [] {
                    let distance = Self.kilometres(latitude, longitude, city.latitude, city.longitude)
                    if distance < best?.distance ?? .infinity { best = (city, distance) }
                }
            }
        }
        return best.flatMap { $0.distance <= 150 ? $0.city : nil }
    }

    private static func cell(_ latitude: Double, _ longitude: Double) -> Int {
        Int(floor(latitude)) * 1000 + Int(floor(longitude))
    }

    private static func kilometres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians, dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6371 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
