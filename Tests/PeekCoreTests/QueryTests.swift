import Foundation
import Testing
@testable import PeekCore

private let places = try! Places(contentsOf: URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "App/places.json"))

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23))!

private func parse(_ text: String) -> Query {
    Query.parse(text, places: places, now: today, calendar: calendar)
}

@Test(arguments: [
    ("me on a boat in goa", "me on a boat", "goa"),
    ("beach in bali", "beach", "bali"),
    ("tokyo at night", "at night", "tokyo"),
    ("sunset from muscat", "sunset", "muscat"),
    ("dinner in the usa", "dinner", "united states"),
])
func `places come out of the text`(input: String, text: String, place: String) {
    let query = parse(input)
    #expect(query.area?.name.lowercased() == place)
    #expect(query.text == text)
}

@Test(arguments: ["a yellow boat", "the red mountain", "me and a girl", "sunset over the sea", "turkey dinner",
                  "a walk in central park", "fine china plates", "me at the beach"])
func `plain descriptions are left alone`(input: String) {
    let query = parse(input)
    #expect(query.area == nil)
    #expect(query.dates == nil)
    #expect(query.text == input)
}

@Test(arguments: [
    ("beach last summer", "beach", "summer 2026"),
    ("snow in winter 2024", "snow", "winter 2024"),
    ("dogs in 2023", "dogs", "2023"),
    ("pizza in march", "pizza", "march 2026"),
    ("party in december", "party", "december 2025"),
    ("hiking last month", "hiking", "last month"),
])
func `dates come out of the text`(input: String, text: String, label: String) {
    let query = parse(input)
    #expect(query.datesLabel == label)
    #expect(query.text == text)
}

@Test func `last summer means the summer that just ended`() throws {
    let dates = try #require(parse("last summer").dates)
    #expect(calendar.component(.month, from: dates.start) == 6)
    #expect(calendar.component(.year, from: dates.start) == 2026)
}

@Test func `filters only leave nothing for siglip`() {
    let query = parse("videos from tokyo in 2025")
    #expect(query.kinds == [.video])
    #expect(query.area?.name == "Tokyo")
    #expect(query.datesLabel == "2025")
    #expect(query.text.isEmpty)
}

@Test func `favorites and screenshots`() {
    #expect(parse("my favorites from japan").favorites)
    #expect(parse("screenshots of tweets").kinds == [.screenshot])
}

@Test func `a photo near the city counts, one across the country doesn't`() throws {
    let tokyo = try #require(places.area(named: "tokyo"))
    #expect(places.contains(tokyo, latitude: 35.66, longitude: 139.70))   // shibuya
    #expect(!places.contains(tokyo, latitude: 34.69, longitude: 135.50))  // osaka
    let goa = try #require(places.area(named: "goa"))
    #expect(places.contains(goa, latitude: 15.55, longitude: 73.75))      // calangute beach
    #expect(!places.contains(goa, latitude: 19.07, longitude: 72.88))     // mumbai
}
