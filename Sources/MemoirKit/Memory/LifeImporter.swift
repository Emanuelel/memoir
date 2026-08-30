import Contacts
import EventKit
import Foundation

/// Reads Contacts, Calendar and the photo library, so the memory reaches back years on the day
/// it is installed instead of starting empty, and keeps reaching forward afterwards.
///
/// ## Why this exists
///
/// Capture can only ever know about today onwards. A product whose whole claim is that you can
/// ask your life a question cannot open on an empty page and ask the user to come back in three
/// years. The vault importer solves half of cold start (it learns your *vocabulary*, the names
/// of your projects) and none of the other half, which is *history*.
///
/// Contacts and Calendar are the two places a decade of a real life is already sitting on the
/// machine, in structured form, with no parsing risk and no third-party anything.
///
/// ## What each one is for
///
/// - **Contacts → people.** Names you typed yourself, so they are `authored` and outrank
///   anything extraction later guesses about the same person.
/// - **Calendar → dated evidence.** Every event becomes a capture row on the day it happened,
///   carrying its title and who was there. That is what makes *"you have not spoken to Ana
///   since March"* answerable at all.
/// - **Photos → places, and dated evidence of being in them.** Dates and coordinates only, never
///   an image. See `PhotoImporter` for what the platform does and does not allow here.
///
/// ## It runs again, and that is the point
///
/// This used to be a one-shot pass from the setup window, which meant a contact added the
/// following week never arrived and the calendar half of the memory stopped on install day,
/// the opposite of the intent. `scan(sources:since:)` now takes a lower bound so the periodic
/// pass costs a short window instead of a decade, and every id in here is derived with
/// `MemoryText.stableID`, so re-running merges into what is already there rather than
/// duplicating it.
///
/// ## Deliberately conservative
///
/// Event titles do **not** become entities. Meeting titles are noisy, and an alias is a licence
/// to attach on-screen text to something, the same reasoning `VaultImporter` applies to note
/// names. Events are evidence; only people become entities here.
///
/// Read-only against both stores, always. Nothing is written to the address book or the
/// calendar, ever, in either direction.
public enum LifeImporter {

    /// The pseudo-apps these rows are recorded under, so provenance reads honestly:
    /// an answer sourced from here says "Contacts" or "Calendar", never "your screen".
    public static let contactsBundleID = "sh.memoir.contacts"
    public static let contactsAppName = "Contacts"
    public static let calendarBundleID = "sh.memoir.calendar"
    public static let calendarAppName = "Calendar"

    /// How far back to read. Ten years is the promise the product makes; beyond that the
    /// calendar is usually empty anyway.
    public static let yearsBack = 10

    /// Ceiling on imported events. A calendar with a decade of fifteen-minute standups in it
    /// would otherwise drown the first day's memory in noise.
    static let maxEvents = 20_000

    /// What one pass produced. Shown to the user verbatim, so the numbers have to mean
    /// something a person recognises.
    public struct Summary: Sendable, Equatable {
        public let peopleImported: Int
        public let eventsImported: Int
        /// Days that had photographs in them. Not a photo count: the row is a day.
        public let photoDaysImported: Int
        /// Cells that cleared `PhotoImporter.minimumDaysForPlace`, so somewhere the user
        /// actually returns to rather than somewhere they once stood.
        public let placesFound: Int
        /// The oldest dated thing actually found, across every source, which is the honest
        /// version of "how far back your memory now reaches".
        public let reachesBackTo: Date?

        public init(
            peopleImported: Int,
            eventsImported: Int,
            photoDaysImported: Int = 0,
            placesFound: Int = 0,
            reachesBackTo: Date?
        ) {
            self.peopleImported = peopleImported
            self.eventsImported = eventsImported
            self.photoDaysImported = photoDaysImported
            self.placesFound = placesFound
            self.reachesBackTo = reachesBackTo
        }

        public static let empty = Summary(
            peopleImported: 0, eventsImported: 0, photoDaysImported: 0, placesFound: 0,
            reachesBackTo: nil
        )
    }

    /// Which sources the user agreed to. Each is a separate decision and a separate prompt;
    /// declining one must never block the other.
    public struct Sources: Sendable, Equatable {
        public var contacts: Bool
        public var calendar: Bool
        public var photos: Bool
        public init(contacts: Bool = true, calendar: Bool = true, photos: Bool = true) {
            self.contacts = contacts
            self.calendar = calendar
            self.photos = photos
        }

        /// True when there is nothing to do, so a caller can skip the pass entirely rather
        /// than walk three permission checks to reach the same answer.
        public var isEmpty: Bool { !contacts && !calendar && !photos }
    }

    // MARK: - Permission

    /// One of the three archives, named, with the switch that governs it.
    ///
    /// Exists because a refusal has to be *actionable*. macOS records a "no" and then stops
    /// prompting, so `requestContactsAccess()` and friends return false without showing
    /// anything and the button looks broken. The only way back is the System Settings pane,
    /// and telling a user which pane to go and find is not the same as opening it for them.
    public enum Source: String, CaseIterable, Sendable, Identifiable {
        case contacts, calendar, photos

        public var id: String { rawValue }

        /// What the switch is called in System Settings, so the sentence and the pane agree.
        public var label: String {
            switch self {
            case .contacts: return "Contacts"
            case .calendar: return "Calendars"
            case .photos: return "Photos"
            }
        }

        /// What Memoir loses while this one is off. Said in what it costs the user, not in
        /// what the importer failed to read.
        public var whatItCosts: String {
            switch self {
            case .contacts: return "the names of the people in your life"
            case .calendar: return "ten years of what you were doing and who was there"
            case .photos: return "the places you keep going back to"
            }
        }

        /// The `x-apple.systempreferences:` pane holding this switch.
        public var settingsPane: String {
            switch self {
            case .contacts: return "com.apple.preference.security?Privacy_Contacts"
            case .calendar: return "com.apple.preference.security?Privacy_Calendars"
            case .photos: return "com.apple.preference.security?Privacy_Photos"
            }
        }

        /// Whether the machine will hand this over right now. Never prompts.
        public var isGranted: Bool {
            switch self {
            case .contacts: return CNContactStore.authorizationStatus(for: .contacts) == .authorized
            case .calendar: return EKEventStore.authorizationStatus(for: .event) == .fullAccess
            case .photos: return PhotoImporter.isAuthorized
            }
        }

        /// Opens the one pane this source lives in.
        @MainActor public func openSettings() {
            Permissions.openPrivacyPane(settingsPane)
        }
    }

    /// The sources macOS is currently withholding. Empty is the healthy state.
    public static var withheld: [Source] {
        Source.allCases.filter { !$0.isGranted }
    }

    /// Granted, but not fully: macOS is handing over a slice and calling it access.
    ///
    /// Only Photos can be in this state: its "Limited Access" level passes every ordinary
    /// permission check and then returns the handful of images the user picked. Contacts and
    /// Calendar have no equivalent, so this is a one-element list or an empty one.
    public static var partial: [Source] {
        PhotoImporter.access == .limited ? [.photos] : []
    }

    /// Asks for Contacts, once. Returns false when the user says no, which is a normal
    /// answer, not an error, and must leave the rest of setup working.
    public static func requestContactsAccess() async -> Bool {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { return true }
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Asks for Calendar, once. Same contract as ``requestContactsAccess()``.
    public static func requestCalendarAccess() async -> Bool {
        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Asks for the photo library, once. Same contract again. See `PhotoImporter` for why the
    /// system prompt asks for more than this ever reads.
    public static func requestPhotosAccess() async -> Bool {
        await PhotoImporter.requestAccess()
    }

    /// Which sources the machine will actually give us right now, without asking for anything.
    ///
    /// Used by the periodic pass: it must never trigger a permission prompt out of nowhere,
    /// hours after setup, with no user action to explain it.
    public static var granted: Sources {
        Sources(
            contacts: CNContactStore.authorizationStatus(for: .contacts) == .authorized,
            calendar: EKEventStore.authorizationStatus(for: .event) == .fullAccess,
            photos: PhotoImporter.isAuthorized
        )
    }

    // MARK: - Reading

    /// How far back an incremental pass re-reads past its lower bound.
    ///
    /// An event moved or retitled after the fact keeps its identifier, so re-reading a week of
    /// overlap picks the edit up and `INSERT OR REPLACE` corrects the row. Without the overlap
    /// the memory would keep the version it saw first and never learn it had changed.
    static let incrementalOverlap: TimeInterval = 7 * 24 * 60 * 60

    /// Reads the granted stores and returns rows ready for the same commit path the vault uses.
    ///
    /// Never throws on a refused permission: a source the user declined simply contributes
    /// nothing. The only failures that surface are ones the user can act on.
    ///
    /// - Parameter since: Lower bound for the dated sources. Nil means the full ``yearsBack``
    ///   decade, which is what the first run wants. A date means the periodic pass, which
    ///   re-reads from there minus ``incrementalOverlap``. Contacts are read in full either
    ///   way: an address book carries no dates to filter on, and reading it is cheap.
    public static func scan(
        sources: Sources,
        since: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (captures: [CaptureEvent], result: ExtractionResult, summary: Summary) {

        var captures: [CaptureEvent] = []
        var entities: [Entity] = []
        var provenance: [Provenance] = []
        var people = 0
        var events = 0
        var photoDays = 0
        var places = 0
        var oldest: Date?

        /// Where the dated sources start reading from.
        let datedStart: Date = {
            guard let since else {
                return calendar.date(byAdding: .year, value: -yearsBack, to: now) ?? now
            }
            return since.addingTimeInterval(-incrementalOverlap)
        }()

        // ---- Contacts: the names, as people ----
        if sources.contacts, CNContactStore.authorizationStatus(for: .contacts) == .authorized {
            for contact in readContacts() {
                let name = contact.name
                let captureID = MemoryText.stableID("lifecap", contactsBundleID, contact.identifier)
                let text = contact.evidence
                captures.append(CaptureEvent(
                    id: captureID,
                    ts: now,
                    appBundleID: contactsBundleID,
                    appName: contactsAppName,
                    windowTitle: name,
                    text: text,
                    textHash: MemoryText.stableID("hash", text)
                ))

                // Same identity derivation as every other source, so a contact and an
                // on-screen sighting of the same person collide into one entity.
                let entityID = MemoryText.stableID(
                    "entity", EntityKind.person.rawValue, MemoryText.normalizedTitle(name)
                )
                entities.append(Entity(
                    id: entityID,
                    kind: .person,
                    title: name,
                    detail: contact.organisation,
                    dueAt: nil,
                    confidence: 0.95,
                    source: .authored,
                    aliases: contact.aliases,
                    createdAt: now,
                    updatedAt: now
                ))
                provenance.append(Provenance(
                    id: MemoryText.stableID("prov", entityID, captureID, "title", name),
                    entityID: entityID,
                    captureID: captureID,
                    field: "title",
                    snippet: MemoryText.truncate(contact.evidence, max: 240),
                    ts: now
                ))
                people += 1
            }
        }

        // ---- Calendar: the years, as dated evidence ----
        if sources.calendar, EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let read = readEvents(from: datedStart, to: now)
            var captureIDForEvent: [String: ID] = [:]
            for event in read {
                let captureID = MemoryText.stableID("lifecap", calendarBundleID, event.identifier)
                captures.append(CaptureEvent(
                    id: captureID,
                    ts: event.date,
                    appBundleID: calendarBundleID,
                    appName: calendarAppName,
                    windowTitle: event.title,
                    text: event.evidence,
                    textHash: MemoryText.stableID("hash", event.evidence)
                ))
                captureIDForEvent[event.identifier] = captureID
                if oldest == nil || event.date < oldest! { oldest = event.date }
                events += 1
            }

            // Somewhere you said you were going, three separate times. Named in your own words,
            // which is the whole advantage over a coordinate: nothing to geocode, and nothing
            // for the user to rename before the sentence can be said out loud.
            // `Self.` because `places` is also the local counter in this function: the
            // shadowing is real and the compiler catches it, but naming it explicitly is
            // clearer than renaming either one.
            for place in Self.places(in: read, calendar: calendar) {
                let entityID = MemoryText.stableID(
                    "entity", EntityKind.place.rawValue, "calendar", place.key
                )
                entities.append(Entity(
                    id: entityID,
                    kind: .place,
                    title: place.title,
                    // Same reasoning as the photo places: no count here. A detail is filled
                    // only when empty, so a number written now would freeze and go stale.
                    detail: "From your calendar",
                    dueAt: nil,
                    confidence: 0.6,
                    // Inferred: the recurrence is Memoir's observation. The *name* is the
                    // user's, which is why it may be shown as written rather than as a number.
                    source: .inferred,
                    aliases: [],
                    createdAt: now,
                    updatedAt: now
                ))

                if let newest = place.days.last,
                   let eventID = place.eventIDByDay[newest],
                   let captureID = captureIDForEvent[eventID],
                   let row = captures.last(where: { $0.id == captureID }) {
                    provenance.append(Provenance(
                        id: MemoryText.stableID("prov", entityID, captureID, "title", place.title),
                        entityID: entityID,
                        captureID: captureID,
                        field: "title",
                        snippet: MemoryText.truncate(row.text, max: 240),
                        ts: now
                    ))
                }
                places += 1
            }
        }

        // ---- Photos: the places, and the days spent in them ----
        //
        // Dates and coordinates, one row per day per place. `PhotoImporter` explains why a grid
        // and not real clustering, and why faces and place names are not available at all.
        if sources.photos, PhotoImporter.isAuthorized {
            let shots = PhotoImporter.readShots(from: datedStart, to: now)
            let grouped = PhotoImporter.group(shots: shots, calendar: calendar)

            // Day rows first, keeping the id of each so a place can cite one of its own days.
            var captureIDForDay: [String: ID] = [:]
            for day in grouped.days {
                let dayKey = Self.localDayKey(day.day, calendar: calendar)
                let rowKey = "\(dayKey)|\(day.cell?.key ?? "-")"
                let captureID = MemoryText.stableID("lifecap", PhotoImporter.bundleID, rowKey)
                let name = day.cell.map { Cellname.title(for: $0) }
                let text = day.evidence(placeName: name)

                captures.append(CaptureEvent(
                    id: captureID,
                    ts: day.day,
                    appBundleID: PhotoImporter.bundleID,
                    appName: PhotoImporter.appName,
                    windowTitle: name,
                    text: text,
                    textHash: MemoryText.stableID("hash", text),
                    localDay: dayKey
                ))
                captureIDForDay[rowKey] = captureID
                if oldest == nil || day.day < oldest! { oldest = day.day }
                photoDays += 1
            }

            // Then the places themselves, cited to their most recent day.
            for place in grouped.places {
                // Keyed on the grid cell, never on the title: the user is expected to rename
                // these, and a rename must not mint a second place at the same coordinates.
                let entityID = MemoryText.stableID(
                    "entity", EntityKind.place.rawValue, place.cell.key
                )
                let title = Cellname.title(for: place.cell)

                entities.append(Entity(
                    id: entityID,
                    kind: .place,
                    title: title,
                    // Deliberately not "5 days with photographs". The merge laws fill a detail
                    // only when the stored one is empty (correctly, since a detail is not
                    // something to rewrite behind the user's back), so a count put here would
                    // freeze at whatever the first pass saw and then be wrong forever. The
                    // number belongs to the day captures, which is where it can be counted and
                    // cited at the moment someone asks.
                    detail: "From your photo library",
                    dueAt: nil,
                    confidence: 0.6,
                    // Inferred, not authored: nobody typed this. A coordinate is what the
                    // machine worked out, and the user renaming it outranks this row.
                    source: .inferred,
                    aliases: [],
                    createdAt: now,
                    updatedAt: now
                ))

                // Cited to the most recent day spent there. A snippet has to be a quote of the
                // capture it points at, never a summary of several, so it is that day's own
                // text, not a sentence about the place.
                if let newest = place.days.last {
                    let rowKey = "\(Self.localDayKey(newest, calendar: calendar))|\(place.cell.key)"
                    if let captureID = captureIDForDay[rowKey],
                       let row = captures.last(where: { $0.id == captureID }) {
                        provenance.append(Provenance(
                            id: MemoryText.stableID("prov", entityID, captureID, "title", title),
                            entityID: entityID,
                            captureID: captureID,
                            field: "title",
                            snippet: MemoryText.truncate(row.text, max: 240),
                            ts: now
                        ))
                    }
                }
                places += 1
            }
        }

        return (
            captures,
            ExtractionResult(entities: entities, provenance: provenance),
            Summary(
                peopleImported: people,
                eventsImported: events,
                photoDaysImported: photoDays,
                placesFound: places,
                reachesBackTo: oldest
            )
        )
    }

    /// How a grid cell is shown to a person.
    ///
    /// Its own type so there is one place to change when place naming improves: matching a cell
    /// against calendar event locations on the same day is the obvious next step, and it would
    /// land here rather than being threaded through the scan.
    enum Cellname {
        static func title(for cell: PhotoImporter.Cell) -> String {
            String(format: "%.4f, %.4f", cell.latitude, cell.longitude)
        }
    }

    // MARK: - Contacts

    struct ImportedContact {
        let identifier: String
        let name: String
        let organisation: String?
        let aliases: [String]
        let evidence: String
    }

    /// Everyone in the address book who has a usable name.
    ///
    /// Names, nickname and organisation only. Not phone numbers, not addresses, not email,
    /// not birthdays, not photographs, none of which the memory has any use for, and all of
    /// which would be a much larger thing to have taken.
    static func readContacts() -> [ImportedContact] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var out: [ImportedContact] = []

        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            let given = contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
            let family = contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let nickname = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            let organisation = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)

            let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
            // A card with only a company on it is a company, not a person. Skip it rather
            // than mint a person entity that will never match anything a human says.
            guard !full.isEmpty else { return }

            // Aliases are a licence to attach text to this person, and a given name is the
            // wrong thing to hand that licence to.
            //
            // A first name is not a name for a person, it is a name for everyone who has it.
            // On a real address book this merged thirteen pairs of people who had never met:
            // two Marcos became one, and one Federico absorbed two unrelated Federicos, because
            // "marco" on a screen attached to whichever Marco the matcher reached first. Five
            // first-name collisions existed in 191 contacts before anyone looked.
            //
            // A nickname is different and stays: somebody typed it, it is what that person is
            // actually called, and it is not a category. Two guards on it. It must not be a
            // prefix of the full name — measured, every one of 96 aliases in a real vault was
            // exactly that, a given name wearing the nickname field — and it must be more than
            // one token, for the same reason the given name is now refused.
            let aliases = Self.aliases(given: given, family: family, nickname: nickname)

            out.append(ImportedContact(
                identifier: contact.identifier,
                name: full,
                organisation: organisation.isEmpty ? nil : organisation,
                aliases: aliases,
                evidence: organisation.isEmpty ? full : "\(full), \(organisation)"
            ))
        }
        return out
    }

    // MARK: - Calendar

    struct ImportedEvent {
        let identifier: String
        let title: String
        let date: Date
        let evidence: String
        /// The raw location string, kept apart from `evidence` so it can be counted.
        let location: String?
    }

    /// Events in a window, oldest first, capped.
    ///
    /// EventKit refuses spans longer than four years in a single predicate, so the window is
    /// walked a year at a time. Without this the decade query silently returns nothing, which
    /// would look exactly like an empty calendar.
    static func readEvents(from start: Date, to end: Date) -> [ImportedEvent] {
        let store = EKEventStore()
        let calendar = Calendar.current
        var out: [ImportedEvent] = []
        var windowStart = start

        // Named because "54 events in ten years" has two very different causes: a calendar
        // that is genuinely that empty, or a Google account the user lives in that was never
        // added to the Mac's Calendar app, so EventKit cannot see it at all. The second is by
        // far the more likely and Memoir had no way to say which it was looking at.
        let visible = store.calendars(for: .event)
        if visible.isEmpty {
            Log.shared.info(
                "calendar scan: EventKit reports no calendars. A Google or Exchange account "
                + "is only readable once it is added in System Settings > Internet Accounts."
            )
        } else {
            let described = visible
                .map { "\($0.title) [\($0.source.title)]" }
                .sorted()
                .joined(separator: ", ")
            Log.shared.info("calendar scan: \(visible.count) calendars (\(described))")
        }

        while windowStart < end, out.count < maxEvents {
            let windowEnd = min(
                calendar.date(byAdding: .year, value: 1, to: windowStart) ?? end,
                end
            )
            let predicate = store.predicateForEvents(
                withStart: windowStart, end: windowEnd, calendars: nil
            )
            for event in store.events(matching: predicate) {
                guard out.count < maxEvents else { break }
                let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let date = event.startDate else { continue }
                out.append(ImportedEvent(
                    identifier: event.eventIdentifier ?? MemoryText.stableID("ev", title, "\(date.timeIntervalSince1970)"),
                    title: title,
                    date: date,
                    evidence: evidence(for: event, title: title),
                    location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
            windowStart = windowEnd
        }
        return out
    }

    // MARK: - Places, from where you said you were going

    /// A place the user keeps going to, named the way they named it.
    ///
    /// The photo library was the only source of places, and it can only be one where the
    /// camera recorded a coordinate. Measured on one real library: 113 of 14,683 photographs,
    /// which is 0.8%, and one place out of nine years. With Location Services off for the
    /// camera it is zero, and that is a setting Memoir cannot see, ask about, or influence.
    ///
    /// A calendar location is better than a coordinate on every axis that matters here. It is
    /// already a name, so nothing has to be geocoded and no network call is needed to say it
    /// out loud. It is a name the *user* typed or picked, which is the rule that governs
    /// topics too. And it survives the failure that broke the grid: two visits to the same
    /// venue near a cell boundary land in different cells, whereas an autocompleted address
    /// is byte-identical every time it is chosen.
    struct CalendarPlace {
        /// Normalised, and what the entity id is derived from.
        let key: String
        /// The spelling to show: the most frequent raw form, so the user reads their own words.
        let title: String
        /// Distinct days, oldest first.
        let days: [Date]
        /// The event each day came from, for citation.
        let eventIDByDay: [Date: String]
    }

    /// Strings that name a video call rather than a place.
    ///
    /// A recurring standup is not somewhere you go, and "Google Meet" appearing on 200 days
    /// would be the single strongest "place" in most people's calendars: top of the list,
    /// wrong in a way that discredits everything under it.
    static let virtualLocationMarkers = [
        "zoom.us", "meet.google", "teams.microsoft", "teams.live", "webex", "whereby.com",
        "skype", "hangout", "gotomeeting", "bluejeans", "chime.aws",
        "google meet", "microsoft teams", "phone call", "conference call", "dial-in", "dial in"
    ]

    /// The key a location string groups under, or nil when it does not name a place at all.
    ///
    /// Case, surrounding whitespace and repeated spaces are the only things normalised away.
    /// Nothing is inferred about what part of the string is the venue and what part is the
    /// address: taking the text before the first comma would merge every "Reception" in the
    /// city, and a wrong place is worse than a missing one.
    static func placeKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        // A link is a room on the internet, not a room.
        if lowered.contains("://") || lowered.hasPrefix("www.") { return nil }
        if virtualLocationMarkers.contains(where: { lowered.contains($0) }) { return nil }
        // A bare dial-in string is digits and punctuation, and names nowhere.
        if lowered.rangeOfCharacter(from: CharacterSet.letters) == nil { return nil }

        let collapsed = lowered
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let key = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:-–\u{2014}/ "))
        return key.isEmpty ? nil : key
    }

    /// Which locations in these events are places somebody actually goes.
    ///
    /// Pure, so the rule is testable without a calendar. Same bar as the photo library
    /// (``PhotoImporter/minimumDaysForPlace`` distinct days), referenced rather than repeated so
    /// the two definitions of "a place" cannot drift into disagreeing with each other.
    static func places(in events: [ImportedEvent], calendar: Calendar = .current) -> [CalendarPlace] {
        var daysByKey: [String: Set<Date>] = [:]
        var spellings: [String: [String: Int]] = [:]
        var eventByKeyDay: [String: [Date: String]] = [:]

        for event in events {
            guard let key = placeKey(event.location), let raw = event.location else { continue }
            let day = calendar.startOfDay(for: event.date)
            daysByKey[key, default: []].insert(day)
            spellings[key, default: [:]][raw.trimmingCharacters(in: .whitespacesAndNewlines), default: 0] += 1
            // First event of that day wins, so the citation is stable across re-imports.
            if eventByKeyDay[key]?[day] == nil {
                eventByKeyDay[key, default: [:]][day] = event.identifier
            }
        }

        return daysByKey
            .filter { $0.value.count >= PhotoImporter.minimumDaysForPlace }
            .map { key, days in
                // Most frequent spelling, ties broken alphabetically so a re-import cannot
                // silently rename a place the user has been looking at.
                let title = (spellings[key] ?? [:])
                    .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                    .first?.key ?? key
                return CalendarPlace(
                    key: key,
                    title: title,
                    days: days.sorted(),
                    eventIDByDay: eventByKeyDay[key] ?? [:]
                )
            }
            .sorted { ($0.days.count, $1.key) > ($1.days.count, $0.key) }
    }

    /// What an event contributes as text: what it was, where, and who was there.
    ///
    /// Attendee names are the point: they are what lets a person entity pick up a dated
    /// sighting from four years ago. Notes and URLs are left out: a calendar note is often
    /// a dial-in code or a password, and none of it is worth the risk of storing.
    static func evidence(for event: EKEvent, title: String) -> String {
        var parts = [title]
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
           !location.isEmpty {
            parts.append("at \(location)")
        }
        let names = (event.attendees ?? [])
            .compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !names.isEmpty {
            parts.append("with \(names.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Dates that do not move

    /// The calendar date of an instant, in the calendar that produced it, as `yyyy-MM-dd`.
    ///
    /// This replaced `ISO8601DateFormatter().string(from:)`, and the difference is the whole
    /// bug. `PhotoImporter.group` keys a day by `calendar.startOfDay(for:)`, which is a *local*
    /// midnight — 22:00Z in a UTC+2 summer, 23:00Z in a UTC+1 winter. Rendering that instant
    /// through an ISO formatter, which defaults to UTC, gave back the day before with a time on
    /// it, and the string changed the moment the machine's offset did.
    ///
    /// The id was derived from that string, so a library imported under two offsets minted two
    /// rows per day. On the developer's own vault 2,027 of 4,350 photo rows were exact
    /// duplicates an hour apart, and the visible symptom was a memory that had lived through
    /// each of nine years twice.
    ///
    /// Formatting the components in the same calendar makes the key what it always meant: the
    /// date a human would write on that day. `Store.repairImportedDays` clears the rows the old
    /// key created.
    public static func localDayKey(_ instant: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: instant)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }


    /// The alternate names a contact card may lend the matcher. See the reasoning above the
    /// call site; separated out so the rule can be tested without a Contacts store.
    static func aliases(given: String, family: String, nickname: String) -> [String] {
        let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty, nick != full else { return [] }
        guard !MemoryText.normalizedTitle(full)
            .hasPrefix(MemoryText.normalizedTitle(nick)) else { return [] }
        guard nick.split(whereSeparator: \.isWhitespace).count > 1 else { return [] }
        return [nick]
    }

}
