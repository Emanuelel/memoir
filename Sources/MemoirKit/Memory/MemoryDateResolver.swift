import Foundation

/// Resolves date expressions found in captured text to absolute `Date` values,
/// always relative to the timestamp of the capture rather than to "now".
///
/// Relative expressions ("tomorrow", "Friday", "next week") are handled with
/// explicit calendar arithmetic so that consolidating an old capture still yields
/// the date the writer meant. Everything else is handed to `NSDataDetector`, which
/// is far better at absolute dates than any hand-written regex.
///
/// Day-granularity expressions resolve to 17:00 local time, the convention Memoir uses
/// for "end of that working day". An explicit time in the same sentence overrides it.
struct MemoryDateResolver {

    /// A resolved date plus the text it was read from.
    struct Hit {
        /// The absolute instant the expression resolves to.
        let date: Date
        /// The matched text, for provenance.
        let snippet: String
        /// Where in the source string the expression was found.
        let range: NSRange
    }

    /// Hour used for expressions that name a day but no time.
    static let defaultHour = 17
    /// Hour used for "tonight".
    static let eveningHour = 20
    /// Hour used for "eod" and "end of the day". Named rather than left inline because the
    /// confirm panel offers the same word in its due field, and the two must not drift apart.
    static let endOfDayHour = 18

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale.current
        c.timeZone = TimeZone.current
        return c
    }

    /// The first date expression in `text`, resolved against `reference`.
    func first(in text: String, reference: Date) -> Hit? {
        hits(in: text, reference: reference).first
    }

    /// Every date expression in `text`, in order of appearance, resolved against `reference`.
    func hits(in text: String, reference: Date) -> [Hit] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        var out: [Hit] = []
        var covered: [NSRange] = []

        func claim(_ range: NSRange) -> Bool {
            for r in covered where NSIntersectionRange(r, range).length > 0 { return false }
            covered.append(range)
            return true
        }

        for hit in relativeHits(ns: ns, reference: reference) where claim(hit.range) {
            out.append(hit)
        }
        for hit in absoluteHits(ns: ns, reference: reference) where claim(hit.range) {
            out.append(hit)
        }
        for hit in detectorHits(ns: ns, reference: reference) where claim(hit.range) {
            out.append(hit)
        }

        return out.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Relative expressions

    private func relativeHits(ns: NSString, reference: Date) -> [Hit] {
        var out: [Hit] = []
        let full = NSRange(location: 0, length: ns.length)
        let cal = calendar

        func add(_ range: NSRange, _ date: Date?) {
            guard let date else { return }
            let snippet = ns.substring(with: range)
            let adjusted = applyExplicitTime(to: date, ns: ns, near: range) ?? date
            out.append(Hit(date: adjusted, snippet: snippet, range: range))
        }

        // today / tonight / tomorrow / yesterday / day after tomorrow
        for (pattern, days, hour) in [
            ("\\bday after tomorrow\\b", 2, Self.defaultHour),
            ("\\btomorrow\\b", 1, Self.defaultHour),
            ("\\btonight\\b", 0, Self.eveningHour),
            ("\\bthis evening\\b", 0, Self.eveningHour),
            ("\\btoday\\b", 0, Self.defaultHour),
            ("\\byesterday\\b", -1, Self.defaultHour),
            ("\\b(?:eod|end of (?:the )?day)\\b", 0, Self.endOfDayHour),
        ] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: ns as String, options: [], range: full) {
                let base = cal.date(byAdding: .day, value: days, to: reference)
                add(m.range, setTime(base, hour: hour, calendar: cal))
            }
        }

        // next week / this week / end of week / next month
        if let re = try? NSRegularExpression(
            pattern: "\\b(next week|this week|end of (?:the )?week|eow|next month|next monday)\\b",
            options: [.caseInsensitive]
        ) {
            for m in re.matches(in: ns as String, options: [], range: full) {
                let phrase = ns.substring(with: m.range).lowercased()
                var date: Date?
                if phrase == "next week" {
                    date = setTime(cal.date(byAdding: .day, value: 7, to: reference), hour: Self.defaultHour, calendar: cal)
                } else if phrase == "next month" {
                    date = setTime(cal.date(byAdding: .month, value: 1, to: reference), hour: Self.defaultHour, calendar: cal)
                } else if phrase == "next monday" {
                    date = weekday(6, from: reference, modifier: "next", calendar: cal)
                } else {
                    // this week / end of week: the coming Friday.
                    date = weekday(6, from: reference, modifier: "this", calendar: cal)
                }
                add(m.range, date)
            }
        }

        // in N days / weeks / hours / months
        if let re = try? NSRegularExpression(
            pattern: "\\bin (\\d{1,3}|a|an|two|three|four|five) (hour|hours|day|days|week|weeks|month|months)\\b",
            options: [.caseInsensitive]
        ) {
            for m in re.matches(in: ns as String, options: [], range: full) {
                guard m.numberOfRanges >= 3 else { continue }
                let rawCount = ns.substring(with: m.range(at: 1)).lowercased()
                let unit = ns.substring(with: m.range(at: 2)).lowercased()
                let count = Int(rawCount) ?? ["a": 1, "an": 1, "two": 2, "three": 3, "four": 4, "five": 5][rawCount] ?? 0
                guard count > 0 else { continue }
                var date: Date?
                switch unit {
                case "hour", "hours":
                    date = cal.date(byAdding: .hour, value: count, to: reference)
                case "day", "days":
                    date = setTime(cal.date(byAdding: .day, value: count, to: reference), hour: Self.defaultHour, calendar: cal)
                case "week", "weeks":
                    date = setTime(cal.date(byAdding: .day, value: count * 7, to: reference), hour: Self.defaultHour, calendar: cal)
                default:
                    date = setTime(cal.date(byAdding: .month, value: count, to: reference), hour: Self.defaultHour, calendar: cal)
                }
                add(m.range, date)
            }
        }

        // weekday names, with optional this / next / on / by / before
        let names = "(sunday|sun|monday|mon|tuesday|tues|tue|wednesday|weds|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat)"
        if let re = try? NSRegularExpression(
            pattern: "\\b(this|next|on|by|before|coming|due)?\\s*\(names)\\b",
            options: [.caseInsensitive]
        ) {
            for m in re.matches(in: ns as String, options: [], range: full) {
                guard m.numberOfRanges >= 3 else { continue }
                let modifier = m.range(at: 1).location == NSNotFound
                    ? ""
                    : ns.substring(with: m.range(at: 1)).lowercased()
                let name = ns.substring(with: m.range(at: 2)).lowercased()
                guard let index = Self.weekdayIndex(name) else { continue }
                add(m.range, weekday(index, from: reference, modifier: modifier, calendar: cal))
            }
        }

        return out
    }

    // MARK: - Absolute expressions

    private func absoluteHits(ns: NSString, reference: Date) -> [Hit] {
        var out: [Hit] = []
        let full = NSRange(location: 0, length: ns.length)
        let cal = calendar

        func add(_ range: NSRange, _ date: Date?) {
            guard let date else { return }
            let adjusted = applyExplicitTime(to: date, ns: ns, near: range) ?? date
            out.append(Hit(date: adjusted, snippet: ns.substring(with: range), range: range))
        }

        // ISO 8601 date, optionally with a time.
        if let re = try? NSRegularExpression(
            pattern: "\\b(\\d{4})-(\\d{1,2})-(\\d{1,2})(?:[T ](\\d{1,2}):(\\d{2}))?\\b",
            options: []
        ) {
            for m in re.matches(in: ns as String, options: [], range: full) {
                guard let year = intAt(m, 1, ns), let month = intAt(m, 2, ns), let day = intAt(m, 3, ns) else { continue }
                guard (1...12).contains(month), (1...31).contains(day) else { continue }
                var comps = DateComponents()
                comps.year = year
                comps.month = month
                comps.day = day
                comps.hour = intAt(m, 4, ns) ?? Self.defaultHour
                comps.minute = intAt(m, 5, ns) ?? 0
                out.append(Hit(date: cal.date(from: comps) ?? reference, snippet: ns.substring(with: m.range), range: m.range))
            }
        }

        // Numeric day/month, locale aware. Year optional.
        if let re = try? NSRegularExpression(
            pattern: "(?<![\\d/-])(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?(?![\\d/-])",
            options: []
        ) {
            let dayFirst = Self.localeIsDayFirst
            for m in re.matches(in: ns as String, options: [], range: full) {
                guard let a = intAt(m, 1, ns), let b = intAt(m, 2, ns) else { continue }
                var day = dayFirst ? a : b
                var month = dayFirst ? b : a
                if a > 12, b <= 12 { day = a; month = b }
                if b > 12, a <= 12 { day = b; month = a }
                guard (1...12).contains(month), (1...31).contains(day) else { continue }
                var comps = DateComponents()
                comps.day = day
                comps.month = month
                comps.hour = Self.defaultHour
                if var year = intAt(m, 3, ns) {
                    if year < 100 { year += 2000 }
                    comps.year = year
                    add(m.range, cal.date(from: comps))
                } else {
                    comps.year = cal.component(.year, from: reference)
                    add(m.range, normalizeYear(cal.date(from: comps), reference: reference, calendar: cal))
                }
            }
        }

        // "Aug 12", "12 August", "August 12th, 2026"
        let months = "(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)"
        let monthPatterns = [
            "\\b\(months)[a-z]*\\.?,?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?\\b",
            "\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?\(months)[a-z]*\\.?(?:,?\\s+(\\d{4}))?\\b",
        ]
        for (i, pattern) in monthPatterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let monthGroup = i == 0 ? 1 : 2
            let dayGroup = i == 0 ? 2 : 1
            for m in re.matches(in: ns as String, options: [], range: full) {
                guard m.numberOfRanges >= 3 else { continue }
                let monthName = ns.substring(with: m.range(at: monthGroup)).lowercased()
                guard let month = Self.monthIndex(monthName), let day = intAt(m, dayGroup, ns), (1...31).contains(day) else { continue }
                var comps = DateComponents()
                comps.month = month
                comps.day = day
                comps.hour = Self.defaultHour
                if let year = intAt(m, 3, ns) {
                    comps.year = year
                    add(m.range, cal.date(from: comps))
                } else {
                    comps.year = cal.component(.year, from: reference)
                    add(m.range, normalizeYear(cal.date(from: comps), reference: reference, calendar: cal))
                }
            }
        }

        return out
    }

    // MARK: - NSDataDetector

    private func detectorHits(ns: NSString, reference: Date) -> [Hit] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let full = NSRange(location: 0, length: ns.length)
        let cal = calendar
        let now = Date()
        var out: [Hit] = []

        for m in detector.matches(in: ns as String, options: [], range: full) {
            guard var date = m.date else { continue }
            let text = ns.substring(with: m.range)

            // The detector resolves relative phrasing against "now". Re-anchor it to the
            // capture timestamp when the two are on different days.
            if Self.looksRelative(text) {
                let dayDelta = cal.dateComponents(
                    [.day],
                    from: cal.startOfDay(for: now),
                    to: cal.startOfDay(for: reference)
                ).day ?? 0
                if dayDelta != 0, let shifted = cal.date(byAdding: .day, value: dayDelta, to: date) {
                    date = shifted
                }
            } else {
                date = normalizeYear(date, reference: reference, calendar: cal) ?? date
            }

            out.append(Hit(date: date, snippet: text, range: m.range))
        }
        return out
    }

    // MARK: - Helpers

    private func intAt(_ m: NSTextCheckingResult, _ index: Int, _ ns: NSString) -> Int? {
        guard index < m.numberOfRanges else { return nil }
        let r = m.range(at: index)
        guard r.location != NSNotFound, r.length > 0 else { return nil }
        return Int(ns.substring(with: r))
    }

    private func setTime(_ date: Date?, hour: Int, calendar: Calendar) -> Date? {
        guard let date else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)
    }

    /// Pulls the calendar year toward the reference date when the text omitted one.
    private func normalizeYear(_ date: Date?, reference: Date, calendar: Calendar) -> Date? {
        guard var date else { return nil }
        var guard_ = 0
        while date.timeIntervalSince(reference) < -120 * 86_400, guard_ < 4 {
            guard let next = calendar.date(byAdding: .year, value: 1, to: date) else { break }
            date = next
            guard_ += 1
        }
        while date.timeIntervalSince(reference) > 300 * 86_400, guard_ < 8 {
            guard let prev = calendar.date(byAdding: .year, value: -1, to: date) else { break }
            date = prev
            guard_ += 1
        }
        return date
    }

    /// Resolves a weekday name to the next matching day.
    ///
    /// - `this Friday` is the coming Friday, today included.
    /// - a bare `Friday` is the next Friday strictly after the reference day.
    /// - `next Friday` is the Friday of the following calendar week.
    private func weekday(_ index: Int, from reference: Date, modifier: String, calendar: Calendar) -> Date? {
        let startOfReference = calendar.startOfDay(for: reference)
        let current = calendar.component(.weekday, from: startOfReference)
        var delta = index - current
        if modifier == "this" {
            if delta < 0 { delta += 7 }
        } else {
            if delta <= 0 { delta += 7 }
        }
        if modifier == "next", delta < 7 {
            let sameWeek = calendar.isDate(
                calendar.date(byAdding: .day, value: delta, to: startOfReference) ?? startOfReference,
                equalTo: startOfReference,
                toGranularity: .weekOfYear
            )
            if sameWeek { delta += 7 }
        }
        guard let day = calendar.date(byAdding: .day, value: delta, to: startOfReference) else { return nil }
        return calendar.date(bySettingHour: Self.defaultHour, minute: 0, second: 0, of: day)
    }

    /// Looks for an explicit clock time immediately after a day expression and applies it.
    private func applyExplicitTime(to date: Date, ns: NSString, near range: NSRange) -> Date? {
        let start = range.location + range.length
        let length = min(28, ns.length - start)
        guard length > 0 else { return nil }
        let tail = ns.substring(with: NSRange(location: start, length: length))
        guard let re = try? NSRegularExpression(
            pattern: "^\\s*(?:at\\s+)?(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?\\b",
            options: [.caseInsensitive]
        ) else { return nil }
        let tailNS = tail as NSString
        guard let m = re.firstMatch(in: tail, options: [], range: NSRange(location: 0, length: tailNS.length)),
              m.range(at: 1).location != NSNotFound,
              var hour = Int(tailNS.substring(with: m.range(at: 1)))
        else { return nil }
        let minute = m.range(at: 2).location == NSNotFound ? 0 : Int(tailNS.substring(with: m.range(at: 2))) ?? 0
        let marker = m.range(at: 3).location == NSNotFound ? "" : tailNS.substring(with: m.range(at: 3)).lowercased()
        if marker.isEmpty, hour > 23 { return nil }
        if marker == "pm", hour < 12 { hour += 12 }
        if marker == "am", hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        if marker.isEmpty, hour < 7 { return nil }   // "Friday 3" is not a time
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }

    /// Calendar weekday number (Sunday == 1) for a weekday name or abbreviation.
    static func weekdayIndex(_ name: String) -> Int? {
        switch name.lowercased() {
        case "sunday", "sun": return 1
        case "monday", "mon": return 2
        case "tuesday", "tues", "tue": return 3
        case "wednesday", "weds", "wed": return 4
        case "thursday", "thurs", "thur", "thu": return 5
        case "friday", "fri": return 6
        case "saturday", "sat": return 7
        default: return nil
        }
    }

    /// Month number for a month name or three letter abbreviation.
    static func monthIndex(_ name: String) -> Int? {
        switch name.lowercased() {
        case "jan": return 1
        case "feb": return 2
        case "mar": return 3
        case "apr": return 4
        case "may": return 5
        case "jun": return 6
        case "jul": return 7
        case "aug": return 8
        case "sep", "sept": return 9
        case "oct": return 10
        case "nov": return 11
        case "dec": return 12
        default: return nil
        }
    }

    /// True when the user's locale writes the day before the month.
    static var localeIsDayFirst: Bool {
        guard let template = DateFormatter.dateFormat(fromTemplate: "MMdd", options: 0, locale: Locale.current) else {
            return true
        }
        guard let d = template.firstIndex(of: "d"), let m = template.firstIndex(of: "M") else { return true }
        return d < m
    }

    /// True when a matched span contains wording that is relative to the reading moment.
    static func looksRelative(_ text: String) -> Bool {
        let lower = text.lowercased()
        for token in [
            "today", "tonight", "tomorrow", "yesterday", "next", "this ", "coming",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "mon ", "tue", "wed", "thu", "fri", "sat", "sun ",
        ] where lower.contains(token) {
            return true
        }
        return false
    }
}
