import Foundation

/// The day's own material, laid out beside the composer as something to write *about*.
///
/// ## Why this exists
///
/// `JournalPrompt` describes the day in one sentence, built from the longest stretch of work.
/// That is one fact out of a day that already has several sitting in the memory: the meetings
/// that happened, the photographs taken and roughly where, the thing the hours went on. The
/// composer was showing a summary of a day it could have shown.
///
/// The difference is between telling and showing. A sentence about your day is Memoir's
/// account of it; a row of the day's own pieces is yours, and picking one is a stronger
/// invitation to write than any sentence: it puts the first line on the page for you.
///
/// ## Where the material comes from
///
/// Entirely from rows already in the store. `LifeImporter` writes calendar events and photo
/// day-rows as captures under their own pseudo-apps, and `WorkSpanBuilder` derives the hours.
/// Nothing here reads a store, a library or a network; it is handed rows and returns tiles,
/// which is what makes every rule below testable.
///
/// ## What it deliberately does not do
///
/// - **No thumbnails.** `PhotoImporter` reads dates and coordinates and never asks PhotoKit
///   for image data of any size: the absence of that call is the proof of the promise. A
///   photo tile therefore says *"6 photos · Cala Piccola"* and shows no picture.
/// - **No interpretation.** A tile states what happened and stops. The moment it says *"a
///   busy day"* or *"you seemed happier"*, a journal becomes a wellness app telling somebody
///   how their own life went.
/// - **No counting of days.** Nothing here knows or says whether anything was written
///   yesterday, for the reason `JournalPrompt` gives at length.
public struct DayContext: Sendable, Equatable {

    /// Whether the weather is there, and if not, which of the two switches is in the way.
    ///
    /// Modelled rather than left as an optional because the difference matters to the user: a
    /// switch they have never seen and a permission macOS is withholding need different words
    /// and lead to different places.
    public enum WeatherState: Sendable, Equatable {
        /// `allowWeather` is off, which is the default and the common case.
        case off
        /// Turned on, but macOS will not say where this Mac is.
        case needsLocation
        /// Turned on, permitted, and no answer came back, or nobody asked.
        case unavailable
        case known(Weather.Day)
    }

    /// One thing that happened, and the line it puts on the page.
    public struct Item: Sendable, Equatable, Identifiable {

        /// A switch standing between this tile and the thing it would show.
        ///
        /// A tile carrying one of these does not write a line when picked. It takes the user
        /// to the switch instead, which is the only reason it is on screen at all.
        public enum Need: String, Sendable, Equatable {
            /// Memoir's own weather switch, in Settings.
            case weatherSwitch
            /// macOS Location Services, in System Settings.
            case locationPermission

            /// The link, as it reads on the tile. Short, lower case, and a verb: it is a
            /// control, not an announcement.
            public var invitation: String {
                switch self {
                case .weatherSwitch: return "Turn on"
                case .locationPermission: return "Allow location"
                }
            }

            /// What turning it on costs, said plainly under the link. The switch is off by
            /// default because of this sentence, so the sentence has to be on screen with it.
            public var cost: String {
                switch self {
                case .weatherSwitch:
                    return "Asks open-meteo.com, with your location rounded to about 11 km. "
                        + "Nothing else leaves."
                case .locationPermission:
                    return "Memoir asks macOS for an approximate location, and keeps none of it."
                }
            }
        }

        /// What kind of thing this was. Chooses the icon and the small label above the title,
        /// and nothing else. Provenance is the point: a tile from the calendar has to look
        /// like it came from the calendar.
        public enum Kind: String, Sendable, Equatable {
            case photos, event, weather, work

            /// The word above the title. Names the *source*, so an item is always traceable
            /// back to where Memoir got it.
            public var label: String {
                switch self {
                case .photos: return "Photos"
                case .event: return "Calendar"
                case .weather: return "Weather"
                case .work: return "Longest"
                }
            }

            /// SF Symbol for the tile.
            public var symbol: String {
                switch self {
                case .photos: return "photo.on.rectangle"
                case .event: return "calendar"
                case .weather: return "cloud.sun"
                case .work: return "clock"
                }
            }
        }

        public let id: String
        public let kind: Kind
        /// The headline: an event's title, a place name, what the work was on.
        public let title: String
        /// The quiet second line: a time, a duration, a count. Nil when there isn't one.
        public let detail: String?
        /// The photograph this tile shows, when it has one.
        ///
        /// A reference, never pixels: the view asks `PhotoFrames.thumbnail(for:size:)` at the
        /// moment it draws, and nothing decoded is kept anywhere. Nil on every other kind, and
        /// on a photo tile that came from an imported row rather than a live library.
        public let frame: PhotoFrames.Frame?
        /// What lands in the composer when this is picked.
        ///
        /// Ends mid-thought on purpose where a thought is expected to follow: the tile is
        /// meant to start a sentence, not to be one.
        public let line: String

        /// The switch in the way, when this tile is an offer rather than a fact.
        public let needs: Need?

        public init(
            id: String,
            kind: Kind,
            title: String,
            detail: String?,
            line: String,
            frame: PhotoFrames.Frame? = nil,
            needs: Need? = nil
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.line = line
            self.frame = frame
            self.needs = needs
        }
    }

    public let items: [Item]

    public init(items: [Item]) { self.items = items }

    public static let empty = DayContext(items: [])

    public var isEmpty: Bool { items.isEmpty }

    // MARK: - Limits

    /// How many meetings are worth offering. A day of eight standups is not eight invitations
    /// to write, and past about four tiles the strip stops reading as a glance.
    static let maxEvents = 4

    /// How many photo rows. One per place per day, so more than two means a day of moving
    /// around, worth two tiles, not six.
    static let maxPhotoRows = 2

    /// A stretch of work shorter than this is not what the day was about. Same threshold
    /// `JournalPrompt` uses, and for the same reason.
    static let minimumWorkSeconds: TimeInterval = 900

    // MARK: - Building

    /// Turns the day's imported captures and work spans into tiles.
    ///
    /// - Parameters:
    ///   - captures: Rows from `LifeImporter.calendarBundleID` and `PhotoImporter.bundleID`.
    ///     Anything else is ignored rather than trusted: a screen capture is not something to
    ///     hand somebody as a writing prompt, because it is the one source that can contain
    ///     text from an app they would not want quoted back at them.
    ///   - spans: Today's work spans. Only the longest is offered.
    ///   - frames: Today's photographs, from `PhotoFrames.frames(on:)`. References and times,
    ///     never pixels. When there are any they replace the imported photo rows, because a
    ///     picture of the afternoon says more than a count of it.
    ///   - weather: What the weather was, or why it is not there. `.off` is the normal case,
    ///     since the switch starts off, and it still produces a tile; see ``WeatherState``.
    public static func build(
        captures: [CaptureEvent],
        spans: [WorkSpan],
        frames: [PhotoFrames.Frame] = [],
        weather: WeatherState = .unavailable,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> DayContext {
        var items: [Item] = []

        // The photographs themselves, when the library is readable.
        for frame in frames.prefix(PhotoFrames.maxPerDay) {
            let time = clockTime(frame.date, calendar: calendar, locale: locale)
            items.append(Item(
                id: frame.id,
                kind: .photos,
                title: time,
                detail: nil,
                // Names no place and no subject, because nothing here knows either one. It
                // opens the sentence and leaves the picture to say what it is about.
                line: "\(time)… ",
                frame: frame
            ))
        }

        // Otherwise the imported day-rows, which survive when the library does not: no
        // permission, or macOS handing over a slice of it. They are the one source whose rows
        // say where somebody actually was rather than where they meant to be.
        let photoRows = (frames.isEmpty ? captures : [])
            .filter { $0.appBundleID == PhotoImporter.bundleID }
            .sorted { $0.ts < $1.ts }
            .prefix(maxPhotoRows)
        for row in photoRows {
            let place = row.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let count = photoCount(from: row.text)
            let title = (place?.isEmpty == false) ? place! : (count ?? "Photos")
            let detail = (place?.isEmpty == false) ? count : nil
            let line = (place?.isEmpty == false)
                ? "Photos from \(place!)… "
                : "Something worth a photograph today… "
            items.append(Item(
                id: row.id, kind: .photos, title: title, detail: detail, line: line
            ))
        }

        // Then the meetings, in the order they happened.
        let events = captures
            .filter { $0.appBundleID == LifeImporter.calendarBundleID }
            .sorted { $0.ts < $1.ts }
            .prefix(maxEvents)
        for row in events {
            let title = (row.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let time = clockTime(row.ts, calendar: calendar, locale: locale)
            items.append(Item(
                id: row.id,
                kind: .event,
                title: title,
                detail: time,
                line: "\(title), \(time)… "
            ))
        }

        // Then the weather, which is not about you and is often exactly why a day felt like it
        // did. Stated and not interpreted: "overcast, 24°", never "a gloomy day".
        switch weather {
        case .known(let day):
            let high = Int(day.highCelsius.rounded())
            let low = Int(day.lowCelsius.rounded())
            let opener = "\(day.summary.prefix(1).uppercased())\(day.summary.dropFirst())"
            items.append(Item(
                id: "weather",
                kind: .weather,
                title: "\(day.summary), \(high)°",
                detail: "low \(low)°",
                line: "\(opener), \(high)°… "
            ))

        case .off, .needsLocation:
            // The tile appears anyway, switched off, saying what it would be and offering the
            // one switch that turns it on.
            //
            // This is the opposite of how the rest of the app treats a declined permission,
            // and deliberately. Everything else Memoir shows is something it already has, so a
            // missing source is a smaller memory and not a thing to advertise. Weather is the
            // one capability nobody can discover by using the product: it is off by default,
            // it costs a network request, and a switch buried in Settings for a feature you
            // have never seen is a feature that does not exist. So it says so once, here,
            // where it would have appeared.
            items.append(Item(
                id: "weather",
                kind: .weather,
                title: "What the weather was",
                detail: nil,
                line: "",
                needs: weather == .off ? .weatherSwitch : .locationPermission
            ))

        case .unavailable:
            // Switched on, permitted, and the answer did not arrive. Nothing to offer and
            // nothing to ask for: a network that failed is not the user's problem to solve.
            break
        }

        // And the hours, last, because it is the one thing the composer already said.
        if let longest = spans.max(by: { $0.seconds < $1.seconds }),
           longest.seconds > minimumWorkSeconds {
            let howLong = duration(longest.seconds)
            items.append(Item(
                id: "work-\(longest.label)",
                kind: .work,
                title: longest.label,
                detail: howLong,
                line: "\(howLong) on \(longest.label)… "
            ))
        }

        return DayContext(items: items)
    }

    // MARK: - Formatting

    /// The count out of a photo row's evidence, which `PhotoImporter.DayInPlace.evidence`
    /// writes as `"6 photos · Cala Piccola"`.
    ///
    /// Reads the row rather than recomputing it so the tile and any answer sourced from the
    /// same row can never disagree about how many photographs there were.
    static func photoCount(from evidence: String) -> String? {
        let head = evidence.split(separator: "·", maxSplits: 1).first.map(String.init)
        let trimmed = (head ?? evidence).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `9:30` or `09:30`, whichever the user's region writes.
    static func clockTime(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: date)
    }

    /// `2h14` or `45m`. Short because it sits under a title in a tile, not in a sentence.
    /// `JournalPrompt` spells the same duration out in full for the opposite reason.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        guard minutes >= 60 else { return "\(minutes)m" }
        return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
    }
}
