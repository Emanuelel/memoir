import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

/// Tests for the one thing the journal shows that is not already on this Mac.
///
/// Weather is the third outbound path in a product built on there being two, so most of what is
/// pinned here is the terms it was allowed on rather than the arithmetic: off unless switched
/// on, coarse before it leaves, and nothing attached that says who is asking.
@Suite("Weather")
struct WeatherTests {

    /// A recorded Open-Meteo body. Real shape, so the decoder is tested against what the
    /// service actually returns rather than against a fixture written to match the decoder.
    private let recorded = Data("""
    {"latitude":44.4,"longitude":8.9,"timezone":"Europe/Rome",
     "daily":{"time":["2026-08-15"],"weather_code":[51],
     "temperature_2m_max":[33.1],"temperature_2m_min":[24.0]}}
    """.utf8)

    @Test("Switched off, nothing is sent and nothing is asked")
    func offSendsNothing() async {
        // The whole switch, in one assertion. `allowed: false` must short-circuit before the
        // request is built, so a day with weather off is indistinguishable from a build with
        // no weather code in it.
        let before = OutboundMonitor.shared.snapshot.count

        let day = await Weather.forDay(
            TestClock.reference, latitude: 44.41, longitude: 8.93, allowed: false
        )

        #expect(day == nil)
        #expect(OutboundMonitor.shared.snapshot.count == before, "a request was counted with the switch off")
    }

    @Test("The coordinate is blunted before it leaves")
    func coordinateIsCoarsened() {
        // ~11 km. Enough that the answer is unchanged and the question is much less revealing:
        // an address and a district get the same weather.
        let coarse = Weather.coarsen(latitude: 44.4137, longitude: 8.9333)

        #expect(abs(coarse.lat - 44.4) < 0.0001)
        #expect(abs(coarse.lon - 8.9) < 0.0001)

        // The rounding must not quietly become a truncation towards zero: a southern or
        // western coordinate has to move to the nearest cell like any other.
        let southWest = Weather.coarsen(latitude: -33.87, longitude: -70.65)
        #expect(abs(southWest.lat - -33.9) < 0.0001)
        #expect(abs(southWest.lon - -70.7) < 0.0001)
    }

    @Test("A recorded response becomes a day")
    func decodesARealBody() {
        let day = Weather.decode(recorded)

        #expect(day?.summary == "drizzle")
        #expect(day?.highCelsius == 33.1)
        #expect(day?.lowCelsius == 24.0)
    }

    @Test("A response that is not what we expect is nothing, never a wrong number")
    func rejectsRubbish() {
        #expect(Weather.decode(Data("{}".utf8)) == nil)
        #expect(Weather.decode(Data("not json".utf8)) == nil)
        // Present but empty: the shape is right and the day is missing, which is the case a
        // decoder written against the happy path would read as zero degrees.
        let empty = Data("""
        {"daily":{"time":[],"weather_code":[],"temperature_2m_max":[],"temperature_2m_min":[]}}
        """.utf8)
        #expect(Weather.decode(empty) == nil)
    }

    @Test("Codes are said the way a person would say them")
    func summariesReadLikeSpeech() {
        #expect(Weather.summary(forCode: 0) == "clear")
        #expect(Weather.summary(forCode: 3) == "overcast")
        #expect(Weather.summary(forCode: 95) == "thunderstorms")
        // An unknown code is still a word, never a number on the tile.
        #expect(Weather.summary(forCode: 4_242) == "unsettled")
    }

    // MARK: - The tile

    @Test("The weather tile states the weather and does not interpret it")
    func tileStatesRatherThanInterprets() {
        // "overcast, 24°" and never "a gloomy day". The moment a journal characterises somebody's
        // day back at them it has stopped being their journal.
        let context = DayContext.build(
            captures: [], spans: [],
            weather: .known(Weather.Day(summary: "overcast", highCelsius: 23.6, lowCelsius: 17.2))
        )

        let tile = try? #require(context.items.first)
        #expect(tile?.kind == .weather)
        #expect(tile?.title == "overcast, 24°")
        #expect(tile?.detail == "low 17°")
        #expect(tile?.needs == nil)
    }

    @Test("Switched off, the tile is still there, offering the switch")
    func offStillShowsTheOffer() {
        // The one capability nobody can discover by using the product: off by default, costs a
        // network request, and a switch in Settings for a feature you have never seen is a
        // feature that does not exist. So it says so where it would have appeared.
        let context = DayContext.build(captures: [], spans: [], weather: .off)

        let tile = try? #require(context.items.first)
        #expect(tile?.needs == .weatherSwitch)
        #expect(tile?.line.isEmpty == true, "an offer must not write a line into somebody's journal")
    }

    @Test("Switched on but unlocated, the tile asks for the other switch")
    func needsLocationAsksForLocation() {
        let context = DayContext.build(captures: [], spans: [], weather: .needsLocation)

        #expect(context.items.first?.needs == .locationPermission)
    }

    @Test("A failed lookup is silent")
    func failureShowsNothing() {
        // Switched on, permitted, no answer. Nothing to offer and nothing to ask for: a
        // network that failed is not the user's problem to solve, and a tile saying so would
        // be an error message in a journal.
        #expect(DayContext.build(captures: [], spans: [], weather: .unavailable).isEmpty)
    }

    @Test("Both offers say what turning them on costs")
    func offersStateTheirPrice() {
        // The switch is off by default because of this sentence, so the sentence has to travel
        // with the switch rather than living in a privacy document nobody opens.
        #expect(DayContext.Item.Need.weatherSwitch.cost.contains("open-meteo.com"))
        #expect(DayContext.Item.Need.weatherSwitch.cost.contains("11 km"))
        #expect(DayContext.Item.Need.locationPermission.cost.contains("approximate"))
    }
}
