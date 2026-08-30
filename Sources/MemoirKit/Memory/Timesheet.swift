import Foundation

/// A reconstructed record of where working time actually went, per day, per thing,
/// with evidence.
///
/// This is the proof-of-work output: the same asset the agents read, sold to the
/// person with a billing line. Every line is computed from sessions and labelled by
/// the ontology; every line can point at the captures it rests on. A timesheet built
/// on app names is a commodity; one built on project names with citations is not.
public struct Timesheet: Sendable, Equatable {

    public struct Line: Sendable, Equatable {
        /// Start of the local day this line belongs to.
        public let day: Date
        /// Project title when the ontology recognised the work, app name otherwise.
        public let label: String
        /// The labelling entity, nil for app fallback.
        public let entityID: ID?
        public let seconds: TimeInterval
        public let apps: [String]
        /// Captures the attribution rests on.
        public let captureIDs: [ID]

        public init(day: Date, label: String, entityID: ID?, seconds: TimeInterval,
                    apps: [String], captureIDs: [ID]) {
            self.day = day
            self.label = label
            self.entityID = entityID
            self.seconds = seconds
            self.apps = apps
            self.captureIDs = captureIDs
        }
    }

    public let from: Date
    public let to: Date
    /// Ordered by day, then by time spent within the day, biggest first.
    public let lines: [Line]

    public var totalSeconds: TimeInterval { lines.reduce(0) { $0 + $1.seconds } }

    public init(from: Date, to: Date, lines: [Line]) {
        self.from = from
        self.to = to
        self.lines = lines
    }
}

/// Builds and renders timesheets from work spans. Pure and deterministic.
public enum TimesheetBuilder {

    /// Buckets spans into day + label lines. A span crossing midnight is split at the
    /// boundary: its seconds are apportioned linearly, which is the honest reading of
    /// "attributed time" when the exact distribution inside a span is unknowable.
    public static func build(
        spans: [WorkSpan],
        from: Date,
        to: Date,
        calendar: Calendar = .current
    ) -> Timesheet {
        struct Key: Hashable { let day: Date; let label: String }
        var buckets: [Key: (entityID: ID?, seconds: TimeInterval, apps: [String], captureIDs: [ID])] = [:]

        for rawSpan in spans {
            // The builder enforces its own range even if a caller hands it wider
            // spans: a timesheet for [from, to] must never contain a second outside
            // it. Seconds are apportioned linearly over the clamped fraction.
            let clampedStart = max(rawSpan.start, from)
            let clampedEnd = min(rawSpan.end, to)
            guard clampedEnd > clampedStart else { continue }
            let wallSpan = rawSpan.end.timeIntervalSince(rawSpan.start)
            let keptFraction = wallSpan > 0 ? clampedEnd.timeIntervalSince(clampedStart) / wallSpan : 1
            let span = WorkSpan(
                label: rawSpan.label, entityID: rawSpan.entityID,
                start: clampedStart, end: clampedEnd,
                seconds: rawSpan.seconds * keptFraction,
                apps: rawSpan.apps, captureIDs: rawSpan.captureIDs
            )
            var sliceStart = span.start
            while sliceStart < span.end {
                let day = calendar.startOfDay(for: sliceStart)
                let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? span.end
                let sliceEnd = min(span.end, nextDay)
                let wall = span.end.timeIntervalSince(span.start)
                let share = wall > 0 ? sliceEnd.timeIntervalSince(sliceStart) / wall : 1
                let key = Key(day: day, label: span.label)
                var entry = buckets[key] ?? (span.entityID, 0, [], [])
                entry.seconds += span.seconds * share
                for app in span.apps where !entry.apps.contains(app) { entry.apps.append(app) }
                entry.captureIDs.append(contentsOf: span.captureIDs)
                buckets[key] = entry
                sliceStart = sliceEnd
            }
        }

        var lines: [Timesheet.Line] = []
        for (key, entry) in buckets {
            lines.append(Timesheet.Line(
                day: key.day, label: key.label, entityID: entry.entityID,
                seconds: entry.seconds, apps: entry.apps, captureIDs: entry.captureIDs
            ))
        }
        lines.sort { (a: Timesheet.Line, b: Timesheet.Line) -> Bool in
            if a.day != b.day { return a.day < b.day }
            return a.seconds > b.seconds
        }
        return Timesheet(from: from, to: to, lines: lines)
    }

    /// Renders a timesheet as markdown a human could paste into an invoice draft,
    /// and defend, because every line says what the attribution rests on.
    public static func markdown(_ sheet: Timesheet, calendar: Calendar = .current) -> String {
        guard !sheet.lines.isEmpty else {
            return "No tracked time in this range."
        }
        var out: [String] = ["# Timesheet", ""]
        let dayFormat = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)

        var currentDay: Date?
        for line in sheet.lines {
            if line.day != currentDay {
                currentDay = line.day
                let dayTotal = sheet.lines.filter { $0.day == line.day }.reduce(0.0) { $0 + $1.seconds }
                out.append("## \(line.day.formatted(dayFormat)): \(duration(dayTotal))")
            }
            let evidence = line.captureIDs.isEmpty
                ? "session records only"
                : "\(line.captureIDs.count) capture\(line.captureIDs.count == 1 ? "" : "s") on record"
            out.append("- **\(line.label)** · \(duration(line.seconds)) · \(line.apps.joined(separator: ", ")) · \(evidence)")
        }
        out.append("")
        out.append("**Total: \(duration(sheet.totalSeconds))**")
        out.append("")
        out.append("Attribution: frontmost-app sessions, cut at screen captures, labelled by the names in your memory. Unlabelled time is listed under the app it was spent in, never guessed into a project.")
        return out.joined(separator: "\n")
    }

    /// "3h 10m" / "42m". Invoice-style, terser than the ask-bar rendering.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }
}

/// Assembles the weekly review: what the time went to, what came up, what is owed.
/// Deterministic, citable, and honest about being a record rather than a judgement.
public enum ReviewBuilder {

    public static func markdown(
        sheet: Timesheet,
        touched: [Entity],
        commitments: [Entity],
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        var out: [String] = ["# Week in review", ""]

        // Where the time went, aggregated over the whole range.
        var byLabel: [String: (seconds: TimeInterval, labeled: Bool)] = [:]
        for line in sheet.lines {
            var entry = byLabel[line.label] ?? (0, line.entityID != nil)
            entry.seconds += line.seconds
            byLabel[line.label] = entry
        }
        if byLabel.isEmpty {
            out.append("No tracked time this week.")
        } else {
            out.append("## Where the time went: \(TimesheetBuilder.duration(sheet.totalSeconds)) tracked")
            for (label, entry) in byLabel.sorted(by: { $0.value.seconds > $1.value.seconds }).prefix(8) {
                let name = entry.labeled ? "**\(label)**" : label
                out.append("- \(name): \(TimesheetBuilder.duration(entry.seconds))")
            }
            out.append("")
        }

        // What surfaced, by kind, user-authored first.
        if !touched.isEmpty {
            out.append("## What came up")
            let ranked = touched.sorted {
                ($0.source == .authored ? 0 : 1, -$0.confidence) < ($1.source == .authored ? 0 : 1, -$1.confidence)
            }
            for entity in ranked.prefix(10) {
                let tag = entity.source == .authored ? "" : " *(inferred)*"
                out.append("- \(entity.kind.displayName): \(entity.title)\(tag)")
            }
            out.append("")
        }

        // Commitments: overdue first, then due soon.
        let open = commitments.filter { !$0.deleted }
        if !open.isEmpty {
            out.append("## Commitments")
            let sorted = open.sorted { a, b in
                switch (a.dueAt, b.dueAt) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.updatedAt > b.updatedAt
                }
            }
            for entity in sorted.prefix(8) {
                let due: String
                if let dueAt = entity.dueAt {
                    due = dueAt < now ? ", **overdue**" : ", due \(dueAt.formatted(date: .abbreviated, time: .omitted))"
                } else {
                    due = ""
                }
                out.append("- \(entity.title)\(due)")
            }
            out.append("")
        }

        out.append("*Assembled from session records and captures on this Mac. Time figures are measured, not estimated; nothing here is a claim about outcomes.*")
        return out.joined(separator: "\n")
    }
}
