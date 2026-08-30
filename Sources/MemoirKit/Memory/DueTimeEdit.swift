import Foundation

/// A time of day with no day attached: the only thing the confirm panel's due field can change.
///
/// Separate from `Date` on purpose. A `Date` carries a day, and the whole contract of editing
/// the due time is that the day the user actually said survives untouched, so the type that
/// crosses between the parser and the edit cannot be one that is able to carry a day at all.
public struct ClockTime: Equatable, Sendable {
    /// 0...23. Always the 24 hour reading, because 12 hour needs an am/pm the user may not
    /// have typed, and picking one for them is a guess.
    public let hour: Int
    /// 0...59.
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }
}

/// Reads a time of day out of what a person typed into the due field.
///
/// Deliberately not `MemoryDateResolver`. That resolver's job is to find a *date* inside a
/// sentence, and every form it knows resolves to a day plus a convention hour, which is the
/// exact thing being corrected here. What it does own are Memoir's conventions for the vague
/// words ("tonight" is 20:00, end of day is 18:00), so those are read from it rather than
/// copied: typing "tonight" into the field has to mean the same hour as saying "tonight" in
/// the sentence, or the panel and the parser would disagree about one word.
///
/// Everything here is a pure function of a string. No clock, no calendar, no locale, so the
/// tests can be exhaustive and the failures are never about what day it is.
public enum DueTime {

    /// What the typed text turned out to be.
    public enum Reading: Equatable, Sendable {
        /// Nothing typed. The user is clearing the due date, which is a real answer.
        case blank
        case time(ClockTime)
        /// Not a time. The caller must say so and leave the old value standing; guessing
        /// here would silently keep a value the user believes they changed.
        case unreadable
    }

    /// The reading of `typed`, or why there isn't one.
    public static func read(_ typed: String) -> Reading {
        let text = MemoryText.collapseWhitespace(typed)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !text.isEmpty else { return .blank }
        // A paste, not a time. Bounded before the regexes so a wall of text cannot be walked
        // character by character on every keystroke.
        guard text.count <= 24 else { return .unreadable }

        // Ordinary trailing punctuation from dictation and fast typing. Stripped rather than
        // rejected: "9pm." is a time, and refusing it teaches the user to distrust the field.
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!"))
        guard !body.isEmpty else { return .unreadable }

        if let named = namedHours[body] {
            return ClockTime(hour: named, minute: 0).map(Reading.time) ?? .unreadable
        }
        if let fractional = readFractional(body) { return fractional }
        if let numeric = readNumeric(body) { return numeric }
        return .unreadable
    }

    // MARK: - Words that name an hour

    /// Hour used for "morning". Nine is when a working day starts for most people, and the
    /// point of accepting the word at all is that the resulting 09:00 is on screen a keystroke
    /// later, where a wrong guess is visible instead of shipped.
    public static let morningHour = 9
    /// Hour used for "afternoon". Early enough to still be one.
    public static let afternoonHour = 14
    /// Hour used for "lunch". Deliberately not noon: people who say lunch and people who say
    /// noon rarely mean the same thing, and noon has an exact meaning that must survive.
    public static let lunchHour = 13

    /// Every word the field accepts in place of a number.
    ///
    /// A closed list, like `PushParser.leadIns`, and for the same reason: the alternative is
    /// inferring an hour from a word nobody defined, which is how a reminder acquires a time
    /// its owner never chose. "evening" and "tonight" defer to `MemoryDateResolver` so that
    /// one word cannot mean two hours depending on where it was typed.
    private static let namedHours: [String: Int] = [
        "noon": 12,
        "midday": 12,
        "midnight": 0,
        "morning": morningHour,
        "this morning": morningHour,
        "in the morning": morningHour,
        "afternoon": afternoonHour,
        "this afternoon": afternoonHour,
        "lunch": lunchHour,
        "lunchtime": lunchHour,
        "evening": MemoryDateResolver.eveningHour,
        "this evening": MemoryDateResolver.eveningHour,
        "tonight": MemoryDateResolver.eveningHour,
        "eod": MemoryDateResolver.endOfDayHour,
        "end of day": MemoryDateResolver.endOfDayHour,
        "end of the day": MemoryDateResolver.endOfDayHour,
    ]

    // MARK: - "half past two"

    /// Number words this field understands, one to twelve. Past twelve nobody spells it out.
    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    /// "half past 2", "quarter past nine", "quarter to 6", with an optional am or pm.
    ///
    /// Spoken far more often than typed, which is exactly why it is here: this field is one
    /// Return away from a dictated sentence, and the words people say out loud have to land.
    private static func readFractional(_ text: String) -> Reading? {
        // Non-capturing on purpose: the marker is read by group number, and a nested capture
        // here would silently shift it by one and drop every "half past 2 pm" to 02:30.
        let words = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
        guard let re = try? NSRegularExpression(
            pattern: "^(half|quarter)\\s+(past|to)\\s+(\\d{1,2}|\(words))\\s*(am|pm)?$",
            options: []
        ) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        else { return nil }

        let size = ns.substring(with: m.range(at: 1)) == "half" ? 30 : 15
        let direction = ns.substring(with: m.range(at: 2))
        let rawHour = ns.substring(with: m.range(at: 3))
        guard let baseHour = Int(rawHour) ?? numberWords[rawHour] else { return .unreadable }
        let marker = m.range(at: 4).location == NSNotFound ? "" : ns.substring(with: m.range(at: 4))
        guard let hour = applyMarker(marker, to: baseHour) else { return .unreadable }

        // Minutes from midnight, so "to" is subtraction rather than a special case. A result
        // below zero is "quarter to midnight", which belongs to the day before. Moving
        // the day is the one thing this edit may never do, so it is refused instead.
        let minutes = hour * 60 + (direction == "past" ? size : -size)
        guard minutes >= 0 else { return .unreadable }
        return ClockTime(hour: minutes / 60, minute: minutes % 60).map(Reading.time) ?? .unreadable
    }

    // MARK: - Numbers

    /// "9", "9am", "9:30", "9.30", "21:30", "0930", "2130".
    private static func readNumeric(_ text: String) -> Reading? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Separated: the separator settles that the second group is minutes, so nothing here
        // has to guess.
        if let re = try? NSRegularExpression(pattern: "^(\\d{1,2})[:.](\\d{2})\\s*(am|pm)?$", options: []),
           let m = re.firstMatch(in: text, options: [], range: full) {
            guard let base = Int(ns.substring(with: m.range(at: 1))),
                  let minute = Int(ns.substring(with: m.range(at: 2)))
            else { return .unreadable }
            let marker = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
            guard let hour = applyMarker(marker, to: base) else { return .unreadable }
            return ClockTime(hour: hour, minute: minute).map(Reading.time) ?? .unreadable
        }

        // Bare digits, optionally with a marker. One or two digits are an hour; three or four
        // are the run-together form people type on a keypad.
        if let re = try? NSRegularExpression(pattern: "^(\\d{1,4})\\s*(am|pm)?$", options: []),
           let m = re.firstMatch(in: text, options: [], range: full) {
            let digits = ns.substring(with: m.range(at: 1))
            let marker = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            guard let value = Int(digits) else { return .unreadable }

            if digits.count <= 2 {
                // A bare "9" is 09:00 and a bare "21" is 21:00: the 24 hour reading, always.
                // Reading "3" as the afternoon would be Memoir choosing an hour the user did not
                // type, which is the bug this whole field exists to fix. The result appears in
                // the panel immediately, so a wrong reading costs one correction, not a
                // missed reminder.
                guard let hour = applyMarker(marker, to: value) else { return .unreadable }
                return ClockTime(hour: hour, minute: 0).map(Reading.time) ?? .unreadable
            }
            // "930" and "2130". An am or pm marker on top of a four digit clock reading is a
            // contradiction, so it is refused rather than resolved in the user's favour.
            guard marker.isEmpty else { return .unreadable }
            return ClockTime(hour: value / 100, minute: value % 100).map(Reading.time) ?? .unreadable
        }

        return nil
    }

    /// Applies an "am" or "pm" marker to an hour, or nil when the two contradict each other.
    private static func applyMarker(_ marker: String, to hour: Int) -> Int? {
        guard !marker.isEmpty else { return hour }
        // "13pm" is not a time anybody means, and quietly reading it as 13:00 would hide a
        // typo behind a value that looks deliberate.
        guard (1...12).contains(hour) else { return nil }
        if marker == "pm" { return hour == 12 ? 12 : hour + 12 }
        return hour == 12 ? 0 : hour
    }
}

/// Applying an edit of the due field to a ``PushIntent``, and the words that describe one.
///
/// Every decision the confirm panel makes about the due date lives here rather than in the
/// view, because the view cannot be tested and these are the rules that can go wrong quietly:
/// which day the edited time lands on, what an empty field means, and whether the hour on
/// screen is one the user chose or one Memoir supplied.
public enum DueEdit {

    /// The outcome of applying typed text to a proposal.
    public enum Result: Equatable, Sendable {
        /// The edit was understood. The intent carries the new value and nothing else moved.
        case applied(PushIntent)
        /// The text was not a time, or there was nowhere to put one. The reason is shown to
        /// the user and the previous value stands: a rejected edit that silently kept the old
        /// number would be the same failure as a wrong default, one step later.
        case rejected(String)
    }

    /// The proposal with the typed time applied, or the reason it was not.
    ///
    /// - Parameters:
    ///   - typed: exactly what is in the field, unnormalised.
    ///   - intent: the proposal on screen. Never mutated; a new value is returned.
    ///   - day: the day the time lands on. The caller holds the day the *parse* produced and
    ///     passes it unchanged for the life of the card, so clearing the field and typing a
    ///     time again restores the day the user actually said rather than inventing one.
    ///   - calendar: the frame the day is read in. Defaults to the one the resolver used.
    public static func apply(
        _ typed: String,
        to intent: PushIntent,
        day: Date?,
        calendar: Calendar = DueEdit.localCalendar
    ) -> Result {
        switch DueTime.read(typed) {
        case .blank:
            // An empty field means no due date. It does NOT mean midnight, which is what a
            // date built from an empty time would be: a reminder at 00:00 is a reminder that
            // fires while you sleep, off the back of a field the user simply cleared. CF-52
            // applies to an edit exactly as it applies to a parse.
            var out = intent
            out.dueAt = nil
            out.dueTimeIsConvention = false
            return .applied(out)

        case .unreadable:
            return .rejected(unreadable(typed))

        case .time(let clock):
            guard let day else { return .rejected(noDay) }
            guard let moved = instant(of: clock, on: day, calendar: calendar) else {
                return .rejected(impossibleHour)
            }
            var out = intent
            out.dueAt = moved
            // Whatever it was before, this hour is now the user's. The label comes off.
            out.dueTimeIsConvention = false
            return .applied(out)
        }
    }

    /// The instant `clock` names on `day`, or nil when that hour does not happen there.
    ///
    /// The day is read back rather than trusted. On the spring clock change an hour of the day
    /// does not exist, and `bySettingHour` quietly hands back the next one that does: silently
    /// saving 03:00 for a user who typed 02:30 is the same failure as the default they came
    /// here to fix. Reading the day back is also what makes "changing the time never changes
    /// the day" a property this code checks rather than one it hopes for.
    static func instant(of clock: ClockTime, on day: Date, calendar: Calendar) -> Date? {
        guard let moved = calendar.date(
                bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day),
              calendar.isDate(moved, inSameDayAs: day),
              calendar.component(.hour, from: moved) == clock.hour,
              calendar.component(.minute, from: moved) == clock.minute
        else { return nil }
        return moved
    }

    // MARK: - What the panel shows

    /// Said out loud rather than left blank, so a date nobody gave cannot be mistaken for a
    /// date nobody displayed.
    public static let noDateText = "no date given"

    /// The label that admits an hour came from Memoir rather than from the user.
    ///
    /// A default the user cannot tell apart from their own intent is how the wrong hour ships:
    /// 17:00 is a reasonable convention for "that day" and a bad final answer for a reminder,
    /// and the only thing that makes it safe is that it says whose idea it was.
    public static let conventionNote = "Memoir's default"

    /// ``conventionNote`` when the hour on screen is Memoir's, nil when it is the user's.
    ///
    /// - Parameter draft: what the edit field currently holds, when there is one. The label
    ///   is dropped as soon as the field stops matching the proposal, because from that
    ///   keystroke on the hour being previewed is the user's and calling it Memoir's would be
    ///   the same lie in the other direction.
    public static func note(
        for intent: PushIntent,
        draft: String? = nil,
        timeZone: TimeZone = .current
    ) -> String? {
        guard intent.dueAt != nil, intent.dueTimeIsConvention else { return nil }
        if let draft, draft != editableText(for: intent, timeZone: timeZone) { return nil }
        return conventionNote
    }

    /// The due date spelled out.
    ///
    /// Absolute, never relative: "tomorrow at 10" would need a *now* to render, and reading
    /// the clock here could make the panel describe a different day from the one the parse
    /// resolved against its injected reference date.
    public static func absoluteText(
        _ due: Date?,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let due else { return noDateText }
        return formatter(format: "EEE d MMM, HH:mm", locale: locale, timeZone: timeZone).string(from: due)
    }

    /// What the editable field starts out holding: the current time of day, or nothing.
    ///
    /// 24 hour and separated, so it reads back through ``DueTime/read(_:)`` as the same time.
    /// The field is the value, not a description of it, and a field whose own contents it
    /// would reject is a trap: tab in, press Return, and be told your own unchanged time is
    /// not a time.
    ///
    /// Which is why the digits are POSIX and not the user's locale. ``absoluteText(_:locale:timeZone:)``
    /// is prose and should read the way the reader's machine reads dates; this is a value being
    /// handed to a parser that only knows Western digits, and localising it would spring exactly
    /// that trap on everyone whose locale numbers itself differently.
    public static func editableText(
        for intent: PushIntent,
        timeZone: TimeZone = .current
    ) -> String {
        guard let due = intent.dueAt else { return "" }
        return formatter(format: "HH:mm", locale: fieldLocale, timeZone: timeZone).string(from: due)
    }

    /// The locale the edit field's own text is written in. See ``editableText(for:timeZone:)``.
    static let fieldLocale = Locale(identifier: "en_US_POSIX")

    /// The live reading of what is currently typed, for display beside the field.
    ///
    /// Nil while the text is not yet a time. Half-typed input is not a mistake and must not be
    /// shouted at: the complaint belongs to the moment the user commits, not to every
    /// keystroke on the way to "9:30".
    public static func preview(
        _ typed: String,
        day: Date?,
        calendar: Calendar = DueEdit.localCalendar,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        switch DueTime.read(typed) {
        case .blank:
            return noDateText
        case .unreadable:
            return nil
        case .time(let clock):
            // The same arithmetic the save uses, so the panel cannot preview one instant and
            // write another.
            guard let day, let moved = instant(of: clock, on: day, calendar: calendar) else { return nil }
            return absoluteText(moved, locale: locale, timeZone: timeZone)
        }
    }

    // MARK: - Whose hour is it

    /// True when `date`'s time of day is one Memoir supplies for a phrase that named a day and no
    /// time, rather than one the user's own words account for.
    ///
    /// Two questions, in this order, because the cheap one settles most cases: is the time one
    /// of Memoir's conventions at all, and if it is, did the user say it anyway. When in doubt it
    /// answers **true**. A label on an hour the user did choose costs them a glance at a value
    /// that turns out to be right; a missing label on an hour Memoir chose costs them the
    /// reminder, which is the failure this exists to prevent.
    static func timeIsConvention(_ date: Date, statedIn text: String, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        guard minute == 0, conventionHours.contains(hour) else { return false }
        return !stated(ClockTime(hour: hour, minute: 0), in: text)
    }

    /// The hours `MemoryDateResolver` supplies when a phrase names a day and no time.
    ///
    /// Read from the resolver rather than repeated, so moving the convention moves the label
    /// with it. The cost of the set being hours rather than provenance is recorded rather than
    /// fixed: "send it friday 18" resolves to 18:00 from the user's own "18" and still gets
    /// labelled, because the reading below only counts a stated hour it can be sure of.
    private static let conventionHours: Set<Int> = [
        MemoryDateResolver.defaultHour,
        MemoryDateResolver.eveningHour,
        MemoryDateResolver.endOfDayHour,
    ]

    /// True when `text` contains a clock time that accounts for `clock`.
    ///
    /// Only the unambiguous forms count: a separator, an am/pm marker, "at" in front of a
    /// number, or one of the words that names an hour outright. A bare number loose in a
    /// sentence is not evidence ("send the 17 invoices friday" is not somebody setting 17:00),
    /// and treating it as evidence would strip the label off an hour Memoir actually chose.
    private static func stated(_ clock: ClockTime?, in source: String) -> Bool {
        guard let clock else { return false }
        let lower = source.lowercased()
        let ns = lower as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let re = try? NSRegularExpression(
            pattern: "\\b(?:at\\s+(\\d{1,2})|(\\d{1,2})[:.](\\d{2})\\s*(am|pm)?|(\\d{1,2})\\s*(am|pm)|(noon|midday|midnight|tonight|this evening))\\b",
            options: []
        ) else { return false }

        for m in re.matches(in: lower, options: [], range: full) {
            var candidate: ClockTime?
            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            if let at = group(1), let hour = Int(at) {
                candidate = ClockTime(hour: hour, minute: 0)
            } else if let h = group(2), let mm = group(3), let hour = Int(h), let minute = Int(mm) {
                candidate = DueTime.read("\(hour):\(String(format: "%02d", minute)) \(group(4) ?? "")")
                    .clockTime
            } else if let h = group(5), let marker = group(6), let hour = Int(h) {
                candidate = DueTime.read("\(hour)\(marker)").clockTime
            } else if let word = group(7) {
                candidate = DueTime.read(word).clockTime
            }
            if candidate == clock { return true }
        }
        return false
    }

    // MARK: - Rejections

    /// The complaint for text that is not a time. Quotes what they typed back at them, because
    /// "that is not a time" is unhelpful when the field is showing a dictation mishearing.
    static func unreadable(_ typed: String) -> String {
        let shown = MemoryText.truncate(
            MemoryText.collapseWhitespace(typed).trimmingCharacters(in: .whitespaces), max: 20)
        return "Didn't recognise \"\(shown)\" as a time. Try 9, 9:30, 9am, noon or tonight."
    }

    /// The complaint for a time with no day under it.
    ///
    /// The alternative is picking a day, and there is no day to pick that the user said. CF-52
    /// does not stop applying because the field looks empty and inviting.
    static let noDay = "No day was given, so a time has nowhere to land. Say the day in your message."

    /// The complaint for an hour that does not exist on that day.
    static let impossibleHour = "The clocks change that day, so that time doesn't exist. Try another."

    // MARK: - Frames

    /// The calendar every day in the push path is read and written in.
    ///
    /// `MemoryDateResolver` resolves days in `TimeZone.current`, so an edit that read them in
    /// any other frame would move the day for every user whose offset is not zero. Computed
    /// rather than stored: a machine that changes timezone mid-session must not keep answering
    /// with the old one.
    public static var localCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale.current
        c.timeZone = TimeZone.current
        return c
    }

    private static func formatter(format: String, locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.timeZone = timeZone
        fmt.dateFormat = format
        return fmt
    }
}

extension DueTime.Reading {
    /// The time this reading carries, if it carries one.
    var clockTime: ClockTime? {
        if case .time(let t) = self { return t }
        return nil
    }
}
