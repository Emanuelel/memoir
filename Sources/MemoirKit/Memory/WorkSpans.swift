import Foundation

/// A contiguous stretch of work on one thing, across however many apps it took.
///
/// The sessions table answers "how long was Chrome frontmost". This answers the
/// question people actually ask: "how long did I work on the migration", where the
/// migration was twenty minutes of Xcode, six of Chrome and four of Slack, and no
/// per-app number contains it.
public struct WorkSpan: Sendable, Equatable {
    /// What the work was about: an entity title when the ontology recognised it,
    /// otherwise the app name.
    public let label: String
    /// The labelling entity, or nil when the label is only an app-name fallback.
    public let entityID: ID?
    /// When the span began.
    public let start: Date
    /// When the span ended.
    public let end: Date
    /// Attributed working seconds. Less than `end - start` when merged across a gap.
    public let seconds: TimeInterval
    /// Distinct app names touched during the span, in order of first appearance.
    public let apps: [String]
    /// Captures the attribution rests on. Empty for a session with no captured text.
    public let captureIDs: [ID]

    public init(
        label: String, entityID: ID?, start: Date, end: Date,
        seconds: TimeInterval, apps: [String], captureIDs: [ID]
    ) {
        self.label = label
        self.entityID = entityID
        self.start = start
        self.end = end
        self.seconds = seconds
        self.apps = apps
        self.captureIDs = captureIDs
    }
}

/// Builds work spans from sessions, captures and an ontology. Pure and deterministic:
/// same inputs, same spans, no clock, no store.
public enum WorkSpanBuilder {

    /// How far back a screen may keep labelling a session that began before the
    /// asked window. Callers fetch captures from `from - this` so the label exists.
    public static let defaultCarryForward: TimeInterval = 4 * 3_600

    /// One attributed slice of session time, before merging.
    private struct Slice {
        let label: String
        let entityID: ID?
        let start: Date
        let end: Date
        let app: String
        let captureID: ID?
        var seconds: TimeInterval { end.timeIntervalSince(start) }
    }

    /// The apps worth listing beside a span's label.
    ///
    /// Unlabelled work degrades honestly to the app name, and this then listed the apps
    /// beside it, so the working set named Claude twice on one row: once as the label, once
    /// as the app. Saying the same word twice is not more information, and it made an
    /// honest fallback look like a bug.
    public static func appsWorthNaming(_ span: WorkSpan) -> [String] {
        let label = span.label.lowercased()
        let rest = span.apps.filter { $0.lowercased() != label }
        // Only worth naming when the label is a real thing spanning apps, or when the work
        // touched somewhere other than the app it is named after.
        return span.apps.count == 1 && rest.isEmpty ? [] : rest.isEmpty ? span.apps : rest
    }

    /// Sessions clipped to a window: overlap becomes intersection, empties drop.
    ///
    /// `Store.sessions(from:to:)` returns sessions that merely *overlap* the window,
    /// which is right for "what was running" and wrong for attribution: a 23:00–01:00
    /// session answering a "today" question would otherwise bill its 23:00 hour into
    /// today's report, dated yesterday. Time outside the asked window belongs to a
    /// different question.
    public static func clip(_ sessions: [Session], from: Date, to: Date) -> [Session] {
        sessions.compactMap { session in
            let start = max(session.startedAt, from)
            let end = min(session.endedAt, to)
            guard end > start else { return nil }
            guard start != session.startedAt || end != session.endedAt else { return session }
            return Session(
                id: session.id,
                appBundleID: session.appBundleID,
                appName: session.appName,
                startedAt: start,
                endedAt: end,
                idle: session.idle
            )
        }
    }

    /// Computes merged spans for a window.
    ///
    /// Attribution: each non-idle session is cut at its captures; every interval carries
    /// the label of the capture that opened it (a screen labels the time *after* it
    /// appears, until the screen changes). Time before the first capture, and sessions
    /// with no captures at all, fall back to the app name. Adjacent slices with the same
    /// label then merge across apps and across gaps of up to `mergeGap`.
    public static func spans(
        sessions: [Session],
        captures: [CaptureEvent],
        ontology: Ontology,
        mergeGap: TimeInterval = 15 * 60,
        minimumSpanSeconds: TimeInterval = 60,
        carryForward: TimeInterval = 4 * 3_600
    ) -> [WorkSpan] {
        let active = sessions.filter { !$0.idle && $0.duration > 0 }.sorted { $0.startedAt < $1.startedAt }
        guard !active.isEmpty else { return [] }

        // Every stretch Memoir was actually recording, idle included.
        //
        // Idle sessions count here on purpose. An idle session is Memoir watching a screen
        // saver, which is evidence it was running; the absence of ANY session is evidence it
        // was not. That distinction is what `carriedCapture` needs and nothing else in this
        // file has ever asked for.
        let watched = Self.merged(sessions.filter { $0.duration > 0 }.map { ($0.startedAt, $0.endedAt) })

        // Label every capture once, up front.
        let ordered = captures.sorted { $0.ts < $1.ts }
        var matches: [ID: Ontology.Match] = [:]
        for capture in ordered {
            if let hit = ontology.match(
                windowTitle: capture.windowTitle, text: capture.text, appName: capture.appName) {
                matches[capture.id] = hit
            }
        }

        // Cut each session into labelled slices.
        var slices: [Slice] = []
        for session in active {
            let mine = ordered.filter {
                $0.appBundleID == session.appBundleID
                    && $0.ts >= session.startedAt && $0.ts <= session.endedAt
            }
            // The screen that was already showing when the session began.
            //
            // A window asked about mid-work clips its first session, and the capture
            // that names what is on screen sits just *before* the clip. Without this,
            // "where did I leave off" reported an hour of Figma for the same minutes the
            // timesheet correctly billed to "Client Onboarding": same data, two
            // answers, purely because one view started its clock later. A screen
            // labels the time after it appears, including across a window boundary.
            // How far back the record can be trusted for this session: the earliest instant
            // reachable from it without crossing a hole. Computed once per session, so the
            // per-capture test below stays a comparison rather than a scan.
            let reachable = max(
                Self.earliestWatched(before: session.startedAt, watched: watched),
                session.startedAt.addingTimeInterval(-carryForward)
            )
            let carried = ordered.last {
                $0.appBundleID == session.appBundleID
                    && $0.ts < session.startedAt
                    && $0.ts >= reachable
                    && matches[$0.id] != nil
            }

            guard !mine.isEmpty else {
                let hit = carried.flatMap { matches[$0.id] }
                slices.append(Slice(
                    label: hit?.title ?? session.appName, entityID: hit?.entityID,
                    start: session.startedAt, end: session.endedAt,
                    app: session.appName, captureID: carried?.id
                ))
                continue
            }
            // Head: before anything was captured in-window, the carried screen labels
            // it if there is one; otherwise only the app is known.
            if mine[0].ts > session.startedAt {
                let hit = carried.flatMap { matches[$0.id] }
                slices.append(Slice(
                    label: hit?.title ?? session.appName, entityID: hit?.entityID,
                    start: session.startedAt, end: mine[0].ts,
                    app: session.appName, captureID: carried?.id
                ))
            }
            for (index, capture) in mine.enumerated() {
                let sliceEnd = index + 1 < mine.count ? mine[index + 1].ts : session.endedAt
                guard sliceEnd > capture.ts else { continue }
                let hit = matches[capture.id]
                slices.append(Slice(
                    label: hit?.title ?? session.appName,
                    entityID: hit?.entityID,
                    start: capture.ts, end: sliceEnd,
                    app: session.appName, captureID: capture.id
                ))
            }
        }
        guard !slices.isEmpty else { return [] }
        slices.sort { $0.start < $1.start }

        // Merge adjacent same-label slices, tolerating short gaps.
        var spans: [WorkSpan] = []
        var label = slices[0].label
        var entityID = slices[0].entityID
        var start = slices[0].start
        var end = slices[0].end
        var seconds = slices[0].seconds
        var apps: [String] = [slices[0].app]
        var captureIDs: [ID] = slices[0].captureID.map { [$0] } ?? []

        func flush() {
            guard seconds >= minimumSpanSeconds else { return }
            spans.append(WorkSpan(
                label: label, entityID: entityID, start: start, end: end,
                seconds: seconds, apps: apps, captureIDs: captureIDs
            ))
        }

        for slice in slices.dropFirst() {
            let sameThing = slice.label == label && slice.entityID == entityID
            if sameThing && slice.start.timeIntervalSince(end) <= mergeGap {
                end = max(end, slice.end)
                seconds += slice.seconds
                if !apps.contains(slice.app) { apps.append(slice.app) }
                if let id = slice.captureID { captureIDs.append(id) }
            } else {
                flush()
                label = slice.label
                entityID = slice.entityID
                start = slice.start
                end = slice.end
                seconds = slice.seconds
                apps = [slice.app]
                captureIDs = slice.captureID.map { [$0] } ?? []
            }
        }
        flush()
        return spans
    }

    // MARK: - Carrying a label forward, and where it must stop

    /// The earliest instant a label may be carried forward from, for a session starting at
    /// `start`.
    ///
    /// Walks back through the stretches Memoir was actually recording and stops at the first
    /// hole. Everything on the far side of that hole is unreachable, however recent it is.
    ///
    /// **Why recency alone was not enough.** Carry-forward exists for a real reason: a screen
    /// showing at 10:00 labels the time until Memoir first reads it at 10:02, and without that
    /// two views of the same day disagreed about the same minutes. But the rule was "same app,
    /// within four hours", and four hours of continuous recording and four hours of absence are
    /// the same number of seconds and opposite facts.
    ///
    /// The case that found it, from a real vault: an app in front from 08:47, idle from 08:50,
    /// and then the record stops dead — no captures, no sessions, nothing at all until 12:46.
    /// The Mac was asleep or Memoir was not running. The first session after that hole had no
    /// captures of its own, so the old rule reached back, found the screen from before the
    /// outage, and billed three minutes of the afternoon to it. Measured on that vault, 80
    /// borrows reached across a stretch averaging fifty minutes in which Memoir recorded
    /// nothing whatsoever.
    ///
    /// A screen labels the time after it appears *until the screen changes*, and Memoir cannot
    /// know whether a screen changed while it was not looking. So the carry stops at the edge
    /// of what was witnessed.
    ///
    /// Idle stretches count as watching, on purpose: an idle session is Memoir observing a
    /// screen saver, which is evidence the loop was running. The absence of any session is the
    /// evidence that it was not.
    ///
    /// The tolerance exists only so that ordinary bookkeeping — one session closing a moment
    /// before the next opens — does not read as an outage.
    /// **Only a proven hole blocks a carry. Missing information does not.**
    ///
    /// This distinction cost a passing test to find, and the test was right. The session list
    /// handed to `spans` is already clipped to the window being asked about, so "no session
    /// covers that moment" usually means "the caller did not ask about that moment" — not
    /// "Memoir was not watching it". Treating the two the same broke the case carry-forward was
    /// written for: a window asked about mid-work clips its first session, and the screen that
    /// names it sits just before the clip.
    ///
    /// So the walk refuses only when it can SEE the hole: a recorded stretch exists on the far
    /// side, and there is unrecorded time between it and here. Walking off the front of what
    /// the caller supplied returns no constraint at all, and `carryForward` remains the
    /// backstop for how far a screen may reach when nothing is known.
    static func earliestWatched(
        before start: Date, watched: [(start: Date, end: Date)], tolerance: TimeInterval = 120
    ) -> Date {
        var floor = start
        // `watched` is merged and sorted, so walking it backwards walks the record backwards.
        for stretch in watched.reversed() where stretch.start < floor {
            // A stretch exists back there and cannot be reached from here: that is the hole.
            guard floor.timeIntervalSince(stretch.end) <= tolerance else { return floor }
            floor = stretch.start
        }
        // Ran out of record rather than hitting a gap. Older than this is unknown, and unknown
        // is not the same as unwatched.
        return .distantPast
    }

    /// Union of intervals, oldest first. Used to ask what was witnessed and what was not.
    static func merged(_ intervals: [(Date, Date)]) -> [(start: Date, end: Date)] {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var out: [(start: Date, end: Date)] = []
        for (start, end) in sorted {
            if let last = out.last, start <= last.end {
                out[out.count - 1].end = max(last.end, end)
            } else {
                out.append((start, end))
            }
        }
        return out
    }

}
