import Foundation
import MemoirKit

/// Deterministic, locale-independent formatting helpers.
///
/// Output is consumed by another model, so everything is stable and explicit:
/// ISO-8601 timestamps carrying the local UTC offset, English weekday and month
/// names, and durations written the way a person would read them aloud.
public enum Fmt {
    private static let weekdayNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// A gregorian calendar pinned to the machine's current time zone.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }

    // MARK: - Absolute time

    /// ISO-8601 in local time with an explicit UTC offset, e.g. `2026-07-30T14:22:11+02:00`.
    public static func iso(_ date: Date) -> String {
        let zone = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = zone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let magnitude = abs(offset)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
            sign, magnitude / 3600, (magnitude % 3600) / 60
        )
    }

    /// `Thursday 30 July 2026`.
    public static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let weekday = weekdayNames[max(0, min(6, (c.weekday ?? 1) - 1))]
        let month = monthNames[max(0, min(11, (c.month ?? 1) - 1))]
        return "\(weekday) \(c.day ?? 0) \(month) \(c.year ?? 0)"
    }

    /// True when every term appears as a whole word inside one window of `width` characters.
    ///
    /// What `verify` used to ask was whether every term appeared *somewhere* in the capture,
    /// and a capture is a whole accessibility tree — a page of 2,300 characters, navigation,
    /// sidebar, footer and all. Two words two thousand characters apart, in unrelated parts of
    /// a page neither of them was about, certified a claim. The tool whose entire job is
    /// evidence had the loosest test in the product.
    ///
    /// Two changes, both about scope rather than about which words count. The window bounds
    /// how far apart the terms may be, because a claim is a sentence and sentences are short.
    /// And matching is whole-word, because substring co-presence found "cat" inside "catering"
    /// and counted it.
    ///
    /// This is a narrower promise, not entailment. Words near each other on one screen is
    /// still not the same as the screen asserting the claim, and no window size makes it so.
    /// The tool says what it observed and stops there.
    public static func coOccur(_ terms: [String], in haystack: String, width: Int = 400) -> Bool {
        guard !terms.isEmpty else { return false }
        let hay = Array(haystack.lowercased())
        guard !hay.isEmpty else { return false }
        let needles = terms.map { Array($0.lowercased()) }
        guard needles.allSatisfy({ !$0.isEmpty }) else { return false }

        // Where each term occurs, as a whole word.
        var positions: [[Int]] = []
        for needle in needles {
            var found: [Int] = []
            if needle.count <= hay.count {
                for start in 0...(hay.count - needle.count) {
                    guard Array(hay[start..<(start + needle.count)]) == needle else { continue }
                    let beforeOK = start == 0 || !isWordCharacter(hay[start - 1])
                    let end = start + needle.count
                    let afterOK = end == hay.count || !isWordCharacter(hay[end])
                    if beforeOK && afterOK { found.append(start) }
                }
            }
            if found.isEmpty { return false }
            positions.append(found)
        }

        // Anchor on the term with the fewest occurrences and ask whether the others reach it.
        guard let anchorIndex = positions.indices.min(by: { positions[$0].count < positions[$1].count })
        else { return false }
        for anchor in positions[anchorIndex] {
            let reachable = positions.indices.allSatisfy { i in
                i == anchorIndex || positions[i].contains { abs($0 - anchor) <= width }
            }
            if reachable { return true }
        }
        return false
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// `2019-07-15`, the date part only, in local time.
    ///
    /// The fallback for an imported row written before schema v10 gave it a stored date. It
    /// is the reader's answer rather than the importer's, which is exactly the ambiguity
    /// `local_day` exists to end — so it is only ever used where there is nothing better.
    public static func isoDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return LifeImporter.localDayKey(date, calendar: calendar)
    }

    /// `14:22` in local time.
    public static func clock(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - Relative time

    /// A compact duration: `2d 3h`, `1h 23m`, `47m`, `12s`.
    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        if total < 0 { return "0s" }
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }

    /// `12m ago` / `in 3h` / `just now`.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(date)
        if abs(delta) < 45 { return "just now" }
        return delta > 0 ? "\(duration(delta)) ago" : "in \(duration(-delta))"
    }

    // MARK: - Text

    /// First eight characters of an id, enough to cite without bloating output.
    public static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }

    /// Collapses all whitespace runs into single spaces and trims.
    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncates to `limit` characters, appending an ellipsis when cut.
    public static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// A one-line excerpt from the most informative part of a capture.
    ///
    /// Provenance is only useful if the consuming agent can see the words the
    /// memory was derived from, so every capture is rendered through this.
    ///
    /// This used to centre on the **first** occurrence of the **first** matching term and
    /// stop looking. On a site whose own name and navigation sit at the top of every page,
    /// that anchor is always character zero: a LinkedIn feed capture opens with
    /// `Feed | LinkedIn / 0 notifications / Skip navigation menu / Home / My Network / Jobs`,
    /// so any query mentioning "linkedin", "feed" or "post" matched the menu and rendered
    /// 220 characters of it. The post the user was actually reading sat 14,605 characters
    /// further in and was never shown, and an agent handed that snippet reported, in good
    /// faith, that the content had not been captured. It had. This is the fix for a memory
    /// that denies holding what it holds.
    ///
    /// So every candidate window is scored rather than the first one taken, on two signals:
    /// how many *distinct* query terms it covers, and how much of it reads like prose. The
    /// second is what demotes navigation, because navigation is a stack of two-word lines
    /// and content is not. It is also why a query with no matching term at all now returns
    /// something the user read instead of the top of the chrome.
    public static func snippet(_ text: String, matching terms: [String] = [], width: Int = 220) -> String {
        let chars = Array(text)
        let whole = oneLine(text)
        guard !whole.isEmpty else { return "(no text)" }
        guard whole.count > width, chars.count > width else { return whole }

        let start = bestWindow(in: chars, terms: terms, width: width).start
        let end = min(chars.count, start + width)
        var excerpt = oneLine(String(chars[start..<end]))
        if start > 0 { excerpt = "…" + excerpt }
        if end < chars.count { excerpt += "…" }
        return excerpt
    }

    /// The excerpt to quote for a capture that knows what part of it was on screen.
    ///
    /// A capture holds the whole accessibility tree; `visibleText` holds the part of it that
    /// was inside the window. On a virtualised feed those differ by the four posts scrolled
    /// past above the one being read, and picking between them by "does a term appear in it"
    /// gets the motivating case backwards: "what was that LinkedIn post" matches the word
    /// *LinkedIn* in the navigation of the full text, which would send the citation straight
    /// back to the off-screen half it is supposed to escape.
    ///
    /// So the screen is quoted by default, and only a question specific enough to be clearly
    /// about something else overrules it. Specific means: nothing on screen matched, and the
    /// full text matches at least ``specificQuery`` distinct terms in prose.
    ///
    /// Term coverage decides this and the prose ratio deliberately does not. The ratio is for
    /// choosing a window *within* one text, where it separates content from navigation;
    /// compared *across* two texts it measures writing style. Tried that way first, and the
    /// post being read lost to an advertisement one screen above it, because the post was
    /// mostly bullets and the ad was one flowing paragraph.
    public static func citation(
        text: String, visibleText: String?, matching terms: [String], width: Int = 220
    ) -> String {
        guard let visible = visibleText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !visible.isEmpty
        else { return snippet(text, matching: terms, width: width) }

        let onScreen = bestWindow(in: Array(visible), terms: terms, width: width)
        let whole = bestWindow(in: Array(text), terms: terms, width: width)
        if onScreen.terms < 1.0, whole.terms >= specificQuery {
            return snippet(text, matching: terms, width: width)
        }
        return snippet(visible, matching: terms, width: width)
    }

    /// Distinct prose terms an off-screen window needs before it outranks what was on screen.
    ///
    /// Two, because one is exactly the noise case: a site's own name appears in the navigation
    /// of every page and somewhere in most of its content, so "what was that LinkedIn post"
    /// finds *linkedin* off screen every time. Two independent terms is a question about
    /// something in particular, and that is worth leaving the viewport for.
    private static let specificQuery = 2.0

    /// A line shorter than this is a label, a menu item or a counter rather than something
    /// somebody wrote. Measured against the LinkedIn capture that prompted this: every line
    /// of the navigation block is under 30 characters, every line of a post body is over 60.
    private static let proseLineLength = 50

    /// Weight of the prose signal relative to one distinct term.
    private static let proseWeight = 2.0

    /// What a term match is worth when it lands on a chrome line rather than in prose.
    ///
    /// A quarter, because those matches are real but almost never what was being asked
    /// about: "linkedin", "feed" and "post" all appear in the navigation of every page on
    /// the site, so on full credit a menu covering three query terms (3.0) would outscore
    /// the post the user was reading (1 term + full prose = 3.0) and win the tie by being
    /// earlier. Discounted, the menu scores 0.75 and cannot displace content. A term that
    /// only ever appears in chrome still anchors there, since 0.75 beats nothing.
    private static let chromeTermCredit = 0.25

    /// The offset whose `width`-character window is the most worth showing, and what it scored.
    ///
    /// Candidates are every term occurrence (backed off by a third of the width so the match
    /// is not flush against the edge) plus a coarse stride across the whole text, which is
    /// what gives an unmatched query a content-bearing answer instead of the head. The score
    /// is comparable across different texts, which is what lets ``citation(text:visibleText:matching:width:)``
    /// choose between the whole tree and the part of it that was on screen.
    private static func bestWindow(
        in chars: [Character], terms: [String], width: Int
    ) -> (start: Int, score: Double, terms: Double) {
        let lower = lowercasedAligned(chars)
        let prose = proseMask(chars)

        var occurrences: [[Int]] = []
        var candidates: Set<Int> = []
        for term in terms where !term.isEmpty {
            let hits = positions(of: Array(term.lowercased()), in: lower)
            occurrences.append(hits)
            for hit in hits { candidates.insert(max(0, hit - width / 3)) }
        }
        let lastStart = max(0, chars.count - width)
        for start in stride(from: 0, through: lastStart, by: max(1, width / 2)) {
            candidates.insert(start)
        }
        candidates.insert(lastStart)

        var bestStart = 0
        var bestScore = -1.0
        var bestTerms = 0.0
        for start in candidates.sorted() {
            let end = min(chars.count, start + width)
            let covered = occurrences.reduce(0.0) { total, hits in
                let inWindow = hits.filter { $0 >= start && $0 < end }
                if inWindow.isEmpty { return total }
                return total + (inWindow.contains { prose[$0] } ? 1.0 : chromeTermCredit)
            }
            let proseChars = (start..<end).reduce(0) { $0 + (prose[$1] ? 1 : 0) }
            let ratio = end > start ? Double(proseChars) / Double(end - start) : 0
            let score = covered + proseWeight * ratio
            if score > bestScore {
                bestScore = score
                bestStart = start
                bestTerms = covered
            }
        }
        return (bestStart, max(0, bestScore), bestTerms)
    }

    /// `chars` lowercased with the index alignment preserved.
    ///
    /// Alignment is the whole point: the search runs on this array and the window is cut from
    /// the original, so a character whose lowercase form is more than one character (`İ`) is
    /// left as it was rather than shifting every offset after it.
    private static func lowercasedAligned(_ chars: [Character]) -> [Character] {
        chars.map { character in
            let folded = character.lowercased()
            return folded.count == 1 ? folded.first! : character
        }
    }

    /// For each character, whether it sits on a line long enough to be prose.
    private static func proseMask(_ chars: [Character]) -> [Bool] {
        var mask = [Bool](repeating: false, count: chars.count)
        var lineStart = 0
        var index = 0
        while index <= chars.count {
            if index == chars.count || chars[index].isNewline {
                if index - lineStart >= proseLineLength {
                    for position in lineStart..<index { mask[position] = true }
                }
                lineStart = index + 1
            }
            index += 1
        }
        return mask
    }

    /// Every offset in `haystack` where `needle` starts, capped so a common term in a long
    /// capture cannot make the scoring quadratic.
    private static func positions(of needle: [Character], in haystack: [Character], limit: Int = 64) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var found: [Int] = []
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                found.append(start)
                if found.count >= limit { break }
            }
        }
        return found
    }

    /// Escapes a value so it survives a markdown table cell.
    public static func cell(_ text: String) -> String {
        oneLine(text).replacingOccurrences(of: "|", with: "\\|")
    }

    /// Window titles too generic to name what somebody was doing.
    private static let uninformativeTitles: Set<String> = [
        "", "new tab", "untitled", "login", "loading", "blank", "home", "start page",
        "about:blank", "new window", "menubar", "window", "new chat", "claude", "chatgpt",
    ]

    /// The work named inside an assistant's window title, preferring the project.
    ///
    /// An assistant in a browser puts the whole hierarchy in the title bar:
    ///
    ///     Test question - Claude – Part of group ✅Memoir demo video with Remotion
    ///     Memoir avatar and website design - Google Chrome
    ///
    /// The group is the project and the leading fragment is the conversation, which is
    /// exactly the two things a person means by "what was I working on". The project wins
    /// when both are there, because "an hour on the demo video" is the answer and "an hour
    /// on Test question" is a filename.
    ///
    /// This reads the title only, never the conversation. CF-81 refuses to cite what a
    /// model *said* as evidence of the world, and that stands: a reply that quotes Memoir's
    /// own output back at it must never become a fact. The name the user gave the work they
    /// were doing is not a claim about the world, it is the label on the folder.
    static func assistantWorkspace(_ title: String) -> String? {
        for marker in [" – Part of group ", " - Part of group ", " \u{2014} Part of group "] {
            if let range = title.range(of: marker) {
                let group = title[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if group.count >= 3 { return group }
            }
        }
        for suffix in [" - Claude", " – Claude", " - ChatGPT", " – ChatGPT"] {
            if title.hasSuffix(suffix) {
                let conversation = String(title.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if conversation.count >= 3 { return conversation }
            }
        }
        return nil
    }

    /// A window title reduced to the thing the user would recognise.
    ///
    /// Time that lands under an app name is time Memoir cannot name, and "Claude: 1h 25m"
    /// is the one fact the user already had. The screen itself usually says what the hour
    /// was for; it just says it with the application stapled on the end and an unread count
    /// on the front. Both are chrome, and neither is the work (CF-98).
    ///
    /// Returns nil when the title is only furniture, so the caller can stay honest about
    /// knowing nothing rather than dress a login screen up as a subject.
    public static func screenSubject(_ windowTitle: String?, app: String) -> String? {
        guard var title = windowTitle.map(oneLine) else { return nil }

        // An unread badge, wherever it sits. "(6) Devon Marsh on X: …" is the common shape and
        // was the only one handled; the count also appears mid-string, after a site name or
        // between separators. It changes on every capture, so each value splits one page into
        // another apparent screen — measured on a real vault, one page fragmented into 32
        // separate subjects and its day count with it, which is exactly the signal a
        // returned-to ranking is built on.
        //
        // Only a bare number in brackets. "(2024)" is a year and a legitimate part of a title,
        // so the badge must be short; four digits or more is left alone.
        title = Self.withoutUnreadBadges(title)

        // The application, stapled to the end by the window manager: " - Google Chrome", or
        // an em dash before "Obsidian v1.13.4". Matched on the app's first word so a version
        // suffix does not save it.
        let appHead = app.split(separator: " ").first.map(String.init) ?? app
        for separator in [" - ", " \u{2014} ", " – ", " | "] {
            let parts = title.components(separatedBy: separator)
            guard parts.count > 1, let last = parts.last else { continue }
            if last.localizedCaseInsensitiveContains(appHead) {
                title = parts.dropLast().joined(separator: separator)
            }
        }

        // Browser state, stapled on by the browser and changing while the page does not.
        // "Feed | LinkedIn", "Feed | LinkedIn – Audio playing" and "Feed | LinkedIn - High
        // memory usage - 1.1 GB" are one page and were three subjects, which splits the very
        // count a returned-to ranking rests on. The memory figure carries a number that moves
        // every capture, so a busy tab could become dozens of distinct screens.
        for state in [" – Audio playing", " - Audio playing", " – Audio muted", " - Audio muted"] {
            title = title.replacingOccurrences(of: state, with: "")
        }
        if let range = title.range(of: " - High memory usage", options: .caseInsensitive) {
            title = String(title[title.startIndex..<range.lowerBound])
        }

        // An assistant names the project in its title bar; prefer that over the raw string.
        if let workspace = assistantWorkspace(title) { title = workspace }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uninformativeTitles.contains(title.lowercased()),
              title.count >= 3,
              title.localizedCaseInsensitiveCompare(app) != .orderedSame
        else { return nil }

        // An address is a person, and a subject key is a thing.
        //
        // A mail client puts the account in the window title, so "Posta in arrivo -
        // name@example.com - Gmail" became a row key printed verbatim in an answer — found on
        // a real vault the first time the ranked table was built, which is exactly where an
        // earlier review predicted it would appear. The same shape catches a correspondent's
        // address in a thread title and a shell prompt of the form user@host.
        //
        // Structural rather than a list, because a list of the user's own addresses is a list
        // this product must not hold, and would not catch anybody else's anyway.
        title = withoutAddresses(title)

        // Six words. A window title can be a whole sentence, and a key long enough to be a
        // sentence is long enough to carry a name, a subject line or an argument. It is also
        // the difference between a table and a transcript.
        let words = title.split(separator: " ")
        if words.count > 6 { title = words.prefix(6).joined(separator: " ") + "…" }

        return truncate(title, 70)
    }

    /// Replaces anything shaped like an email address, or a `user@host` prompt, with a
    /// placeholder.
    ///
    /// Deliberately crude and deliberately not a list. The thing being removed is "a token
    /// containing @ with something either side of it", which is what an address looks like
    /// whoever it belongs to. A list of the user's own addresses would be a list this product
    /// has no business holding, and would miss every other person's.
    static func withoutAddresses(_ title: String) -> String {
        title
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> Substring in
                guard let at = token.firstIndex(of: "@"),
                      at != token.startIndex,
                      token.index(after: at) < token.endIndex
                else { return token }
                return "[address]"
            }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -\u{2014}\u{2013}|·"))
    }

    /// Strips bracketed unread counts from anywhere in a window title.
    ///
    /// A badge is a bare number in round brackets of at most three digits, so a year in
    /// brackets survives. Whitespace left behind is collapsed, because "Inbox (12) — Mail"
    /// and "Inbox — Mail" must normalise to the same subject or the page counts twice.
    static func withoutUnreadBadges(_ title: String) -> String {
        var out = ""
        var rest = Substring(title)
        while let open = rest.firstIndex(of: "(") {
            guard let close = rest[open...].firstIndex(of: ")") else { break }
            let inner = rest[rest.index(after: open)..<close]
            let isBadge = !inner.isEmpty && inner.count <= 3 && inner.allSatisfy(\.isNumber)
            out += rest[rest.startIndex..<open]
            if !isBadge { out += rest[open...close] }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        // Collapse the hole the badge left, including a separator now orphaned at either end.
        let collapsed = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " -\u{2014}\u{2013}|·"))
    }

    // MARK: - Parsing

    /// Parses a date boundary supplied by a calling agent.
    ///
    /// Accepted forms:
    /// - `2026-07-30` (bare day; expands to 00:00:00 local, or 23:59:59 when `isEnd`)
    /// - `2026-07-30T14:22:11+02:00`, `...Z`, with or without fractional seconds
    /// - `2026-07-30T14:22` / `2026-07-30 14:22:11` (no offset, read as local time)
    /// - the keywords `now`, `today`, `yesterday`
    public static func parseBoundary(_ raw: String, isEnd: Bool, now: Date = Date()) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        switch text.lowercased() {
        case "now":
            return now
        case "today":
            return isEnd ? endOfDay(now, calendar) : calendar.startOfDay(for: now)
        case "yesterday":
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            return isEnd ? endOfDay(yesterday, calendar) : calendar.startOfDay(for: yesterday)
        default:
            break
        }

        // Bare calendar day.
        if let components = dayComponents(text) {
            var dc = DateComponents()
            dc.year = components.0
            dc.month = components.1
            dc.day = components.2
            dc.hour = isEnd ? 23 : 0
            dc.minute = isEnd ? 59 : 0
            dc.second = isEnd ? 59 : 0
            return calendar.date(from: dc)
        }

        // Full ISO-8601 with a zone designator.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }

        // Zone-less local timestamp.
        if let date = localTimestamp(text, calendar: calendar) { return date }
        return nil
    }

    /// Last instant of the day containing `date`.
    public static func endOfDay(_ date: Date, _ calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    private static func dayComponents(_ text: String) -> (Int, Int, Int)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        return (y, m, d)
    }

    private static func localTimestamp(_ text: String, calendar: Calendar) -> Date? {
        let normalized = text.replacingOccurrences(of: "T", with: " ")
        let halves = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard halves.count == 2, let day = dayComponents(String(halves[0])) else { return nil }
        let timeParts = halves[1].split(separator: ":")
        guard timeParts.count >= 2, let hour = Int(timeParts[0]), let minute = Int(timeParts[1]) else { return nil }
        let second = timeParts.count > 2 ? Int(timeParts[2].prefix(2)) ?? 0 : 0
        var dc = DateComponents()
        dc.year = day.0
        dc.month = day.1
        dc.day = day.2
        dc.hour = hour
        dc.minute = minute
        dc.second = second
        return calendar.date(from: dc)
    }
}
