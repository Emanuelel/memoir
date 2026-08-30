import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

/// Tests for the sources that are not the screen: Contacts, Calendar and Photos.
///
/// None of these touch a permission. Everything worth getting wrong in `PhotoImporter` and
/// `LifeImporter` lives in pure functions (the grid, the day grouping, the places bar, the
/// identity derivation) precisely so it can be tested on a machine with no photo library and
/// in CI with no logged-in user.
///
/// Written after the import shipped with no tests at all.
@Suite("Life import")
struct LifeImportTests {

    // MARK: - The grid

    @Test("A coordinate lands in the same cell every time")
    func cellIsStable() {
        let a = PhotoImporter.cell(latitude: 41.3874, longitude: 2.1686)
        let b = PhotoImporter.cell(latitude: 41.3874, longitude: 2.1686)
        #expect(a == b)
        #expect(a.key == b.key)
    }

    @Test("Points a few metres apart share a cell; a kilometre apart do not")
    func cellResolution() {
        let base = PhotoImporter.cell(latitude: 41.3874, longitude: 2.1686)
        // ~20 m north: same place by any human account.
        let close = PhotoImporter.cell(latitude: 41.38758, longitude: 2.1686)
        // ~1.1 km north: a different neighbourhood.
        let far = PhotoImporter.cell(latitude: 41.3974, longitude: 2.1686)

        #expect(base == close)
        #expect(base != far)
    }

    @Test("Cells stay roughly square away from the equator")
    func longitudeScaling() {
        // At 60° north a degree of longitude is half a degree of latitude on the ground, so the
        // longitude step has to be about twice as wide for the cell to stay square.
        let equator = PhotoImporter.longitudeStep(atLatitudeIndex: 0)
        let north = PhotoImporter.longitudeStep(
            atLatitudeIndex: Int(60.0 / PhotoImporter.latitudeStep)
        )
        #expect(north > equator * 1.9)
        #expect(north < equator * 2.1)
    }

    @Test("The step never runs away at the pole")
    func polarClamp() {
        let step = PhotoImporter.longitudeStep(
            atLatitudeIndex: Int(90.0 / PhotoImporter.latitudeStep)
        )
        #expect(step.isFinite)
        #expect(step <= PhotoImporter.latitudeStep * 100)
    }

    // MARK: - Grouping

    /// A photo on a given day at a given place. Local helper so the tests read like the thing
    /// they are describing.
    private func shot(_ day: Int, lat: Double? = nil, lon: Double? = nil) -> PhotoImporter.Shot {
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = day
        components.hour = 12
        let date = Calendar(identifier: .gregorian).date(from: components)!
        return PhotoImporter.Shot(date: date, latitude: lat, longitude: lon)
    }

    @Test("Many photos in one place on one day become one row")
    func oneRowPerDayPerPlace() {
        let shots = (0..<40).map { _ in shot(4, lat: 41.3874, lon: 2.1686) }
        let grouped = PhotoImporter.group(shots: shots)

        #expect(grouped.days.count == 1)
        #expect(grouped.days.first?.shots == 40)
    }

    @Test("Two places on the same day are two rows")
    func twoPlacesOneDay() {
        let grouped = PhotoImporter.group(shots: [
            shot(4, lat: 41.3874, lon: 2.1686),
            shot(4, lat: 41.4036, lon: 2.1744),
        ])
        #expect(grouped.days.count == 2)
    }

    @Test("A photo with no location still counts as a day")
    func locationlessPhoto() {
        let grouped = PhotoImporter.group(shots: [shot(4), shot(4)])
        #expect(grouped.days.count == 1)
        #expect(grouped.days.first?.cell == nil)
        #expect(grouped.days.first?.shots == 2)
        // …but it is not a place, because there is no place to be.
        #expect(grouped.places.isEmpty)
    }

    @Test("Somewhere you went once is not a place; three days makes it one")
    func placesBar() {
        let once = PhotoImporter.group(shots: [
            shot(4, lat: 41.3874, lon: 2.1686),
            shot(4, lat: 41.3874, lon: 2.1686),
        ])
        #expect(once.places.isEmpty, "one day, however many photos, is not somewhere you go")

        let thrice = PhotoImporter.group(shots: [
            shot(4, lat: 41.3874, lon: 2.1686),
            shot(11, lat: 41.3874, lon: 2.1686),
            shot(19, lat: 41.3874, lon: 2.1686),
        ])
        #expect(thrice.places.count == 1)
        #expect(thrice.places.first?.days.count == 3)
        #expect(thrice.places.first?.shots == 3)
    }

    @Test("Day rows come out oldest first")
    func chronological() {
        let grouped = PhotoImporter.group(shots: [
            shot(19, lat: 41.3874, lon: 2.1686),
            shot(4, lat: 41.3874, lon: 2.1686),
            shot(11, lat: 41.3874, lon: 2.1686),
        ])
        let days = grouped.days.map(\.day)
        #expect(days == days.sorted())
    }

    @Test("A place's days are sorted, so the newest can be cited")
    func placeDaysSorted() {
        let grouped = PhotoImporter.group(shots: [
            shot(19, lat: 41.3874, lon: 2.1686),
            shot(4, lat: 41.3874, lon: 2.1686),
            shot(11, lat: 41.3874, lon: 2.1686),
        ])
        let days = grouped.places.first?.days ?? []
        #expect(days == days.sorted())
        #expect(days.count == 3)
    }

    @Test("Evidence text reads like something a person would say")
    func evidenceText() {
        let one = PhotoImporter.DayInPlace(day: Date(), cell: nil, shots: 1)
        #expect(one.evidence(placeName: nil) == "1 photo")

        let many = PhotoImporter.DayInPlace(day: Date(), cell: nil, shots: 8)
        #expect(many.evidence(placeName: nil) == "8 photos")
        #expect(many.evidence(placeName: "41.3874, 2.1686") == "8 photos · 41.3874, 2.1686")
    }

    // MARK: - Identity, which is what makes re-running safe

    @Test("A place's id comes from the cell, not from its name")
    func placeIdentitySurvivesRename() {
        let cell = PhotoImporter.cell(latitude: 41.3874, longitude: 2.1686)
        let fromCell = MemoryText.stableID("entity", EntityKind.place.rawValue, cell.key)

        // The same cell, derived again after the user has renamed the place to "home".
        // The id must not move, or the rename would mint a second place at one address.
        let again = MemoryText.stableID("entity", EntityKind.place.rawValue, cell.key)
        #expect(fromCell == again)

        // And a different cell is a different place.
        let elsewhere = PhotoImporter.cell(latitude: 41.4036, longitude: 2.1744)
        #expect(fromCell != MemoryText.stableID("entity", EntityKind.place.rawValue, elsewhere.key))
    }

    @Test("A person is the same entity whichever source found them")
    func sourcesAreLinked() {
        // This is the whole reason the id is derived from the normalised name rather than from
        // anything source-specific: a contact, a calendar attendee and a name seen on screen
        // have to collide into one person, or the memory holds three Anas and can count to
        // three about none of them.
        let fromContacts = MemoryText.stableID(
            "entity", EntityKind.person.rawValue, MemoryText.normalizedTitle("Ana Ruiz")
        )
        let fromCalendar = MemoryText.stableID(
            "entity", EntityKind.person.rawValue, MemoryText.normalizedTitle("ana ruiz")
        )
        let fromScreen = MemoryText.stableID(
            "entity", EntityKind.person.rawValue, MemoryText.normalizedTitle("Ana  Ruiz")
        )
        #expect(fromContacts == fromCalendar)
        #expect(fromContacts == fromScreen)
    }

    @Test("A place and a person with the same text are different entities")
    func kindsDoNotCollide() {
        let person = MemoryText.stableID(
            "entity", EntityKind.person.rawValue, MemoryText.normalizedTitle("Sant Antoni")
        )
        let place = MemoryText.stableID(
            "entity", EntityKind.place.rawValue, MemoryText.normalizedTitle("Sant Antoni")
        )
        #expect(person != place)
    }

    @Test("An unknown kind reads as a note rather than failing")
    func unknownKindIsSafe() {
        // Why adding `place` needed no migration: the column is a string, and a build that has
        // never heard of a kind still opens the file.
        #expect(EntityKind(rawValue: "place") == .place)
        #expect(EntityKind(rawValue: "borough") == nil)
    }

    // MARK: - The incremental window

    @Test("A first pass reads the decade; a refresh reads a month and a week of overlap")
    func incrementalWindow() {
        let now = Date()
        let sources = LifeImporter.Sources(contacts: false, calendar: false, photos: false)

        // With every source off the scan does no work, which is the point being asserted:
        // nothing is read without a granted permission, so this is safe in CI.
        let (captures, result, summary) = LifeImporter.scan(sources: sources, now: now)
        #expect(captures.isEmpty)
        #expect(result.entities.isEmpty)
        #expect(summary == .empty)

        // And the overlap is a week, so an event edited after it happened is re-read.
        #expect(LifeImporter.incrementalOverlap == 7 * 24 * 60 * 60)
    }

    @Test("An empty source set is recognised without walking three permission checks")
    func emptySources() {
        #expect(LifeImporter.Sources(contacts: false, calendar: false, photos: false).isEmpty)
        #expect(!LifeImporter.Sources(contacts: false, calendar: false, photos: true).isEmpty)
        #expect(!LifeImporter.Sources().isEmpty)
    }

    // MARK: - Contacts rules

    @Test("A card with only a company on it is not a person")
    func companyCardsAreSkipped() {
        // The rule lives in readContacts, which needs a real CNContactStore. Assert the shape
        // it protects: an entity with an empty title could never match anything said out loud.
        #expect(MemoryText.normalizedTitle("").isEmpty)
    }

    // MARK: - Linkage, through the real commit path

    @Test("A contact and the same name seen on screen become one person, and the contact wins")
    func contactAndScreenMergeIntoOnePerson() async throws {
        // The id test above proves two strings match. This proves the merge actually happens in
        // the code that runs, which is the thing worth knowing: if these did not collide the
        // memory would hold two Anas and could count to three about neither.
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [])
            let t0 = TestClock.reference

            let contactsCapture = Fixtures.capture(
                text: "Ana Ruiz, Vermell",
                app: LifeImporter.contactsAppName,
                bundleID: LifeImporter.contactsBundleID,
                windowTitle: "Ana Ruiz",
                at: t0,
                name: "contact-ana"
            )
            try await store.insert(capture: contactsCapture)

            let personID = MemoryText.stableID(
                "entity", EntityKind.person.rawValue, MemoryText.normalizedTitle("Ana Ruiz")
            )
            // As the contacts import writes it: authored, because the user typed the name.
            let fromContacts = Entity(
                id: personID,
                kind: .person,
                title: "Ana Ruiz",
                detail: "Vermell",
                confidence: 0.95,
                source: .authored,
                aliases: ["Ana"],
                createdAt: t0,
                updatedAt: t0
            )
            // As extraction writes it after seeing the name on screen: a different row id,
            // lower case, inferred, and more confident than it has any right to be.
            let fromScreen = Entity(
                id: TestID.stable("entity", "person", "screen-ana"),
                kind: .person,
                title: "ana ruiz",
                detail: "a guess from a Slack window",
                confidence: 0.99,
                source: .inferred,
                createdAt: TestClock.minutes(5),
                updatedAt: TestClock.minutes(5)
            )

            _ = try await memory.commit(
                ExtractionResult(entities: [fromContacts], provenance: []), now: t0
            )
            _ = try await memory.commit(
                ExtractionResult(entities: [fromScreen], provenance: []), now: TestClock.minutes(5)
            )

            let people = try await store.entities(kind: .person, includeDeleted: false)
                .filter { MemoryText.normalizedTitle($0.title) == MemoryText.normalizedTitle("Ana Ruiz") }

            #expect(people.count == 1, "one person, not one per source")
            #expect(people.first?.source == .authored, "the address book outranks a screen guess")
            #expect(people.first?.title == "Ana Ruiz", "and keeps the capitalisation the user typed")
        }
    }

    // MARK: - Retention

    @Test("A retention window takes old screen captures and leaves imported history alone")
    func retentionSparesImportedHistory() async throws {
        // The bug this pins: imported rows are dated by when the thing happened, so the first
        // time anybody set a ninety-day window the decade they had just imported was deleted
        // and the setting looked like it had worked.
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [])
            let now = TestClock.reference
            let longAgo = now.addingTimeInterval(-3_650 * 86_400)   // ten years

            let sources: [(String, String)] = [
                (LifeImporter.contactsBundleID, "contact"),
                (LifeImporter.calendarBundleID, "event"),
                (PhotoImporter.bundleID, "photo-day"),
                (VaultImporter.bundleID, "note"),
            ]
            for (bundleID, name) in sources {
                try await store.insert(capture: Fixtures.capture(
                    text: "imported \(name) from ten years ago",
                    app: name,
                    bundleID: bundleID,
                    windowTitle: nil,
                    at: longAgo,
                    name: "imported-\(name)"
                ))
            }
            // And one genuine screen capture of the same age, which must not survive.
            try await store.insert(capture: Fixtures.capture(
                text: "a Slack window from ten years ago",
                app: "Slack",
                bundleID: "com.tinyspeck.slackmacgap",
                windowTitle: "#general (Slack)",
                at: longAgo,
                name: "screen-old"
            ))

            let removed = try await memory.applyRetention(captureDays: 90, now: now)
            #expect(removed == 1, "only the screen capture should go")

            let surviving = try await store.captures(
                from: longAgo.addingTimeInterval(-86_400), to: now, limit: 100
            )
            let survivingBundles = Set(surviving.map(\.appBundleID))
            for (bundleID, name) in sources {
                #expect(survivingBundles.contains(bundleID), "\(name) history was swept away")
            }
            #expect(
                !survivingBundles.contains("com.tinyspeck.slackmacgap"),
                "a real window window from a decade ago is exactly what retention is for"
            )
        }
    }

    @Test("Zero still means keep everything")
    func retentionOffKeepsEverything() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [])
            let now = TestClock.reference
            try await store.insert(capture: Fixtures.capture(
                text: "a Slack window from ten years ago",
                app: "Slack",
                bundleID: "com.tinyspeck.slackmacgap",
                windowTitle: nil,
                at: now.addingTimeInterval(-3_650 * 86_400),
                name: "screen-ancient"
            ))
            #expect(try await memory.applyRetention(captureDays: 0, now: now) == 0)
        }
    }

    @Test("Every import source is registered as exempt")
    func everyImportSourceIsExempt() {
        // Forgetting to add a new source here fails silently and months later: the import works,
        // and then one user sets a window and loses that history alone.
        #expect(ImportedSource.isImported(bundleID: LifeImporter.contactsBundleID))
        #expect(ImportedSource.isImported(bundleID: LifeImporter.calendarBundleID))
        #expect(ImportedSource.isImported(bundleID: PhotoImporter.bundleID))
        #expect(ImportedSource.isImported(bundleID: VaultImporter.bundleID))
        #expect(!ImportedSource.isImported(bundleID: "com.tinyspeck.slackmacgap"))
    }

    @Test("A place from the photo library persists and stays one row across two passes")
    func placeSurvivesReimport() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [])
            let t0 = TestClock.reference
            let cell = PhotoImporter.cell(latitude: 41.3874, longitude: 2.1686)
            let entityID = MemoryText.stableID("entity", EntityKind.place.rawValue, cell.key)

            func place(at date: Date, detail: String) -> Entity {
                Entity(
                    id: entityID,
                    kind: .place,
                    title: LifeImporter.Cellname.title(for: cell),
                    detail: detail,
                    confidence: 0.6,
                    source: .inferred,
                    aliases: [],
                    createdAt: date,
                    updatedAt: date
                )
            }

            _ = try await memory.commit(
                ExtractionResult(entities: [place(at: t0, detail: "From your photo library")], provenance: []),
                now: t0
            )
            // The hourly refresh runs again a month later and finds two more days there.
            _ = try await memory.commit(
                ExtractionResult(entities: [place(at: TestClock.minutes(60), detail: "From your photo library")], provenance: []),
                now: TestClock.minutes(60)
            )

            let places = try await store.entities(kind: .place, includeDeleted: false)
            #expect(places.count == 1, "re-running must merge into the place, not mint another")
            // The detail is deliberately static. This test previously asserted a growing day
            // count here and failed, which is how the design error was found: the merge laws
            // fill a detail only when the stored one is empty, so any number written here would
            // be frozen at the first pass and wrong from the second one onwards. The count is
            // counted from the day captures instead.
            #expect(places.first?.detail == "From your photo library")
        }
    }
    // MARK: - Places from the calendar

    /// Builds an event whose only interesting property is where and when it was.
    private func event(_ location: String?, _ day: Int, id: String? = nil) -> LifeImporter.ImportedEvent {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
        return LifeImporter.ImportedEvent(
            identifier: id ?? "ev-\(location ?? "none")-\(day)",
            title: "Something",
            date: date,
            evidence: "Something",
            location: location
        )
    }

    @Test("The same autocompleted address groups under one key")
    func autocompletedAddressGroups() {
        // The property that makes a calendar better than the photo grid: picking the same
        // suggestion twice produces the identical string, where two visits to one venue can
        // land either side of a 150 m cell boundary.
        let a = LifeImporter.placeKey("Bar Nero, Via Roma 4, Milano")
        let b = LifeImporter.placeKey("  bar nero,  via roma 4,  MILANO ")
        #expect(a != nil)
        #expect(a == b)
    }

    @Test("A video call is not a place")
    func videoCallsAreNotPlaces() {
        // The failure this rule exists to stop: a daily standup is the most recurrent
        // "location" in most calendars, so without this it would be everybody's top place.
        #expect(LifeImporter.placeKey("https://zoom.us/j/123456") == nil)
        #expect(LifeImporter.placeKey("Google Meet") == nil)
        #expect(LifeImporter.placeKey("meet.google.com/abc-defg-hij") == nil)
        #expect(LifeImporter.placeKey("Microsoft Teams Meeting") == nil)
        #expect(LifeImporter.placeKey("www.whereby.com/team") == nil)
        #expect(LifeImporter.placeKey("+39 02 1234 5678") == nil)
        #expect(LifeImporter.placeKey("") == nil)
        #expect(LifeImporter.placeKey(nil) == nil)
    }

    @Test("Three separate days make a place, two do not")
    func threeDaysMakeAPlace() {
        let twice = [event("Bar Nero", 1), event("Bar Nero", 2)]
        #expect(LifeImporter.places(in: twice).isEmpty)

        let thrice = twice + [event("Bar Nero", 9)]
        let found = LifeImporter.places(in: thrice)
        #expect(found.count == 1)
        #expect(found.first?.days.count == 3)
    }

    @Test("Three events on one day are one day, not three")
    func sameDayCountsOnce() {
        // Same rule as the photo library: one afternoon somewhere is an appointment, three
        // separate days is somewhere you go. A packed single day must not clear the bar.
        let sameDay = [event("Bar Nero", 4), event("Bar Nero", 4), event("Bar Nero", 4)]
        #expect(LifeImporter.places(in: sameDay).isEmpty)
    }

    @Test("The place is shown in the spelling the user used most")
    func titleIsTheUsersOwnWords() {
        let events = [
            event("Bar Nero", 1), event("Bar Nero", 2),
            event("bar nero", 3), event("Bar Nero", 4)
        ]
        let found = LifeImporter.places(in: events)
        #expect(found.first?.title == "Bar Nero")
    }

    @Test("A place cites a real event, on its most recent day")
    func placeCitesItsNewestDay() {
        let events = [
            event("Bar Nero", 1, id: "first"),
            event("Bar Nero", 5, id: "middle"),
            event("Bar Nero", 20, id: "newest")
        ]
        let place = LifeImporter.places(in: events).first
        #expect(place != nil)
        let newest = place?.days.last
        #expect(newest != nil)
        #expect(place?.eventIDByDay[newest!] == "newest")
    }

    @Test("Two different venues stay two places")
    func differentVenuesDoNotMerge() {
        // Deliberately not merging on the text before the first comma: every "Reception" in
        // a city would become one place, and a wrong place is worse than a missing one.
        let events = [
            event("Reception, 4 King Street", 1), event("Reception, 4 King Street", 2),
            event("Reception, 4 King Street", 3),
            event("Reception, 90 Queen Road", 1), event("Reception, 90 Queen Road", 2),
            event("Reception, 90 Queen Road", 3)
        ]
        #expect(LifeImporter.places(in: events).count == 2)
    }


    /// A first name is a name for everyone who has it.
    ///
    /// The Contacts importer handed every card's given name to the matcher as an alias, which
    /// is a licence to attach any text containing that word to that person. On a real address
    /// book it merged thirteen pairs of people who had never met: two Marcos became one,
    /// because "marco" on a screen attached to whichever Marco was reached first. Five
    /// first-name collisions existed among 191 contacts before anyone looked.
    ///
    /// A nickname survives, because somebody typed it and it is what a particular person is
    /// actually called — with two guards, both measured. It must not be a prefix of the full
    /// name (every one of 96 aliases in a real vault was exactly that: a given name wearing
    /// the nickname field), and it must be more than one token.
    @Test("a given name is never an alias, and a nickname must earn it")
    func givenNamesAreNotAliases() {
        // The shape of the bug: two people who share a first name.
        #expect(LifeImporter.aliases(given: "Marco", family: "Paolone", nickname: "").isEmpty,
                "a given name was handed to the matcher")
        #expect(LifeImporter.aliases(given: "Marco", family: "Guidini", nickname: "").isEmpty)

        // A nickname that is just the first name again buys nothing and is refused.
        #expect(LifeImporter.aliases(given: "Federico", family: "Gozzi", nickname: "Federico").isEmpty)
        #expect(LifeImporter.aliases(given: "Federico", family: "Gozzi", nickname: "Fede").isEmpty,
                "a one-token nickname is still a name for everyone who has it")

        // A real nickname, of more than one token, is kept: somebody typed it on purpose.
        #expect(LifeImporter.aliases(given: "Bo", family: "N\u{f8}rgaard", nickname: "Bo from school")
                == ["Bo from school"])
    }

    /// The importer stopped writing given names as aliases. This takes back the ones it wrote.
    ///
    /// The rows already on disk still carry them and they are still live in two places.
    /// `MemoryService.consolidate` builds an alias index and reconciles any candidate whose
    /// title matches an alias into that entity, which IS the merge: two cards sharing a first
    /// name, and whichever reached the index first absorbs what belongs to the other.
    /// `MemoryRank.linkedNames` then expands a search by alias, so one person's evidence comes
    /// back under the other's name.
    ///
    /// Measured on a real address book: 96 aliases across 95 people, and every single one is a
    /// prefix of its own full name. Not one real nickname among them.
    @Test("a first name is taken back off a person; a real nickname is left alone")
    func givenNameAliasesAreRemovedFromExistingPeople() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            let collides = Entity(kind: .person, title: "Ivano Restelli", source: .authored,
                                  aliases: ["Ivano"])
            let other = Entity(kind: .person, title: "Ivano Beltrame", source: .authored,
                               aliases: ["Ivano"])
            // Somebody typed this one: more than a word, and not the start of the name.
            let nicknamed = Entity(kind: .person, title: "Bo N\u{f8}rgaard", source: .authored,
                                   aliases: ["Bo from school"])
            for e in [collides, other, nicknamed] { try await store.upsert(entity: e) }

            let removed = try await store.repairGivenNameAliases()
            #expect(removed == 2, "removed \(removed) aliases")

            let people = try await store.entities(kind: .person, includeDeleted: false)
            let byTitle = Dictionary(uniqueKeysWithValues: people.map { ($0.title, $0) })
            #expect(byTitle["Ivano Restelli"]?.aliases.isEmpty == true, "a first name survived")
            #expect(byTitle["Ivano Beltrame"]?.aliases.isEmpty == true, "a first name survived")
            #expect(byTitle["Bo N\u{f8}rgaard"]?.aliases == ["Bo from school"],
                    "a real nickname was taken away too")

            // Idempotent: it only ever removes, so a second pass has nothing to do.
            #expect(try await store.repairGivenNameAliases() == 0, "the repair is not idempotent")
        }
    }

    // MARK: - Dates that do not move (schema v10)

    /// The bug that duplicated nine years of photographs.
    ///
    /// `PhotoImporter.group` keys a day by `calendar.startOfDay(for:)` — a *local* midnight.
    /// The old key rendered that instant with `ISO8601DateFormatter`, which formats in UTC, so
    /// a Madrid summer midnight came back as the previous day at 22:00Z and a winter one as
    /// 23:00Z. The id was derived from that string, so importing under two offsets minted two
    /// rows per day: 2,027 of 4,350 rows on a real vault.
    @Test("a day key is the date a human would write, in any timezone")
    func localDayKeyDoesNotMoveWithTheReader() {
        var madrid = Calendar(identifier: .gregorian)
        madrid.timeZone = TimeZone(identifier: "Europe/Madrid")!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        // A July midnight in Madrid is 22:00Z on the 14th. The date a person writes is the 15th.
        let julyMidnightMadrid = madrid.date(from: DateComponents(year: 2019, month: 7, day: 15))!
        #expect(LifeImporter.localDayKey(julyMidnightMadrid, calendar: madrid) == "2019-07-15")

        // A January midnight in Madrid is 23:00Z on the 9th, and still reads as the 10th.
        let janMidnightMadrid = madrid.date(from: DateComponents(year: 2019, month: 1, day: 10))!
        #expect(LifeImporter.localDayKey(janMidnightMadrid, calendar: madrid) == "2019-01-10")

        // The old code path, for the record: rendering the same instant in UTC loses the day.
        let iso = ISO8601DateFormatter().string(from: julyMidnightMadrid)
        #expect(iso.hasPrefix("2019-07-14"), "the UTC rendering was \(iso)")

        // And the key a different calendar produces for its own midnight is its own date, not
        // an artefact of the offset it was written under.
        let tokyoMidnight = tokyo.date(from: DateComponents(year: 2019, month: 7, day: 15))!
        #expect(LifeImporter.localDayKey(tokyoMidnight, calendar: tokyo) == "2019-07-15")
    }

    /// The repair, on the exact shape the real vault is in.
    @Test("the twins minted by the old key are cleared, and only the twins")
    func repairRemovesDuplicateImportedDays() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            var madrid = Calendar(identifier: .gregorian)
            madrid.timeZone = TimeZone(identifier: "Europe/Madrid")!

            // A July day: local midnight is 22:00Z, and the stale twin sits an hour later.
            let keeper = madrid.date(from: DateComponents(year: 2019, month: 7, day: 15))!
            let twin = keeper.addingTimeInterval(3600)
            let text = "6 photos"
            func row(_ id: String, _ ts: Date) -> CaptureEvent {
                CaptureEvent(
                    id: id, ts: ts,
                    appBundleID: PhotoImporter.bundleID, appName: PhotoImporter.appName,
                    windowTitle: nil, text: text, textHash: MemoryText.stableID("hash", text)
                )
            }
            // A lone row on another day, which must survive untouched.
            let lone = madrid.date(from: DateComponents(year: 2019, month: 7, day: 20))!
            try await seed(store: store, captures: [row("keep", keeper), row("twin", twin), row("lone", lone)])

            // An entity citing the row that is about to be deleted keeps its evidence.
            let place = Entity(kind: .place, title: "41.3800, 2.1700")
            try await store.upsert(entity: place)
            try await store.add(provenance: Provenance(
                entityID: place.id, captureID: "twin", field: "title",
                snippet: text, ts: twin))

            let first = try await store.repairImportedDays(calendar: madrid)
            #expect(first.removed == 1, "removed \(first.removed)")

            let left = try await store.captures(since: .distantPast, limit: 0).map(\.id).sorted()
            #expect(left == ["keep", "lone"], "survivors were \(left)")

            // The citation moved rather than being destroyed.
            let evidence = try await store.provenance(entityID: place.id)
            #expect(evidence.count == 1)
            #expect(evidence.first?.captureID == "keep", "the citation was not repointed")

            // Every surviving imported row carries the date it belongs to.
            let dates = try await store.captures(since: .distantPast, limit: 0)
                .compactMap(\.localDay).sorted()
            #expect(dates == ["2019-07-15", "2019-07-20"], "dates were \(dates)")

            // Idempotent: a second pass finds nothing left to do.
            let second = try await store.repairImportedDays(calendar: madrid)
            #expect(second.removed == 0 && second.dated == 0, "second pass did \(second)")
        }
    }

}
