import Foundation
import MemoirKit

/// Implements the twelve tools: eleven readers and `propose_memory`, which stages
/// to a review file and still never writes the database.
///
/// Every answer is markdown, and every answer carries provenance: which app the text
/// came from and when it was seen. The calling agent can then cite Memoir rather than
/// assert things on its behalf.
public struct ToolHandler: Sendable {

    private let memory: MemoirMemory
    /// Where `propose_memory` stages suggestions. Never the database.
    private let proposalsURL: URL

    public init(memory: MemoirMemory, proposalsURL: URL) {
        self.memory = memory
        self.proposalsURL = proposalsURL
    }

    /// Dispatches a tool call. Never throws: a failure is returned as readable text,
    /// because an agent handles a sentence better than it handles a protocol error.
    ///
    /// The counts come back beside the markdown rather than inside it (CF-93). Every
    /// tool already knows how many rows it found; returning a `String` threw that
    /// away and left a client re-parsing the prose to learn it.
    public func call(name: String, arguments: JSONValue) async -> ToolResult {
        let status = await memory.status()
        guard status.isReady else {
            return .unavailable("""
                Memoir's memory is not available yet.

                Database: `\(status.path)`

                This usually means the Memoir app has not run yet, or has not captured anything. \
                Launch Memoir, grant Accessibility permission, and let it observe for a while.
                """)
        }

        // Scope is settled before any SQL runs.
        //
        // Only the tools that take free text are guarded, because only they can be pointed
        // at something: `today` and `working_set` answer about the record itself and there
        // is nothing in them to refuse. `propose_memory` is a write to a review file and is
        // covered by the user's own accept step.
        //
        // The argument name differs per tool and the guard does not care which one it was:
        // a credential in a `claim` is the same credential as one in a `query`.
        let freeText = ["query", "topic", "claim", "name", "person"]
            .compactMap { arguments[$0]?.stringValue }
        if let refusal = freeText.lazy.compactMap({ ScopeGuard.refusal(for: $0) }).first {
            MCPLog.info("refused \(name): outside what a screen can know")
            return .declined(ScopeGuard.message(refusal), summary: "outside what a screen can know")
        }

        switch name {
        case "recall":              return await recall(arguments)
        case "who_is":              return await whoIs(arguments)
        case "what_happened":       return await whatHappened(arguments)
        case "open_commitments":    return await openCommitments(arguments)
        case "today":               return await today()
        case "what_changed_since":  return await whatChangedSince(arguments)
        case "prior_art":           return await priorArt(arguments)
        case "working_set":         return await workingSet()
        case "sources_for":         return await sourcesFor(arguments)
        case "verify":              return await verify(arguments)
        case "timesheet":           return await timesheet(arguments)
        case "coverage":            return await coverage(arguments)
        case "propose_memory":      return await proposeMemory(arguments)
        default:                    return .declined("Unknown tool: \(name)", summary: "unknown tool")
        }
    }

    // MARK: - recall

    private func recall(_ args: JSONValue) async -> ToolResult {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            return .declined("Missing required argument `query`.", summary: "missing `query`")
        }
        // These three numbers are the ones `ToolCatalog.recall` advertises in its
        // JSON Schema. A calling agent reads that schema and plans against it, so
        // the two must never drift: promising `maximum: 50` and quietly returning
        // 40 makes the catalogue a lie. CF-31 reads the advertised values out of
        // `tools/list` and checks the server actually honours them.
        let bounds = ToolCatalog.RecallLimit.self
        let limit = min(max(args["limit"]?.intValue ?? bounds.fallback, bounds.minimum), bounds.maximum)

        let rawEntities = await memory.searchEntities(query, limit: limit)
        let rawCaptures = await memory.searchCaptures(query, limit: limit)

        // A floor, not a filter (CF-88).
        //
        // Search widens AND to OR so a half-remembered phrase still finds its page, which is
        // exactly right here and must stay. What it also did was return rows sharing nothing
        // with the query but a stopword: "repo about screen memory" came back with an
        // ad-tracker URL and a note about prayer apps, because the OR matched on "about".
        //
        // This is the gentlest floor that fixes it, and deliberately much weaker than the one
        // `verify` and `sources_for` stand on. They require EVERY distinctive word, because
        // they are answering "does the record carry this claim". Recall is answering "what
        // might this be", so one distinctive word in common is enough to stay in. Only rows
        // with none at all are dropped, and those were never matches by any reading.
        // Rarity measured against this corpus, not against English.
        //
        // `distinctiveTerms` drops "the" and keeps everything else, which means a question
        // containing this machine's own wallpaper is steered by the wallpaper. Ordering by
        // document frequency puts the discriminating word first and drops the ones appearing
        // in more than a sixth of every screen the user has ever had open. Degrades to the
        // stopword list when there is no full-text index to ask.
        //
        // `verify` and `sources_for` deliberately keep the old function. They require EVERY
        // distinctive word to be present, so changing which words count changes what they
        // certify, and that is a separate decision with a separate proof.
        let terms = await memory.rankedTerms(in: query)
        func carriesATerm(_ haystack: String) -> Bool {
            guard !terms.isEmpty else { return true }
            let hay = haystack.lowercased()
            return terms.contains { hay.contains($0) }
        }
        // An inferred row's `detail` is Memoir's own sentence about it, not the user's screen.
        //
        // "repo about screen memory" came back with `remotion-dev/skills` at the top, because
        // every repository entity carries the generated detail "Repository style name seen in
        // Google Chrome", so the distinctive term "repo" matched Memoir describing itself,
        // on every repo it had ever seen. The floor was reading the scaffolding it wrote.
        //
        // Authored detail is the opposite: a vault note's body is the user's own words and is
        // exactly what recall should search. So the distinction is provenance, not the field.
        let entities = rawEntities.filter {
            let authoredDetail = $0.source == .authored ? " " + ($0.detail ?? "") : ""
            return carriesATerm($0.title + authoredDetail)
        }
        let captures = rawCaptures.filter { carriesATerm($0.text + " " + ($0.windowTitle ?? "")) }

        guard !entities.isEmpty || !captures.isEmpty else {
            // Distinguish "the query had nothing to search for" from "nothing matched it",
            // the way the evidence tools do. Both are honest; only one is worth rephrasing.
            if !terms.isEmpty, !rawEntities.isEmpty || !rawCaptures.isEmpty {
                return .nothing("""
                    Nothing in Memoir's memory matches "\(query)".

                    Looked for: \(terms.joined(separator: ", ")). There are captures that share \
                    common words with the question, but none that carry any of these.
                    """, summary: "nothing matched")
            }
            return .nothing("Nothing in Memoir's memory matches \"\(query)\".", summary: "nothing matched")
        }

        var out = ["# Recall: \(query)\n"]

        if !entities.isEmpty {
            out.append("## What Memoir knows\n")
            for e in entities {
                out.append(await entityBlock(e))
            }
        }

        if !captures.isEmpty {
            out.append("\n## Where it was seen\n")
            let highlight = terms.isEmpty ? query.split(separator: " ").map(String.init) : terms
            for c in captures {
                let quote = Fmt.citation(text: c.text, visibleText: c.visibleText, matching: highlight)
                out.append("- **\(c.appName)** · \(Fmt.iso(c.ts))\n  > \(quote)")
            }
        }

        let seen = ToolResult.span(captures.map(\.ts))
        return .answered(
            out.joined(separator: "\n"),
            summary: [
                ToolResult.tally([
                    (entities.count, "entity", "entities"),
                    (captures.count, "capture", "captures"),
                ]),
                seen.newest.map { Fmt.relative($0) } ?? "",
            ].filter { !$0.isEmpty }.joined(separator: " · "),
            counts: ["entities": entities.count, "captures": captures.count],
            newest: seen.newest,
            oldest: seen.oldest
        )
    }

    // MARK: - who_is

    private func whoIs(_ args: JSONValue) async -> ToolResult {
        guard let name = args["name"]?.stringValue, !name.isEmpty else {
            return .declined("Missing required argument `name`.", summary: "missing `name`")
        }

        let people = await memory.entities(kind: .person)
            .filter { $0.title.localizedCaseInsensitiveContains(name) }
        let related = await memory.searchEntities(name, limit: 12).filter { $0.kind != .person }
        let mentions = await memory.searchCaptures(name, limit: 10)

        guard !people.isEmpty || !mentions.isEmpty else {
            return .nothing(
                "Memoir has no memory of anyone called \"\(name)\".",
                summary: "nobody by that name"
            )
        }

        // Every person that matches, and the count said out loud.
        //
        // This used to render `people.first` and nothing else. Asking about a common first
        // name returned one record with no hint that two others existed: the real count
        // survived only in a structured field nothing displays. A memory that knows it cannot
        // tell two people apart and answers as though it can is not being brief, it is being
        // wrong — and the reader has no way to notice.
        //
        // The same collision, one layer down, is what let a single-token alias attach any
        // screen containing "marco" to whichever Marco the matcher reached first. That is
        // fixed at the importer now; this is what the tool must say when it happens anyway,
        // because two people really can share a name.
        var out: [String] = []
        if people.count > 1 {
            out.append("# \(name): \(people.count) people\n")
            out.append("""
                **Memoir knows \(people.count) people whose name matches "\(name)" and cannot \
                tell them apart.** Everything below is grouped by record, and a mention may \
                belong to any of them.\n
                """)
        } else {
            out.append("# \(people.first?.title ?? name)\n")
        }

        if people.isEmpty {
            out.append("_No person record; matched on mentions only._\n")
        } else {
            for person in people.prefix(6) {
                out.append(await entityBlock(person))
            }
            if people.count > 6 {
                out.append("_…and \(people.count - 6) more with this name._\n")
            }
        }

        if !related.isEmpty {
            out.append("\n## Related\n")
            for e in related {
                out.append("- [\(e.kind.rawValue)] \(e.title)")
            }
        }

        if !mentions.isEmpty {
            out.append("\n## Recent mentions\n")
            for c in mentions {
                let quote = Fmt.citation(text: c.text, visibleText: c.visibleText, matching: [name])
                out.append("- **\(c.appName)** · \(Fmt.relative(c.ts))\n  > \(quote)")
            }
        }

        let seen = ToolResult.span(mentions.map(\.ts))
        return .answered(
            out.joined(separator: "\n"),
            summary: [
                // `related` is counted but not named: it is the least interesting
                // number here and a chip has room for about four words.
                ToolResult.tally([
                    (people.count, "person", "people"),
                    (mentions.count, "mention", "mentions"),
                ]),
                seen.newest.map { Fmt.relative($0) } ?? "",
            ].filter { !$0.isEmpty }.joined(separator: " · "),
            counts: ["people": people.count, "related": related.count, "mentions": mentions.count],
            newest: seen.newest,
            oldest: seen.oldest
        )
    }

    // MARK: - coverage

    /// How much of a range Memoir was actually running, hour by hour.
    ///
    /// The denominator every other answer needs, and the only thing that separates a quiet
    /// evening from an evening nobody was watching. Those are the same absence in the record
    /// and opposite facts about a life, and until this existed nothing in the product told
    /// them apart.
    ///
    /// Three states per hour, not two. **Active** is Memoir running with somebody at the
    /// machine. **Idle** is Memoir running and watching a screensaver, which is evidence it was
    /// there. **Not running** is no session at all, which is evidence of nothing whatsoever —
    /// the laptop was shut, or the app was not up. Every coverage number this project produced
    /// before collapsed the last two, and that is how "you did nothing on Tuesday" and "I was
    /// not looking on Tuesday" came to read the same.
    private func coverage(_ args: JSONValue) async -> ToolResult {
        let now = Date()
        guard let fromRaw = args["from"]?.stringValue, !fromRaw.isEmpty else {
            return .declined("Missing required argument `from`.", summary: "missing `from`")
        }
        guard let from = Fmt.parseBoundary(fromRaw, isEnd: false, now: now) else {
            return .declined(
                "Could not understand `from`: \"\(fromRaw)\". Try an ISO date like 2026-07-30.",
                summary: "could not read `from`")
        }
        let toRaw = args["to"]?.stringValue ?? "now"
        guard let to = Fmt.parseBoundary(toRaw, isEnd: true, now: now) else {
            return .declined("Could not understand `to`: \"\(toRaw)\".", summary: "could not read `to`")
        }
        guard to > from else {
            return .declined("`to` must be after `from`.", summary: "empty range")
        }

        let sessions = await memory.sessions(from: from, to: to)
        let clipped = WorkSpanBuilder.clip(sessions, from: from, to: to)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        // Seconds per hour-of-day, in each of the three states. Split at hour boundaries so a
        // session spanning midnight is counted in both hours rather than in whichever one it
        // began in.
        var active = [Double](repeating: 0, count: 24)
        var idle = [Double](repeating: 0, count: 24)
        for session in clipped where session.duration > 0 {
            var cursor = session.startedAt
            while cursor < session.endedAt {
                let hour = calendar.component(.hour, from: cursor)
                let nextHour = calendar.date(bySetting: .minute, value: 0, of: cursor)
                    .flatMap { calendar.date(byAdding: .hour, value: 1, to: $0) }
                    .map { calendar.date(bySetting: .second, value: 0, of: $0) ?? $0 }
                    ?? session.endedAt
                let slice = min(nextHour, session.endedAt)
                let seconds = max(0, slice.timeIntervalSince(cursor))
                if session.idle { idle[hour] += seconds } else { active[hour] += seconds }
                cursor = slice > cursor ? slice : session.endedAt
            }
        }

        // Wall-clock seconds available in each hour-of-day across the range, which is the
        // denominator. A four-day range has four of each hour, and a range that starts at noon
        // has fewer of the morning ones — computed rather than assumed, so a partial first or
        // last day cannot inflate a percentage.
        var wall = [Double](repeating: 0, count: 24)
        var cursor = from
        while cursor < to {
            let hour = calendar.component(.hour, from: cursor)
            let nextHour = calendar.date(bySetting: .minute, value: 0, of: cursor)
                .flatMap { calendar.date(byAdding: .hour, value: 1, to: $0) }
                .map { calendar.date(bySetting: .second, value: 0, of: $0) ?? $0 }
                ?? to
            let slice = min(nextHour, to)
            wall[hour] += max(0, slice.timeIntervalSince(cursor))
            cursor = slice > cursor ? slice : to
        }

        let watched = zip(active, idle).map(+).reduce(0, +)
        let total = wall.reduce(0, +)
        let share = total > 0 ? watched / total * 100 : 0

        let activeDays = Set(clipped.filter { $0.duration > 0 }
            .map { calendar.startOfDay(for: $0.startedAt) })
        var calendarDays = 0
        var day = calendar.startOfDay(for: from)
        while day < to { calendarDays += 1; day = calendar.date(byAdding: .day, value: 1, to: day) ?? to }

        var out = ["# Coverage: \(Fmt.day(from)) → \(Fmt.day(to))\n"]
        out.append(
            "Memoir was running for **\(Fmt.duration(watched))** of \(Fmt.duration(total)) — "
            + "**\(String(format: "%.1f", share))%** of the clock. "
            + "\(activeDays.count) of \(calendarDays) days have any recording at all.\n")

        // The hour table. Runs of identical all-zero hours collapse to one line, because
        // sixteen consecutive rows of zeroes is the same fact sixteen times.
        out.append("## By hour of the day\n")
        out.append("| hour | active | idle | not running |")
        out.append("|---|---|---|---|")
        var hour = 0
        while hour < 24 {
            if wall[hour] > 0, active[hour] == 0, idle[hour] == 0 {
                var end = hour
                while end + 1 < 24, wall[end + 1] > 0, active[end + 1] == 0, idle[end + 1] == 0 { end += 1 }
                let label = end > hour
                    ? String(format: "%02d–%02d", hour, end)
                    : String(format: "%02d", hour)
                out.append("| \(label) | — | — | **100%** |")
                hour = end + 1
                continue
            }
            let denom = wall[hour]
            func pct(_ v: Double) -> String {
                guard denom > 0 else { return "—" }
                let p = v / denom * 100
                return p == 0 ? "—" : String(format: "%.0f%%", p)
            }
            let off = denom > 0 ? max(0, denom - active[hour] - idle[hour]) : 0
            out.append(
                "| \(String(format: "%02d", hour)) | \(pct(active[hour])) | \(pct(idle[hour])) "
                + "| \(pct(off)) |")
            hour += 1
        }

        out.append("""

            _Active is Memoir running with somebody at the machine. Idle is Memoir running and \
            watching a screensaver — evidence it was there. Not running is no session at all, \
            which is evidence of nothing: the laptop was shut, or the app was not up. This \
            record cannot tell a machine that was switched off from an app that was never \
            opened._
            """)

        let span = ToolResult.span(clipped.map(\.startedAt) + clipped.map(\.endedAt))
        return .answered(
            out.joined(separator: "\n"),
            summary: "\(String(format: "%.1f", share))% watched · \(activeDays.count)/\(calendarDays) days",
            counts: [
                "watchedSeconds": Int(watched),
                "wallSeconds": Int(total),
                "activeDays": activeDays.count,
                "calendarDays": calendarDays,
            ],
            newest: span.newest,
            oldest: span.oldest
        )
    }

    // MARK: - what_happened

    private func whatHappened(_ args: JSONValue) async -> ToolResult {
        let now = Date()
        let fromRaw = args["from"]?.stringValue ?? "today"
        let toRaw = args["to"]?.stringValue ?? "now"

        guard let from = Fmt.parseBoundary(fromRaw, isEnd: false, now: now) else {
            return .declined(
                "Could not understand `from`: \"\(fromRaw)\". Try an ISO date like 2026-07-30, or `today` / `yesterday`.",
                summary: "could not read `from`"
            )
        }
        guard let to = Fmt.parseBoundary(toRaw, isEnd: true, now: now) else {
            return .declined("Could not understand `to`: \"\(toRaw)\".", summary: "could not read `to`")
        }

        let sessions = await memory.sessions(from: from, to: to)
        let entities = await memory.entitiesTouched(from: from, to: to)

        // Imported history, which is most of what a life is and none of what a session knows.
        //
        // Sessions begin the day Memoir was installed. Everything before that — the photo
        // library above all — arrives through the importers, dated by the day it *happened*
        // rather than the day it was read. Asking this tool about July 2019 used to return
        // "Nothing recorded" against a month with 27 days of photographs in it, because the
        // only two things it consulted were sessions and entities and neither reaches back.
        let imported = await memory.importedCaptures(from: from, to: to)

        // What the user wrote about these days. Everything else this tool returns is something
        // Memoir inferred off a screen; this is the only part that is the person's own sentence
        // about their own day, and it goes first for that reason.
        //
        // It used to go nowhere. Journal entries reached this answer only through the "New in
        // this window" list, sorted by `updated_at` against every other entity and capped at
        // eight — and measured on the real vault the six entries ranked 20th, 149th, 15th,
        // 53rd, 42nd and 97th inside their own days. None of the user's own words had ever
        // appeared in an answer about the day they were written.
        let written = await memory.journalEntries(from: from, to: to)

        guard !sessions.isEmpty || !entities.isEmpty || !imported.isEmpty || !written.isEmpty else {
            return .nothing(
                "Nothing recorded between \(Fmt.day(from)) and \(Fmt.day(to)).",
                summary: "nothing in range"
            )
        }

        // A day the record knows about, and how much is in it. Grouped by the stored date
        // where there is one, so the answer does not change with the reader's timezone.
        let importedByDay: [String: [CaptureEvent]] = Dictionary(
            grouping: imported,
            by: { $0.localDay ?? Fmt.isoDay($0.ts) }
        )
        let photoDays = importedByDay.filter { _, rows in
            rows.contains { $0.appBundleID == PhotoImporter.bundleID }
        }
        let photographs = imported
            .filter { $0.appBundleID == PhotoImporter.bundleID }
            .compactMap { PhotoImporter.DayInPlace.photoCount(in: $0.text) }
            .reduce(0, +)

        // Name the WORK, not the window it happened in (CF-95).
        //
        // "You spent 1h 25m in Claude" is a measurement, not an answer: the user knows
        // which app they had open. What they cannot reconstruct is what the hour was FOR.
        // The machinery to say so already existed and this tool was not using it: the
        // timesheet has attributed time to projects through the ontology since CF-76, while
        // this aggregated raw `session.appName` and could never say more than the app.
        //
        // Unlabelled time still degrades to its app name and is never guessed into a
        // project. That is the timesheet's rule, and the reason its totals can be trusted.
        let clipped = WorkSpanBuilder.clip(sessions, from: from, to: to)
        let labelCaptures = await memory.captures(
            from: from.addingTimeInterval(-WorkSpanBuilder.defaultCarryForward), to: to, limit: 4_000
        )
        let ontology = Ontology.build(from: await memory.allEntities())
        let spans = WorkSpanBuilder.spans(sessions: clipped, captures: labelCaptures, ontology: ontology)

        // What was actually on the screen during the time nothing could name (CF-98).
        //
        // A span's label is either a project from the ontology or, failing that, the app.
        // The app is the one thing the user already knew. The screen itself usually says
        // what the hour was for, and the span already carries the captures it was cut at, so
        // this reads the subject off the dominant window title rather than inventing one.
        //
        // Deliberately NOT used as the span's label: `WorkSpanBuilder` drops spans under a
        // minute, so splitting one app's hour into nine window titles would delete the short
        // ones and the timesheet's totals would quietly shrink. CF-76 is arithmetic with
        // receipts; this is a caption, not a re-attribution.
        // How long each subject was on screen, not merely how often it was captured.
        //
        // Counting captures answers "which page did I photograph most", which is a different
        // question and gives a page left open in a background tab the same weight as an hour
        // of work. Each capture owns the time until the next one on the same app, the way
        // WorkSpanBuilder cuts sessions. It is capped, so a screen left up over lunch does
        // not bill the lunch.
        let inWindow = labelCaptures.filter { $0.ts >= from && $0.ts <= to }.sorted { $0.ts < $1.ts }

        // Subjects that interrupt rather than get visited.
        //
        // A dialog, a permission prompt, a sign-in sheet, a "this extension is disabled"
        // banner: you did not go there, it arrived, and then you went back to what you were
        // doing. That last clause is the whole signal, and it is structural to what an
        // interruption IS. Measured: the screen either side of such a subject is the SAME
        // screen 45 to 75 per cent of the time, against a corpus base rate of 4.8 per cent.
        //
        // Two earlier filters were built for this and both had to be thrown away, because
        // they keyed on how long a screen was held or how often it repeated — and a
        // four-second glance at something private and a pass-through dialog are the same
        // behavioural event under either. Bracketing is not: on the same vault the wedding
        // venues score 0%, the job board 0%, the gym 3%, the anime 1%, the feed 1%.
        //
        // Six sightings minimum. At a base rate of 4.8% a subject bracketed three times in six
        // is far past coincidence, and below that a run of luck reads as a certainty — an
        // earlier cut at four sightings suppressed a job listing seen four times, twice.
        let interrupting: Set<String> = {
            var bracketed: [String: Int] = [:], seen: [String: Int] = [:]
            let byApp = Dictionary(grouping: inWindow, by: { $0.appBundleID })
            for (_, captures) in byApp {
                let subjects = captures.map { Fmt.screenSubject($0.windowTitle, app: $0.appName) }
                for i in 1..<max(1, captures.count - 1) {
                    guard let here = subjects[i], let before = subjects[i - 1], let after = subjects[i + 1]
                    else { continue }
                    // Inside ten minutes either side, or it is a new sitting rather than a
                    // return to what was interrupted.
                    guard captures[i].ts.timeIntervalSince(captures[i - 1].ts) <= 600,
                          captures[i + 1].ts.timeIntervalSince(captures[i].ts) <= 600
                    else { continue }
                    seen[here, default: 0] += 1
                    if before == after, before != here { bracketed[here, default: 0] += 1 }
                }
            }
            return Set(seen.compactMap { subject, count in
                count >= 6 && Double(bracketed[subject] ?? 0) / Double(count) >= 0.5 ? subject : nil
            })
        }()

        // Names of people, taken out of subjects before any of them is printed.
        //
        // A mail client and a messenger put the correspondent in the window title, so the
        // subject of a screen becomes the name of whoever wrote to you. The six-word cap and
        // the address rule do not touch it: "Ingrid Halvorsen - Outlook" is four words and no @.
        //
        // Nothing had to be inferred to fix this. Memoir already holds the people — 191 of
        // them imported from the address book — and no reader had ever thought to check a
        // subject against them. Full names only, two tokens or more: a bare first name is a
        // name for everyone who has it, and redacting on one would hollow out ordinary titles.
        let peopleNames: [String] = await memory.entities(kind: .person)
            .map(\.title)
            .filter { $0.split(whereSeparator: \.isWhitespace).count >= 2 && $0.count >= 6 }
        func withoutPeople(_ subject: String) -> String {
            var out = subject
            for name in peopleNames {
                guard let range = out.range(of: name, options: .caseInsensitive) else { continue }
                out.replaceSubrange(range, with: "[someone]")
            }
            return out
        }

        func subjectBreakdown(
            apps: Set<String>, measured: TimeInterval, limit: Int = 3
        ) -> [(subject: String, seconds: TimeInterval)] {
            let mine = inWindow.filter { apps.contains($0.appName) }
            guard !mine.isEmpty, measured > 0 else { return [] }
            var weights: [String: TimeInterval] = [:]
            for (index, capture) in mine.enumerated() {
                guard let raw = Fmt.screenSubject(capture.windowTitle, app: capture.appName),
                      !interrupting.contains(raw)
                else { continue }
                let subject = withoutPeople(raw)
                let next = index + 1 < mine.count ? mine[index + 1].ts : to
                // Capped, so a screen left up over lunch does not bill the lunch.
                weights[subject, default: 0] += max(min(next.timeIntervalSince(capture.ts), 10 * 60), 0)
            }
            let totalWeight = weights.values.reduce(0, +)
            guard totalWeight > 0 else { return [] }

            // Scaled onto the measured total, never added to it.
            //
            // These weights come from capture spacing, which does not agree with the session
            // clock. Capture only ever runs on the frontmost app, so the gap between two of
            // an app's captures is not time spent in it: it is every stretch spent
            // somewhere else, in between. Billing that gap to the earlier capture invents
            // time, and the 10-minute cap bounds the invention without removing it: on a
            // real day a row measured at 11m had subjects summing to 57m.
            //
            // Published side by side, the smaller number reads as the wrong one. The split
            // is a proportion of time nobody disputes: CF-76's totals are the arithmetic,
            // and this is only a description of how they were spent.
            return weights
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { (subject: $0.key, seconds: measured * ($0.value / totalWeight)) }
                .filter { $0.seconds >= 30 }
        }

        var appsByLabel: [String: Set<String>] = [:]
        for span in spans {
            appsByLabel[span.label, default: []].formUnion(span.apps)
        }

        var perLabel: [String: (seconds: TimeInterval, named: Bool)] = [:]
        for span in spans {
            let existing = perLabel[span.label] ?? (0, span.entityID != nil)
            perLabel[span.label] = (existing.seconds + span.seconds, existing.named || span.entityID != nil)
        }
        let total = perLabel.values.reduce(0) { $0 + $1.seconds }
        let ranked = perLabel.sorted { $0.value.seconds > $1.value.seconds }

        // Lead with the answer, then the evidence (CF-92).
        //
        // This opened with a heading, a total, twelve app rows and twenty-five note titles:
        // about forty lines with the answer nowhere in them, leaving the caller to work out
        // what the week was about from a spreadsheet. `verify` has had the right shape all
        // along: a verdict first, quotes underneath. This is that shape.
        var out: [String] = []
        if let top = ranked.first, total > 0 {
            let share = Int((top.value.seconds / total) * 100)
            let second = ranked.dropFirst().first
            let alongside = second.map { ", then \($0.key) \(Fmt.duration($0.value.seconds))" } ?? ""
            out.append(
                "\(Fmt.day(from)) → \(Fmt.day(to)): **\(Fmt.duration(total))** active, "
                    + "mostly **\(top.key)** (\(Fmt.duration(top.value.seconds)), \(share)%)\(alongside).\n"
            )
        } else {
            out.append("\(Fmt.day(from)) → \(Fmt.day(to)): no measured activity on record.\n")
        }

        // The user's own words, verbatim, before anything Memoir worked out for itself.
        //
        // Verbatim on purpose: this is the one thing in the answer that is not a reconstruction,
        // and paraphrasing it would put Memoir's voice over the only sentence in the memory that
        // is already the user's. Dated by the day it was filed under, and marked when it was
        // typed later, because writing about Tuesday on a Sunday is a different act from writing
        // on the night.
        if !written.isEmpty {
            out.append("## What you wrote\n")
            for entry in written {
                let day = entry.filedAt.map { Fmt.day($0) } ?? Fmt.day(entry.createdAt)
                let calendar = Calendar.current
                let late = entry.filedAt.map { !calendar.isDate($0, inSameDayAs: entry.createdAt) } ?? false
                let note = late ? " _(written \(Fmt.day(entry.createdAt)))_" : ""
                out.append("- **\(day)**\(note)\n  > \(Fmt.oneLine(entry.title))")
            }
            out.append("")
        }

        if total > 0 {
            out.append("## What the time went on\n")
            for (label, entry) in ranked.prefix(12) {
                let pct = Int((entry.seconds / total) * 100)
                // Say which rows are real work and which are only an app with nothing
                // known about what was done in it. A reader can then tell a thin answer
                // from a busy day, instead of both looking the same. Where the app is
                // all Memoir has, name the screen the time was spent on, which is the
                // difference between "Claude, 1h 25m" and an answer.
                var suffix = ""
                if !entry.named {
                    suffix = " · _unlabelled_"
                    let subjects = subjectBreakdown(apps: appsByLabel[label] ?? [], measured: entry.seconds)
                    if !subjects.isEmpty {
                        let named = subjects
                            .map { "\(Fmt.cell($0.subject)) (\(Fmt.duration($0.seconds)))" }
                            .joined(separator: ", ")
                        suffix += ": \(named)"
                    }
                }
                out.append("- \(Fmt.cell(label)) \(Fmt.duration(entry.seconds)) · \(pct)%\(suffix)")
            }
        }

        // Only what actually moved in the window, and only a few of them.
        //
        // "What came up" listed every entity the window touched, which on a machine with an
        // imported vault is the vault: `today`, `working_set`, `what_changed_since` and this
        // tool all answered different questions with the same fifteen note titles. A list
        // that is identical whatever you asked is not an answer to any of it.
        // Created in the window, not merely updated in it.
        //
        // The first cut of this filter accepted `updatedAt >= from` too, and on a real
        // database it removed nothing: re-observing a row raises its confidence, and a
        // raised confidence is a change, so `updatedAt` means LAST SEEN and not last
        // changed. Every one of 675 vault notes qualified. The prose capped at eight and
        // looked fixed; the count that CF-93 now returns beside it said 675 and did not.
        //
        // There is no honest signal for "genuinely revised", so this does not claim one.
        let changed = entities.filter { $0.createdAt >= from }
        if !changed.isEmpty {
            out.append("\n## New in this window\n")
            for e in changed.prefix(8) {
                out.append("- [\(e.kind.rawValue)] \(e.title)")
            }
            if changed.count > 8 {
                out.append("- _…and \(changed.count - 8) more_")
            }
        }

        // What the record holds from before capture, and from off the screen entirely.
        //
        // Deliberately counts and dates only: how many days, how much on each. Not what any
        // of it was about. A photo row's text is "6 photos · 41.3800, 2.1700" and the memory
        // has no business turning that into a claim about the afternoon — it did not see the
        // afternoon, it saw that a camera was used. Days and counts are what the evidence
        // supports, and they are enough to answer "was there anything at all".
        if !importedByDay.isEmpty {
            out.append("\n## Also on the record\n")
            if !photoDays.isEmpty {
                let dayWord = photoDays.count == 1 ? "day" : "days"
                let shotWord = photographs == 1 ? "photograph" : "photographs"
                out.append(
                    "- **Photographs**: \(photoDays.count) \(dayWord)"
                    + (photographs > 0 ? ", \(photographs) \(shotWord)" : ""))
            }
            for (bundle, label) in [
                (LifeImporter.calendarBundleID, "Calendar"),
                (VaultImporter.bundleID, "Notes"),
                (LifeImporter.contactsBundleID, "Contacts"),
            ] {
                let rows = imported.filter { $0.appBundleID == bundle }
                guard !rows.isEmpty else { continue }
                let days = Set(rows.map { $0.localDay ?? Fmt.isoDay($0.ts) }).count
                out.append("- **\(label)**: \(rows.count) row\(rows.count == 1 ? "" : "s") across \(days) day\(days == 1 ? "" : "s")")
            }
            out.append("\n_Dated by the day they belong to, not the day Memoir read them._")
        }

        // Idle is left out of the counts for the same reason it is left out of the
        // total: a screen saver is not a session anybody worked in, and a chip saying
        // "3 sessions" over two working ones is the same overstatement in fewer words.
        // The span is the sessions', not the asked-for range: an answer is only as
        // fresh as the rows behind it, and a caller may ask about any window it likes.
        let active = sessions.filter { !$0.idle }
        let worked = ToolResult.span(active.map(\.startedAt) + active.map(\.endedAt))
        let namedWork = perLabel.values.filter(\.named).count
        let counted = ToolResult.tally([
            (namedWork, "project", "projects"),
            (active.count, "session", "sessions"),
            (changed.count, "entity", "entities"),
            (photoDays.count, "photo day", "photo days"),
            (written.count, "entry you wrote", "entries you wrote"),
        ])
        // A window with nothing but imported history is not "no measured activity": there was
        // no screen to measure, and saying so as if it were a quiet day is the overstatement
        // this tool exists to avoid.
        let headline = total > 0
            ? "\(Fmt.duration(total)) active"
            : (importedByDay.isEmpty ? "no measured activity" : "nothing captured, imported history only")
        var tallies = ["projects": namedWork, "sessions": active.count, "entities": changed.count]
        tallies["photoDays"] = photoDays.count
        tallies["photographs"] = photographs
        tallies["written"] = written.count
        // The span covers what was found, including days that predate capture entirely.
        let importedSpan = ToolResult.span(imported.map(\.ts))
        return .answered(
            out.joined(separator: "\n"),
            summary: counted.isEmpty ? headline : "\(headline) · \(counted)",
            counts: tallies,
            newest: [worked.newest, importedSpan.newest].compactMap { $0 }.max(),
            oldest: [worked.oldest, importedSpan.oldest].compactMap { $0 }.min()
        )
    }

    // MARK: - open_commitments

    private func openCommitments(_ args: JSONValue) async -> ToolResult {
        let now = Date()
        let person = args["person"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        // "Open" excludes completed rows: a done todo listed as open is the tool lying.
        var commitments = await memory.entities(kind: .commitment)
            // Provisional rows were read off a page, not written by the user. An agent
            // told they are open promises would act on somebody else's sentence.
            .filter { $0.completedAt == nil && !$0.provisional }
            .sorted { a, b in
                switch (a.dueAt, b.dueAt) {
                case let (x?, y?): return x < y
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return a.updatedAt > b.updatedAt
                }
            }

        // "What did I tell Marco" is the question people actually ask, and the whole list
        // was the only answer available (CF-91).
        //
        // Matched against the captures behind a commitment as well as its own words,
        // because the name is usually in the conversation and not in the sentence: "I'll
        // get the invoice over to you this week" never says Marco, and the WhatsApp thread
        // it was typed into says nothing else.
        if let person, !person.isEmpty {
            var kept: [Entity] = []
            for e in commitments {
                if e.title.localizedCaseInsensitiveContains(person)
                    || (e.detail?.localizedCaseInsensitiveContains(person) ?? false) {
                    kept.append(e)
                    continue
                }
                let rows = await memory.provenance(entityID: e.id, limit: 8)
                let captures = await memory.captures(ids: rows.map(\.captureID))
                let mentioned = rows.contains { row in
                    if row.snippet.localizedCaseInsensitiveContains(person) { return true }
                    guard let c = captures[row.captureID] else { return false }
                    return c.text.localizedCaseInsensitiveContains(person)
                        || (c.windowTitle?.localizedCaseInsensitiveContains(person) ?? false)
                }
                if mentioned { kept.append(e) }
            }
            commitments = kept
        }

        guard !commitments.isEmpty else {
            if let person, !person.isEmpty {
                return .nothing("""
                    No open commitments involving "\(person)" in Memoir's memory.

                    Absence here is not proof none were made: a promise Memoir never saw on \
                    screen was never recorded.
                    """, summary: "none involving \(person)")
            }
            return .nothing("No open commitments in Memoir's memory.", summary: "none open")
        }

        let overdue = commitments.filter { ($0.dueAt ?? .distantFuture) < now }
        let upcoming = commitments.filter { ($0.dueAt ?? .distantFuture) >= now && $0.dueAt != nil }
        let undated = commitments.filter { $0.dueAt == nil }

        let heading = person.map { "# Open commitments involving \($0)\n" } ?? "# Open commitments\n"
        var out = [heading]

        if !overdue.isEmpty {
            out.append("## Overdue (\(overdue.count))\n")
            for e in overdue { out.append(commitmentLine(e, now: now)) }
        }
        if !upcoming.isEmpty {
            out.append("\n## Coming up\n")
            for e in upcoming { out.append(commitmentLine(e, now: now)) }
        }
        if !undated.isEmpty {
            out.append("\n## No date\n")
            for e in undated.prefix(20) { out.append(commitmentLine(e, now: now)) }
        }

        // Overdue leads the summary for the same reason it leads the markdown: it is
        // the only part of this answer anyone acts on today.
        let counted = ToolResult.tally([
            (overdue.count, "overdue", "overdue"),
            (upcoming.count, "due", "due"),
            (undated.count, "undated", "undated"),
        ])
        return .answered(
            out.joined(separator: "\n"),
            summary: "\(ToolResult.tally([(commitments.count, "commitment", "commitments")])) · \(counted)",
            counts: [
                "commitments": commitments.count,
                "overdue": overdue.count,
                "upcoming": upcoming.count,
                "undated": undated.count,
            ]
        )
    }

    // MARK: - today

    private func today() async -> ToolResult {
        let now = Date()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)

        let sessions = await memory.sessions(from: start, to: now)
        let entities = await memory.entitiesTouched(from: start, to: now)
        let captures = await memory.recentCaptures(limit: 5)

        var out = ["# Today: \(Fmt.day(now))\n"]

        var perApp: [String: TimeInterval] = [:]
        for s in sessions where !s.idle {
            perApp[s.appName, default: 0] += s.duration
        }
        let total = perApp.values.reduce(0, +)

        if total > 0 {
            out.append("**Active \(Fmt.duration(total))** across \(perApp.count) app\(perApp.count == 1 ? "" : "s")\n")
            for (app, seconds) in perApp.sorted(by: { $0.value > $1.value }).prefix(8) {
                out.append("- \(Fmt.cell(app)) \(Fmt.duration(seconds))")
            }
        } else {
            out.append("_No activity recorded yet today._")
        }

        let due = await memory.entities(kind: .commitment).filter { e in
            guard !e.provisional else { return false }
            guard e.completedAt == nil, let d = e.dueAt else { return false }
            return d <= calendar.date(byAdding: .day, value: 1, to: start) ?? now
        }
        if !due.isEmpty {
            out.append("\n## Due today or overdue\n")
            for e in due { out.append(commitmentLine(e, now: now)) }
        }

        // Created today, not merely touched today (CF-92). An imported vault is "touched"
        // every time anything reads it, which is how fifteen note titles came to be the
        // headline of a 22-minute day.
        let newToday = entities.filter { $0.createdAt >= start }
        if !newToday.isEmpty {
            out.append("\n## New in memory today\n")
            for e in newToday.prefix(8) {
                out.append("- [\(e.kind.rawValue)] \(e.title)")
            }
            if newToday.count > 8 {
                out.append("- _…and \(newToday.count - 8) more_")
            }
        }

        if !captures.isEmpty {
            out.append("\n## Most recently seen\n")
            for c in captures {
                out.append("- **\(c.appName)** · \(Fmt.clock(c.ts)) · \(Fmt.oneLine(Fmt.truncate(c.text, 140)))")
            }
        }

        let seen = ToolResult.span(captures.map(\.ts))
        let counted = ToolResult.tally([
            (perApp.count, "app", "apps"),
            (due.count, "due", "due"),
            (newToday.count, "new", "new"),
        ])
        let headline = total > 0 ? "Active \(Fmt.duration(total))" : "nothing recorded yet"
        return .answered(
            out.joined(separator: "\n"),
            summary: counted.isEmpty ? headline : "\(headline) · \(counted)",
            counts: ["apps": perApp.count, "due": due.count, "new": newToday.count],
            newest: seen.newest,
            oldest: seen.oldest
        )
    }

    // MARK: - what_changed_since

    private func whatChangedSince(_ args: JSONValue) async -> ToolResult {
        let now = Date()
        guard let raw = args["since"]?.stringValue,
              let since = Fmt.parseBoundary(raw, isEnd: false, now: now) else {
            return .declined(
                "Could not understand `since`: \"\(args["since"]?.stringValue ?? "")\". Try an ISO date like 2026-08-05, or `yesterday`.",
                summary: "could not read `since`"
            )
        }

        let touched = await memory.entitiesTouched(from: since, to: now)
        let created = touched.filter { $0.createdAt >= since }
        let updated = touched.filter { $0.createdAt < since }
        let sessions = await memory.sessions(from: since, to: now)

        guard !touched.isEmpty || !sessions.isEmpty else {
            return .nothing("Nothing recorded since \(Fmt.iso(since)).", summary: "nothing changed")
        }

        var out = ["# Since \(Fmt.iso(since))\n"]

        var perApp: [String: TimeInterval] = [:]
        for s in sessions where !s.idle { perApp[s.appName, default: 0] += s.duration }
        let total = perApp.values.reduce(0, +)
        if total > 0 {
            let top = perApp.sorted { $0.value > $1.value }.prefix(5)
                .map { "\($0.key) \(Fmt.duration($0.value))" }
                .joined(separator: " · ")
            out.append("**Active \(Fmt.duration(total))**: \(top)\n")
        }

        if !created.isEmpty {
            out.append("## New in memory\n")
            for e in created.prefix(15) {
                let mark = e.source == .authored ? " _(authored)_" : ""
                out.append("- [\(e.kind.rawValue)] \(e.title)\(mark)")
            }
        }
        if !updated.isEmpty {
            out.append("\n## Updated\n")
            for e in updated.prefix(15) {
                out.append("- [\(e.kind.rawValue)] \(e.title)")
            }
        }

        let moved = ToolResult.span(touched.map(\.updatedAt) + touched.map(\.createdAt))
        let counted = ToolResult.tally([
            (created.count, "new", "new"),
            (updated.count, "updated", "updated"),
            (perApp.count, "app", "apps"),
        ])
        return .answered(
            out.joined(separator: "\n"),
            summary: total > 0 ? "\(counted) · \(Fmt.duration(total)) active" : counted,
            counts: ["created": created.count, "updated": updated.count, "apps": perApp.count],
            newest: moved.newest,
            oldest: moved.oldest
        )
    }

    // MARK: - prior_art

    private func priorArt(_ args: JSONValue) async -> ToolResult {
        guard let topic = args["topic"]?.stringValue, !topic.isEmpty else {
            return .declined("Missing required argument `topic`.", summary: "missing `topic`")
        }
        let captures = await memory.searchCaptures(topic, limit: 40).sorted { $0.ts < $1.ts }
        let entities = await memory.searchEntities(topic, limit: 8)

        guard !captures.isEmpty || !entities.isEmpty else {
            return .nothing("""
                No history of "\(topic)" in the record. Within the retention window of raw \
                captures, this appears to be new ground.
                """, summary: "new ground")
        }

        var out = ["# Prior art: \(topic)\n"]

        if let first = captures.first, let last = captures.last {
            let firstDays = Int(Date().timeIntervalSince(first.ts) / 86_400)
            out.append("First seen **\(Fmt.day(first.ts))** (\(firstDays) day\(firstDays == 1 ? "" : "s") ago), last touched **\(Fmt.relative(last.ts))**.\n")
        }

        if !entities.isEmpty {
            out.append("## In memory\n")
            for e in entities {
                let mark = e.source == .authored ? " _(authored)_" : ""
                out.append("- [\(e.kind.rawValue)] \(e.title)\(mark)")
            }
            out.append("")
        }

        if !captures.isEmpty {
            out.append("## Timeline\n")
            let calendar = Calendar.current
            var byDay: [Date: [CaptureEvent]] = [:]
            for c in captures { byDay[calendar.startOfDay(for: c.ts), default: []].append(c) }
            let terms = topic.split(separator: " ").map(String.init)
            for (day, hits) in byDay.sorted(by: { $0.key < $1.key }).suffix(10) {
                let apps = Array(Set(hits.map(\.appName))).sorted().joined(separator: ", ")
                // The screen, not the whole tree. `prior_art` is what an agent calls to
                // decide whether the user has been here before, so a sample drawn from the
                // off-screen half answers that question with something they never read.
                let sample = Fmt.citation(
                    text: hits[0].text, visibleText: hits[0].visibleText, matching: terms)
                out.append("- **\(Fmt.day(day))**: \(hits.count) sighting\(hits.count == 1 ? "" : "s") · \(apps)\n  > \(sample)")
            }
        }

        // Captures arrive sorted oldest first here, so the span is the history this
        // tool exists to date: first sighting to last.
        let days = Set(captures.map { Fmt.calendar.startOfDay(for: $0.ts) }).count
        let counted = ToolResult.tally([
            (captures.count, "sighting", "sightings"),
            (days, "day", "days"),
            (entities.count, "entity", "entities"),
        ])
        return .answered(
            out.joined(separator: "\n"),
            summary: [counted, captures.last.map { "last \(Fmt.relative($0.ts))" } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · "),
            counts: ["sightings": captures.count, "days": days, "entities": entities.count],
            newest: captures.last?.ts,
            oldest: captures.first?.ts
        )
    }

    // MARK: - working_set

    private func workingSet() async -> ToolResult {
        let now = Date()
        let hourAgo = now.addingTimeInterval(-3_600)
        let recent = await memory.captures(from: hourAgo, to: now, limit: 300)
        let sessions = await memory.sessions(from: hourAgo, to: now)
        let all = await memory.allEntities()

        var out = ["# Working set at \(Fmt.clock(now))\n"]

        let ontology = Ontology.build(from: all)
        let spans = WorkSpanBuilder.spans(sessions: sessions, captures: recent, ontology: ontology)
        if !spans.isEmpty {
            out.append("## In play (last hour)\n")
            for span in spans.suffix(6).reversed() {
                let name = span.entityID != nil ? "**\(span.label)**" : span.label
                let apps = WorkSpanBuilder.appsWorthNaming(span)
                let where_ = apps.isEmpty ? "" : " · " + apps.joined(separator: ", ")
                out.append("- \(name) · \(Fmt.duration(span.seconds))\(where_) · until \(Fmt.clock(span.end))")
            }
            out.append("")
        }

        var seenTitles = Set<String>()
        var windows: [String] = []
        for c in recent.sorted(by: { $0.ts > $1.ts }) {
            guard let title = c.windowTitle, !title.isEmpty,
                  seenTitles.insert(title.lowercased()).inserted else { continue }
            // A window titled after its own app ("Claude" in Claude) says nothing twice.
            let app = title.lowercased() == c.appName.lowercased() ? "" : " · \(c.appName)"
            windows.append("- \(Fmt.cell(title))\(app) · \(Fmt.clock(c.ts))")
            if windows.count >= 10 { break }
        }
        if !windows.isEmpty {
            out.append("## On screen\n")
            out.append(contentsOf: windows)
            out.append("")
        }

        let dayStart = Calendar.current.startOfDay(for: now)
        let surfaced = await memory.entitiesTouched(from: dayStart, to: now)
        if !surfaced.isEmpty {
            out.append("## Surfaced today\n")
            for e in surfaced.prefix(10) {
                out.append("- [\(e.kind.rawValue)] \(e.title)")
            }
        }

        // The freshest thing the answer rests on, whichever section supplied it: the
        // chip's job is to say how stale this context is before an agent leans on it.
        var newestSeen = recent.map(\.ts).max()
        var recentShown = 0

        if spans.isEmpty && windows.isEmpty && surfaced.isEmpty {
            // Over-fetch, then keep only distinct things.
            //
            // A browser left open on one page produces a capture a minute, so the five most
            // recent were five copies of the same tab: an agent loading context learned one
            // thing and paid for five. The rest of this tool already dedupes by window
            // title; the fallback was the one path that did not.
            let fallback = await memory.recentCaptures(limit: 60)
            guard !fallback.isEmpty else {
                return .nothing("Nothing recorded recently.", summary: "nothing recent")
            }
            var seen = Set<String>()
            var lines: [String] = []
            for c in fallback {
                // Same app, same opening words: the trailing chrome differs, the page does not.
                let head = Fmt.oneLine(c.text).lowercased().prefix(80)
                guard seen.insert(c.appBundleID + "|" + head).inserted else { continue }
                lines.append("- **\(c.appName)** · \(Fmt.relative(c.ts)) · \(Fmt.oneLine(Fmt.truncate(c.text, 120)))")
                if lines.count >= 5 { break }
            }
            out.append("Nothing in the last hour. Most recent activity:\n")
            out.append(contentsOf: lines)
            newestSeen = fallback.map(\.ts).max()
            recentShown = lines.count
        }

        let counted = ToolResult.tally([
            (spans.count, "in play", "in play"),
            (windows.count, "window", "windows"),
            (surfaced.count, "surfaced", "surfaced"),
            (recentShown, "recent", "recent"),
        ])
        return .answered(
            out.joined(separator: "\n"),
            summary: [counted, newestSeen.map { Fmt.relative($0) } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · "),
            counts: [
                "spans": spans.count,
                "windows": windows.count,
                "surfaced": surfaced.count,
                "recent": recentShown,
            ],
            newest: newestSeen
        )
    }

    // MARK: - sources_for

    private func sourcesFor(_ args: JSONValue) async -> ToolResult {
        guard let claim = args["claim"]?.stringValue, !claim.isEmpty else {
            return .declined("Missing required argument `claim`.", summary: "missing `claim`")
        }

        // The same floor `verify` stands on, for the same reason (CF-80, CF-86).
        //
        // This tool asked `searchCaptures` for the claim and quoted whatever came back.
        // Search widens AND to OR so a half-remembered phrase still finds its page, and
        // when nothing matched at all the widened query fell through to recency: a claim
        // about the MCP server was answered with a Gmail inbox, a permission dialog and a
        // WhatsApp advert for a villa, each carrying an app name and a timestamp. The
        // skill file tells agents to cite this rather than assert, so they cited it.
        //
        // Quoting the wrong capture is worse than quoting none: an empty answer is read as
        // "nothing on record", a furnished one as "here is your evidence".
        let terms = MemoirMemory.distinctiveTerms(in: claim)
        guard !terms.isEmpty else {
            return .declined("""
                **Cannot source.** "\(claim)" carries no distinctive words to look for: \
                every word in it is common enough to appear in almost any capture.

                Ask about the specific thing: a name, a version, a project, a decision.
                """, summary: "nothing distinctive to look for")
        }

        let candidates = await memory.searchCaptures(claim, limit: 60)
        func hits(_ c: CaptureEvent) -> Int {
            let hay = (c.text + " " + (c.windowTitle ?? "")).lowercased()
            return terms.filter { hay.contains($0) }.count
        }

        // Direct evidence: one capture carrying every distinctive word in the claim.
        let scored = candidates.map { (capture: $0, hits: hits($0)) }.filter { $0.hits > 0 }
        let whole = scored.filter { $0.hits == terms.count }

        // Partial evidence exists (a claim can be spread across captures), but it is a
        // weaker thing and has to be labelled as one, never passed off as the claim itself.
        // Two terms is the floor: a single incidental word is a coincidence, not a source.
        let partialFloor = max(2, (terms.count + 1) / 2)
        let partial = scored
            .filter { $0.hits >= partialFloor && $0.hits < terms.count }
            .sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.capture.ts > $1.capture.ts }

        let chosen = whole.isEmpty ? partial : whole.sorted { $0.capture.ts > $1.capture.ts }
        guard !chosen.isEmpty else {
            return .nothing("""
                No evidence in the record for: "\(claim)".

                Looked for: \(terms.joined(separator: ", ")).

                Absence here is not disproof (capture coverage varies by app), but nothing \
                on screen while Memoir was watching said this.
                """, summary: "no evidence on record")
        }

        var out = ["# Sources for: \(claim)\n"]
        if whole.isEmpty {
            out.append("""
                _No single capture carries the whole claim. Below is **partial** evidence: \
                each mentions some of \(terms.joined(separator: ", ")), and the claim as \
                stated is not on record._
                """)
            out.append("")
        }

        // One page is one source, however many times it was captured (CF-82's law, applied
        // where it matters most). A tab left open produces a capture a minute, so the claim
        // above came back with twelve citations that were twelve photographs of one screen.
        // Corroboration is what a reader takes from a list of sources; repetition forges it.
        var seen = Set<String>()
        var cited: [Date] = []
        for (c, matched) in chosen {
            let head = Fmt.oneLine(c.text).lowercased().prefix(80)
            guard seen.insert(c.appBundleID + "|" + head).inserted else { continue }
            let title = c.windowTitle.map { " (\($0))" } ?? ""
            let strength = whole.isEmpty ? " · \(matched) of \(terms.count) terms" : ""
            let quote = Fmt.citation(text: c.text, visibleText: c.visibleText, matching: terms)
            out.append("- **\(c.appName)**\(title) · \(Fmt.iso(c.ts))\(strength)\n  > \(quote)")
            cited.append(c.ts)
            if cited.count >= 8 { break }
        }

        // Partial evidence is labelled in the prose and must be labelled here too: a
        // chip reading "4 sources" over a claim the record does not actually carry is
        // the same lie in fewer words.
        let span = ToolResult.span(cited)
        return .answered(
            out.joined(separator: "\n"),
            summary: [
                whole.isEmpty ? "partial" : "",
                ToolResult.tally([(cited.count, "source", "sources")]),
                span.newest.map { Fmt.relative($0) } ?? "",
            ].filter { !$0.isEmpty }.joined(separator: " · "),
            counts: ["sources": cited.count, "terms": terms.count],
            newest: span.newest,
            oldest: span.oldest
        )
    }

    // MARK: - verify

    private func verify(_ args: JSONValue) async -> ToolResult {
        guard let claim = args["claim"]?.stringValue, !claim.isEmpty else {
            return .declined("Missing required argument `claim`.", summary: "missing `claim`")
        }
        let freshDays = min(max(args["freshDays"]?.intValue ?? 14, 1), 365)
        let now = Date()

        // What in this claim could distinguish it from any other sentence.
        let terms = MemoirMemory.distinctiveTerms(in: claim)
        guard !terms.isEmpty else {
            return .declined("""
                **Cannot verify.** "\(claim)" carries no distinctive words to look for: \
                every word in it is common enough to appear in almost any capture.

                Ask about the specific thing: a name, a version, a project, a decision.
                """, summary: "nothing distinctive to look for")
        }

        // Every distinctive word must appear as a whole word, close together, on ONE screen.
        //
        // `searchCaptures` widens from AND to OR, which is right for recall: a
        // half-remembered phrase should still find the page. It is catastrophic here: an
        // OR match meant a single common word counted as evidence, and this tool certified
        // "the moon is made of cheese" as supported. Verification is the one caller that
        // must be stricter than search, so it re-checks what search returns.
        //
        // The re-check used to be "every term appears somewhere in the capture", and a
        // capture is a whole accessibility tree. Two words two thousand characters apart, in
        // unrelated parts of a page neither of them was about, passed. Bounded now, and
        // whole-word: a claim is a sentence, and sentences are short.
        //
        // Checked against what was ON SCREEN where that is known, for the same reason the
        // citation is drawn from there. Verifying against text that was scrolled out of view
        // certifies a claim from something the user never saw.
        let candidates = await memory.searchCaptures(claim, limit: 60)
        let captures = candidates
            .filter { capture in
                let visible = capture.visibleText?.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = (visible?.isEmpty == false) ? visible! : capture.text
                return Fmt.coOccur(terms, in: body + " " + (capture.windowTitle ?? ""))
            }
            .sorted { $0.ts > $1.ts }

        guard let latest = captures.first else {
            return .nothing("""
                **Not in the record.** Nothing captured while Memoir was watching mentions: "\(claim)".

                If another memory asserts this, the record can neither confirm nor date it. \
                Memoir verifies presence in the captured record, not truth.
                """, summary: "not in the record")
        }

        // What this tool can honestly say, and no more.
        //
        // "Supported by fresh evidence" reads as endorsement, and the thing being reported is
        // that some words were near each other on a screen. Those are different claims and the
        // gap between them is where a memory starts inventing. Words appearing together is not
        // the screen asserting the sentence, and no window size makes it so — the earlier
        // wording promised entailment that no amount of matching can deliver.
        let ageDays = Int(now.timeIntervalSince(latest.ts) / 86_400)
        var out: [String] = []
        if ageDays <= freshDays {
            out.append("""
                **These words appeared together on screen**, most recently \
                \(Fmt.relative(latest.ts)) in \(latest.appName). That is presence, not \
                confirmation: Memoir saw the words, not the fact.\n
                """)
        } else {
            out.append("""
                **Stale.** These words last appeared together on screen **\(ageDays) days ago** \
                (\(Fmt.day(latest.ts)), \(latest.appName)). If another memory asserts this as \
                current, it may have rotted since.
                """)
            out.append("")
        }
        for c in captures.prefix(3) {
            let quote = Fmt.citation(text: c.text, visibleText: c.visibleText, matching: terms)
            out.append("- \(c.appName) · \(Fmt.iso(c.ts))\n  > \(quote)")
        }
        if let oldest = captures.last, captures.count > 1 {
            out.append("\nFirst seen \(Fmt.day(oldest.ts)); \(captures.count) sightings on record.")
        }
        out.append("""

            _Reports that these words appeared together, as whole words, within one screen's \
            worth of text. Not that the screen asserted the claim, and not that the claim is \
            true._
            """)

        // The verdict is the whole value of this tool, so it is the whole summary:
        // fresh or stale, and how old. A chip that only said "3 sightings" would let a
        // caller act on evidence that rotted a year ago.
        return .answered(
            out.joined(separator: "\n"),
            summary: ageDays <= freshDays
                ? "supported · last seen \(Fmt.relative(latest.ts))"
                : "stale · last seen \(ageDays) days ago",
            counts: ["sightings": captures.count, "terms": terms.count],
            newest: latest.ts,
            oldest: captures.last?.ts
        )
    }

    // MARK: - timesheet

    private func timesheet(_ args: JSONValue) async -> ToolResult {
        let now = Date()
        let fromRaw = args["from"]?.stringValue ?? "today"
        let toRaw = args["to"]?.stringValue ?? "now"
        guard let from = Fmt.parseBoundary(fromRaw, isEnd: false, now: now) else {
            return .declined("Could not understand `from`: \"\(fromRaw)\".", summary: "could not read `from`")
        }
        guard let to = Fmt.parseBoundary(toRaw, isEnd: true, now: now) else {
            return .declined("Could not understand `to`: \"\(toRaw)\".", summary: "could not read `to`")
        }

        // Clipped like every other attribution path: an overlapping session's
        // out-of-window minutes belong to a different question.
        let sessions = WorkSpanBuilder.clip(
            await memory.sessions(from: from, to: to), from: from, to: to
        )
        let captures = await memory.captures(
            from: from.addingTimeInterval(-WorkSpanBuilder.defaultCarryForward), to: to, limit: 4_000
        )
        let ontology = Ontology.build(from: await memory.allEntities())
        let spans = WorkSpanBuilder.spans(sessions: sessions, captures: captures, ontology: ontology)
        let sheet = TimesheetBuilder.build(spans: spans, from: from, to: to)

        let days = Set(sheet.lines.map(\.day)).count
        let projects = Set(sheet.lines.map(\.label)).count
        return .answered(
            TimesheetBuilder.markdown(sheet),
            summary: [
                Fmt.duration(sheet.totalSeconds),
                ToolResult.tally([(days, "day", "days"), (projects, "project", "projects")]),
            ].filter { !$0.isEmpty }.joined(separator: " · "),
            counts: ["days": days, "projects": projects, "lines": sheet.lines.count],
            newest: sheet.lines.isEmpty ? nil : to,
            oldest: sheet.lines.map(\.day).min()
        )
    }

    // MARK: - propose_memory

    private func proposeMemory(_ args: JSONValue) async -> ToolResult {
        guard let kindRaw = args["kind"]?.stringValue,
              let kind = EntityKind(rawValue: kindRaw) else {
            let valid = EntityKind.allCases.map(\.rawValue).joined(separator: ", ")
            return .declined("Missing or invalid `kind`. One of: \(valid).", summary: "invalid `kind`")
        }
        guard let title = args["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              title.count >= 3 else {
            return .declined(
                "Missing required argument `title` (at least 3 characters).",
                summary: "missing `title`"
            )
        }
        guard title.count <= ProposalStore.maxTitleChars else {
            return .declined(
                "`title` is limited to \(ProposalStore.maxTitleChars) characters: a memory is a line, not a payload. Put substance in `detail` (max \(ProposalStore.maxDetailChars)).",
                summary: "`title` too long"
            )
        }
        let detail = args["detail"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail, detail.count > ProposalStore.maxDetailChars {
            return .declined(
                "`detail` is limited to \(ProposalStore.maxDetailChars) characters.",
                summary: "`detail` too long"
            )
        }
        var dueAt: Date?
        if let dueRaw = args["due"]?.stringValue, !dueRaw.isEmpty {
            guard let parsed = Fmt.parseBoundary(dueRaw, isEnd: false, now: Date()) else {
                return .declined(
                    "Could not understand `due`: \"\(dueRaw)\". Use an ISO date like 2026-08-14.",
                    summary: "could not read `due`"
                )
            }
            dueAt = parsed
        }

        let proposal = MemoryProposal(
            ts: Date(),
            kind: kind,
            title: title,
            detail: (detail?.isEmpty ?? true) ? nil : detail,
            dueAt: dueAt,
            origin: "mcp"
        )
        do {
            try ProposalStore.append(proposal, at: proposalsURL)
        } catch {
            return .declined(
                "Could not stage the proposal: \(error.localizedDescription)",
                summary: "could not stage"
            )
        }
        // Staged, not recorded. The summary has to keep saying so, because a chip
        // reading "1 memory" over a proposal nobody has accepted is the exact claim
        // this tool spends three paragraphs refusing to make.
        return .answered("""
            Staged for review (id `\(proposal.id)`). The user will see this in Memoir and may \
            accept, edit or reject it. **Nothing has been written to memory**: the database \
            stays read-only to this server, and only the user's accept creates the entry.
            """, summary: "1 proposal staged for review", counts: ["staged": 1], newest: proposal.ts)
    }

    // MARK: - Shared rendering

    private func entityBlock(_ e: Entity) async -> String {
        var lines = ["### \(e.title)"]
        // The one badge that never goes away: authored vs inferred (CF-55).
        var meta = [
            "kind: \(e.kind.rawValue)",
            e.source == .authored ? "**you told me**" : "picked up",
            "confidence: \(Int(e.confidence * 100))%",
        ]
        if let done = e.completedAt { meta.append("completed \(Fmt.day(done))") }
        if e.corrected { meta.append("**user-corrected**") }
        if e.pinned { meta.append("pinned") }
        if let due = e.dueAt { meta.append("due \(Fmt.day(due))") }
        lines.append("_\(meta.joined(separator: " · "))_")
        // What else this row answers to. An alias is what let a mention attach to this record
        // rather than another, so a reader deciding whether to trust the attribution needs to
        // see it — especially where two people share a name.
        if !e.aliases.isEmpty {
            lines.append("_also called: \(e.aliases.joined(separator: ", "))_")
        }
        if let detail = e.detail { lines.append(detail) }

        let rows = await memory.provenance(entityID: e.id, limit: 4)
        if !rows.isEmpty {
            let captures = await memory.captures(ids: rows.map(\.captureID))
            lines.append("\nSeen in:")
            // Every citation carries its grade. A match in a window title and a match two
            // thousand characters down a page are not the same fact, and presenting them in
            // one voice tells the reader they are. See `EvidenceStrength`.
            for row in rows {
                let app = captures[row.captureID]?.appName ?? "unknown app"
                lines.append(
                    "- \(app) · \(Fmt.relative(row.ts)) · \"\(Fmt.oneLine(row.snippet))\""
                    + row.strength.note)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func commitmentLine(_ e: Entity, now: Date) -> String {
        var s = "- \(e.title)"
        if let due = e.dueAt {
            s += due < now
                ? ", **overdue** since \(Fmt.day(due))"
                : ", due \(Fmt.day(due))"
        }
        s += e.source == .authored ? " _(you told me)_" : " _(picked up)_"
        if e.corrected { s += " _(you corrected this)_" }
        return s
    }
}
