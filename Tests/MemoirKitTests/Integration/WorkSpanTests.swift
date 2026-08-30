import Foundation
import Testing
import MemoirFixtures
@testable import MemoirKit

// CF-70: semantic sessions. Work on one thing spanning several apps is reported as
// one span with the thing's name, not as per-app fragments. Unlabelled time degrades
// honestly to the app name; nothing is ever attributed to a project without a capture
// to point at.

@Suite("CF-70 work spans")
struct WorkSpanTests {

    @Test("CF-87 a todo is not a topic, and a label is never the app said twice")
    func commitmentsNeverLabelWork() {
        // A commitment is a task, not something work is ABOUT. This file already records
        // the same failure for threads: an email subject line became a bolded project in
        // a timesheet, 24m billed under a lunch invitation, and the "authored still
        // labels regardless of kind" escape hatch brought it straight back: a stray todo
        // typed into the push bar became the name of an hour's work on the real database.
        let todo = makeEntity(kind: .commitment, title: "what was the last message I sent on whatdsapp")
        var authoredTodo = makeEntity(kind: .commitment, title: "send the invoice")
        authoredTodo.source = .authored
        var project = makeEntity(kind: .project, title: "Fenwick Migration")
        project.source = .authored

        let ontology = Ontology.build(from: [todo, authoredTodo, project])
        #expect(!ontology.labels.contains { $0.kind == .commitment },
                "a todo became a label for work: \(ontology.labels.map(\.title))")
        #expect(ontology.labels.contains { $0.title == "Fenwick Migration" },
                "a real project must still label")
    }

    @Test("CF-87 unlabelled time is named once, not twice")
    func fallbackLabelIsNotRepeated() {
        // Unlabelled work degrades honestly to the app name, and then listed the apps
        // beside it, so the working set read "Claude · 5m · Claude". Saying the same word
        // twice is not more information.
        let sessions = [
            makeSession(appName: "Claude", bundleID: "com.anthropic.claudefordesktop",
                        from: TestClock.reference, to: TestClock.minutes(5))
        ]
        let spans = WorkSpanBuilder.spans(sessions: sessions, captures: [],
                                          ontology: Ontology.build(from: []))
        let span = try! #require(spans.first)
        #expect(span.entityID == nil, "nothing matched, so nothing is claimed")
        #expect(span.label == "Claude")
        // The renderer's contract: when the label IS the app, the app list adds nothing.
        #expect(WorkSpanBuilder.appsWorthNaming(span).isEmpty,
                "the app list repeated the label: \(WorkSpanBuilder.appsWorthNaming(span))")
    }


    private var fenwick: Entity {
        Entity(
            id: TestID.stable("entity", "project", "Fenwick Migration"),
            kind: .project,
            title: "Fenwick Migration",
            source: .authored,
            aliases: ["fenwick", "FEN-42"],
            createdAt: TestClock.reference,
            updatedAt: TestClock.reference
        )
    }

    private func capture(_ text: String, app: String, bundle: String, title: String?, at ts: Date, name: String) -> CaptureEvent {
        Fixtures.capture(text: text, app: app, bundleID: bundle, windowTitle: title, at: ts, name: name)
    }

    @Test("CF-70 one project across three apps is one span")
    func crossAppSpan() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let t0 = TestClock.reference

            // 09:00-09:20 Xcode, 09:20-09:26 Chrome, 09:26-09:30 Slack. All Fenwick.
            let sessions = [
                makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode", from: t0, to: TestClock.minutes(20)),
                makeSession(appName: "Chrome", bundleID: "com.google.Chrome", from: TestClock.minutes(20), to: TestClock.minutes(26)),
                makeSession(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", from: TestClock.minutes(26), to: TestClock.minutes(30)),
            ]
            let captures = [
                capture("class FenwickImporter {", app: "Xcode", bundle: "com.apple.dt.Xcode",
                        title: "FenwickImporter.swift", at: t0, name: "xcode-fenwick"),
                capture("FEN-42 rate limiter design doc", app: "Chrome", bundle: "com.google.Chrome",
                        title: "FEN-42 \u{2014} Jira", at: TestClock.minutes(20), name: "chrome-fenwick"),
                capture("fenwick standup thread", app: "Slack", bundle: "com.tinyspeck.slackmacgap",
                        title: "#fenwick \u{2014} Slack", at: TestClock.minutes(26), name: "slack-fenwick"),
            ]
            try await seed(store: store, captures: captures, entities: [fenwick], sessions: sessions)

            let spans = try await memory.workSpans(from: t0, to: TestClock.minutes(30))
            #expect(spans.count == 1, "three apps, one thing, one span")
            let span = try #require(spans.first)
            #expect(span.label == "Fenwick Migration")
            #expect(span.entityID == fenwick.id)
            #expect(span.apps == ["Xcode", "Chrome", "Slack"])
            #expect(abs(span.seconds - 30 * 60) < 1)
            #expect(span.captureIDs.count == 3, "every attributed minute has evidence")
        }
    }

    @Test("CF-70 unlabelled time degrades to the app, never to a guess")
    func unlabelledFallsBackToApp() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let t0 = TestClock.reference

            let sessions = [
                makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode", from: t0, to: TestClock.minutes(10)),
                makeSession(appName: "Mail", bundleID: "com.apple.mail", from: TestClock.minutes(10), to: TestClock.minutes(16)),
            ]
            let captures = [
                capture("import FenwickKit", app: "Xcode", bundle: "com.apple.dt.Xcode",
                        title: "fenwick migration notes", at: t0, name: "xcode-hit"),
                // Nothing in Mail matches anything known.
                capture("Lunch on Thursday?", app: "Mail", bundle: "com.apple.mail",
                        title: "Inbox", at: TestClock.minutes(10), name: "mail-miss"),
            ]
            try await seed(store: store, captures: captures, entities: [fenwick], sessions: sessions)

            let spans = try await memory.workSpans(from: t0, to: TestClock.minutes(16))
            #expect(spans.count == 2)
            #expect(spans[0].label == "Fenwick Migration")
            #expect(spans[1].label == "Mail")
            #expect(spans[1].entityID == nil, "app fallback carries no entity claim")
        }
    }

    @Test("CF-70 idle sessions are never attributed")
    func idleExcluded() {
        let ontology = Ontology.build(from: [])
        let sessions = [
            makeSession(appName: "Chrome", bundleID: "com.google.Chrome",
                        from: TestClock.reference, to: TestClock.minutes(30), idle: true)
        ]
        let spans = WorkSpanBuilder.spans(sessions: sessions, captures: [], ontology: ontology)
        #expect(spans.isEmpty, "idle time belongs to nobody")
    }

    @Test("CF-70 a short interruption does not split a span")
    func gapMerging() {
        let entity = Entity(
            id: TestID.stable("entity", "project", "Fenwick Migration"),
            kind: .project, title: "Fenwick Migration",
            source: .authored, aliases: ["fenwick"],
            createdAt: TestClock.reference, updatedAt: TestClock.reference
        )
        let ontology = Ontology.build(from: [entity])
        let t0 = TestClock.reference
        // Work, five-minute hole (no session at all), work again.
        let sessions = [
            makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode", from: t0, to: TestClock.minutes(10)),
            makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode", from: TestClock.minutes(15), to: TestClock.minutes(25)),
        ]
        let captures = [
            Fixtures.capture(text: "fenwick importer", app: "Xcode", bundleID: "com.apple.dt.Xcode",
                             windowTitle: "fenwick", at: t0, name: "before-gap"),
            Fixtures.capture(text: "fenwick importer again", app: "Xcode", bundleID: "com.apple.dt.Xcode",
                             windowTitle: "fenwick", at: TestClock.minutes(15), name: "after-gap"),
        ]
        let spans = WorkSpanBuilder.spans(sessions: sessions, captures: captures, ontology: ontology)
        #expect(spans.count == 1, "a coffee refill is not a context switch")
        #expect(abs((spans.first?.seconds ?? 0) - 20 * 60) < 1, "the hole itself is not billed")
    }

    @Test("CF-70 a session already in progress keeps the label of the screen showing when it began")
    func carriedLabelSurvivesWindowStart() {
        let entity = Entity(
            id: TestID.stable("entity", "project", "Client Onboarding"),
            kind: .project, title: "Client Onboarding",
            source: .authored, aliases: ["onboarding"],
            createdAt: TestClock.reference, updatedAt: TestClock.reference
        )
        let ontology = Ontology.build(from: [entity])
        // The screen was captured at T+0; the asked window starts at T+30, mid-session.
        let capture = Fixtures.capture(
            text: "Layer", app: "Figma", bundleID: "com.figma.Desktop",
            windowTitle: "Client Onboarding \u{2014} flows",
            at: TestClock.reference, name: "figma-label"
        )
        let session = makeSession(
            appName: "Figma", bundleID: "com.figma.Desktop",
            from: TestClock.minutes(30), to: TestClock.minutes(90)
        )
        let spans = WorkSpanBuilder.spans(
            sessions: [session], captures: [capture], ontology: ontology
        )
        #expect(spans.count == 1)
        #expect(spans.first?.label == "Client Onboarding",
                "a clipped window must not lose the name of what was on screen")
        #expect(spans.first?.entityID == entity.id)

        // But a screen from days ago never labels today's session.
        let stale = Fixtures.capture(
            text: "Layer", app: "Figma", bundleID: "com.figma.Desktop",
            windowTitle: "Client Onboarding \u{2014} flows",
            at: TestClock.days(-3), name: "figma-stale"
        )
        let staleSpans = WorkSpanBuilder.spans(
            sessions: [session], captures: [stale], ontology: ontology
        )
        #expect(staleSpans.first?.label == "Figma", "carry-forward is bounded, not infinite")
    }

    @Test("CF-70 a midnight-crossing session never bills outside the asked window")
    func midnightSessionIsClipped() {
        // 23:00–01:00 across local midnight, asked about the later day only.
        let dayStart = TestClock.localCalendar.startOfDay(for: TestClock.reference)
        let sessions = [
            makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                        from: dayStart.addingTimeInterval(-3_600),
                        to: dayStart.addingTimeInterval(3_600))
        ]
        let clipped = WorkSpanBuilder.clip(sessions, from: dayStart, to: dayStart.addingTimeInterval(7_200))
        #expect(clipped.count == 1)
        #expect(clipped.first?.startedAt == dayStart, "the pre-window hour is cut off")
        #expect(abs((clipped.first?.duration ?? 0) - 3_600) < 1, "only the in-window hour remains")

        // And the timesheet builder enforces the same range on its own: a span
        // handed to it that starts before `from` yields no line dated the prior day.
        let ontology = Ontology.build(from: [])
        let spans = WorkSpanBuilder.spans(sessions: sessions, captures: [], ontology: ontology)
        let sheet = TimesheetBuilder.build(spans: spans, from: dayStart, to: dayStart.addingTimeInterval(7_200))
        #expect(sheet.lines.allSatisfy { $0.day >= dayStart }, "no line may be dated before the range")
        #expect(abs(sheet.totalSeconds - 3_600) < 1, "the total contains only in-range seconds")
    }

    @Test("CF-70 an inferred email thread never becomes a project label")
    func inferredThreadsDoNotLabel() {
        // A mail subject, extracted as a thread. Real data produced exactly this, and
        // it turned up bolded in a timesheet as if it were a project.
        let thread = makeEntity(kind: .thread, title: "lunch thursday \u{2014} works for me")
        let ontology = Ontology.build(from: [thread])
        #expect(ontology.match(windowTitle: "lunch thursday \u{2014} works for me", text: "") == nil,
                "an inferred thread must not name a span of billable work")

        // The same title authored by the user does not label either. It used to: anything
        // authored labelled regardless of kind, because the user chose to write it. Writing
        // something down is not the same as spending an hour on it, and the reasoning cost
        // more than it bought — see `authoredNotesDoNotLabel` below for what it was billing.
        var authored = thread
        authored.source = .authored
        let authoredOntology = Ontology.build(from: [authored])
        #expect(authoredOntology.match(windowTitle: "lunch thursday \u{2014} works for me", text: "") == nil,
                "kind decides what may label; source only breaks ties between two of them")
    }

    /// A label may not be carried across a hole in the recording.
    ///
    /// Carry-forward exists for a real reason: a screen showing at 10:00 labels the time until
    /// Memoir first reads it at 10:02, and without that two views of the same day disagreed.
    /// But the rule was recency alone — same app, within four hours — and four hours of
    /// continuous recording and four hours of absence are the same number of seconds and
    /// opposite facts.
    ///
    /// The case from the real vault: an app in front from 08:47, idle from 08:50, and then the
    /// record stops dead. No captures, no sessions, until 12:46 — asleep, or not running. The
    /// first session after the hole had no captures of its own, so the old rule reached back,
    /// found the screen from before the outage, and billed the afternoon to it. 70 borrows on
    /// that vault reached over a stretch where Memoir recorded nothing at all.
    @Test("CF-70 a label is not carried across time Memoir did not witness")
    func labelIsNotCarriedAcrossAnOutage() {
        let project = makeEntity(kind: .project, title: "Fenwick Migration")
        let ontology = Ontology.build(from: [project])
        let app = "com.example.editor"

        // 09:00 — a screen naming the project, inside a session that runs to 09:10.
        let screen = Fixtures.capture(
            text: "fenwick migration notes", app: "Editor", bundleID: app,
            windowTitle: "fenwick migration", at: TestClock.minutes(0), name: "before")
        let watchedSession = Session(
            appBundleID: app, appName: "Editor",
            startedAt: TestClock.minutes(0), endedAt: TestClock.minutes(10))

        // 12:00 — three hours later, a session with no captures of its own. Inside the old
        // four-hour cap, so the old rule carried the 09:00 label into it.
        let laterSession = Session(
            appBundleID: app, appName: "Editor",
            startedAt: TestClock.minutes(180), endedAt: TestClock.minutes(185))

        // Case one: nothing was recorded in between. Memoir was not there.
        let acrossOutage = WorkSpanBuilder.spans(
            sessions: [watchedSession, laterSession], captures: [screen], ontology: ontology)
        let carriedLabels = acrossOutage
            .filter { $0.start >= TestClock.minutes(180) }
            .map(\.label)
        #expect(
            carriedLabels.allSatisfy { $0 == "Editor" },
            "a label crossed a hole in the recording: \(carriedLabels)"
        )

        // Case two: the same three hours, but Memoir was watching throughout — an idle
        // session bridges them. Idle is Memoir watching a screen saver, which is evidence it
        // was running. The carry is legitimate and must still happen.
        let bridge = Session(
            appBundleID: app, appName: "Editor",
            startedAt: TestClock.minutes(10), endedAt: TestClock.minutes(180), idle: true)
        let continuous = WorkSpanBuilder.spans(
            sessions: [watchedSession, bridge, laterSession], captures: [screen],
            ontology: ontology)
        let bridged = continuous
            .filter { $0.start >= TestClock.minutes(180) }
            .map(\.label)
        #expect(
            bridged.contains("Fenwick Migration"),
            "an unbroken watch stopped carrying a label it should carry: \(bridged)"
        )
    }

    @Test("CF-70 a short gap between sessions is bookkeeping, not an outage")
    func shortGapsDoNotBreakTheCarry() {
        // Ten seconds between two stretches: one session closing just before the next opens.
        // The record is continuous, so the reach goes all the way back.
        let continuous = WorkSpanBuilder.merged([
            (TestClock.minutes(0), TestClock.minutes(10)),
            (TestClock.minutes(10) + 10, TestClock.minutes(20)),
        ])
        // No hole was seen, so nothing is ruled out and `carryForward` remains the only
        // backstop. `.distantPast` is "no constraint", not "reach forever".
        #expect(
            WorkSpanBuilder.earliestWatched(before: TestClock.minutes(20), watched: continuous)
                == .distantPast,
            "a ten-second bookkeeping gap was read as an outage")

        // Ten minutes of nothing is an outage, and the reach stops on this side of it.
        let holed = WorkSpanBuilder.merged([
            (TestClock.minutes(0), TestClock.minutes(10)),
            (TestClock.minutes(20), TestClock.minutes(30)),
        ])
        #expect(
            WorkSpanBuilder.earliestWatched(before: TestClock.minutes(30), watched: holed)
                == TestClock.minutes(20),
            "the reach crossed a ten-minute hole in the recording")
    }

    /// An application may not name the work done inside it.
    ///
    /// Chrome ends every window title with "— Google Chrome". The moment an entity called
    /// "Google Chrome" existed, it matched every Chrome capture there was: on the real vault
    /// one such row — inferred, minted from a single title-only sighting in one afternoon —
    /// matched 47.3% of the whole corpus and inflated every coverage figure the product
    /// reported by about 13.6 points of the clock.
    ///
    /// Guarded twice, because the two failures are different. The matcher stops it labelling
    /// anything; `ExtractionBuilder.add` stops the row existing at all. A memory that quietly
    /// holds "Google Chrome" among the user's projects is wrong even on a day it bills nothing.
    @Test("CF-70 an app cannot name the work done inside it")
    func anAppIsNotAProject() {
        let chrome = makeEntity(kind: .project, title: "Google Chrome")
        let ontology = Ontology.build(from: [chrome])

        // The window title of every single Chrome capture ends this way.
        #expect(
            ontology.match(
                windowTitle: "Some page \u{2014} Google Chrome", text: "",
                appName: "Google Chrome") == nil,
            "the browser named the work done in the browser")

        // The same row cannot sneak in through the body either.
        #expect(
            ontology.match(
                windowTitle: nil, text: "downloaded with google chrome today",
                appName: "Google Chrome") == nil)

        // Exact match only: a project genuinely named after an app still labels.
        let realProject = makeEntity(kind: .project, title: "Notes for Chrome")
        let real = Ontology.build(from: [realProject])
        #expect(
            real.match(
                windowTitle: "Notes for Chrome \u{2014} Obsidian", text: "",
                appName: "Obsidian")?.entityID == realProject.id,
            "a real project whose name mentions an app must still label")

        // And the guard is scoped to the app it was read in, not applied globally.
        #expect(
            ontology.match(
                windowTitle: "Google Chrome \u{2014} release notes", text: "",
                appName: "Safari") != nil,
            "the guard fired for an app the capture did not come from")
    }

    /// The matcher stopped reading a capture one paragraph in.
    ///
    /// 600 characters was never the binding limit while the screen reader was returning almost
    /// nothing. Once it started returning ten thousand characters a capture, it was: on the
    /// clean corpus 4.1 of the 7.2 readable-but-unlabelled hours sat behind character 600.
    /// Memoir had stored the text and the name was in it.
    @Test("CF-70 a name past the first paragraph still labels")
    func matcherReadsPastTheOpeningParagraph() {
        let project = makeEntity(kind: .project, title: "Fenwick Migration")
        let ontology = Ontology.build(from: [project])
        let filler = String(repeating: "unrelated preamble about other matters. ", count: 40)
        #expect(filler.count > 600, "the fixture must actually push the name past the old cutoff")

        #expect(
            ontology.match(
                windowTitle: nil, text: filler + "and then the Fenwick Migration cutover.",
                appName: "Editor")?.entityID == project.id,
            "a name \(filler.count) characters in was not read")
    }

    @Test("CF-70 an authored note is not a project, whoever wrote it")
    func authoredNotesDoNotLabel() {
        // Obsidian filenames arrive as authored notes, and under the old rule they billed
        // hours on the real database: "Competitive Landscape" labelled 687 captures,
        // "Context" 241, "Architecture" 206. Having a note open is not what the hour was
        // about, and "Context, 2h" is a worse timesheet line than "Obsidian, 2h".
        let note = makeEntity(kind: .note, title: "Competitive Landscape", source: .authored)
        let ontology = Ontology.build(from: [note])
        #expect(ontology.isEmpty,
                "an authored note earned a needle: \(ontology.labels.map(\.title))")
        #expect(ontology.match(windowTitle: "Competitive Landscape \u{2014} Obsidian", text: "") == nil,
                "a note filename must not name a span of billable work")
    }

    @Test("CF-70 an authored person is not a project either")
    func authoredPeopleDoNotLabel() {
        // Contacts cards import as authored people and were the other half of it: the
        // user's own card labelled 756 captures, another contact 968. A name being on screen
        // says who was mentioned, never what the work was.
        //
        // The name here is invented. The real one is in the user's address book, and this
        // file mirrors to a public repository where git history is forever. The ø is kept
        // because it is the part that exercises `normalizedTitle`.
        let person = makeEntity(kind: .person, title: "Bo N\u{f8}rgaard", source: .authored)
        let ontology = Ontology.build(from: [person])
        #expect(ontology.isEmpty,
                "an authored person earned a needle: \(ontology.labels.map(\.title))")
        #expect(ontology.match(windowTitle: "Bo N\u{f8}rgaard \u{2014} Messages", text: "") == nil,
                "a contact's name must not name a span of billable work")
    }

    @Test("CF-70 kind decides what may label, and a project still does either way")
    func projectsLabelWhoeverWroteThem() {
        // The rule that replaced the hatch: kind decides admission, source only breaks a
        // tie between two names of equal length. A project the user typed in still labels.
        let authored = makeEntity(kind: .project, title: "Fenwick Migration", source: .authored)
        let authoredOntology = Ontology.build(from: [authored])
        #expect(authoredOntology.match(windowTitle: "fenwick migration \u{2014} notes", text: "")?.entityID
                == authored.id, "the user's own project must still label")

        // And a project Memoir inferred from the screen labels exactly as it did before:
        // nothing about the inferred path changed.
        let inferred = makeEntity(kind: .project, title: "Client Onboarding")
        #expect(inferred.source == .inferred, "the fixture must actually be inferred")
        let inferredOntology = Ontology.build(from: [inferred])
        #expect(inferredOntology.match(windowTitle: "Client Onboarding \u{2014} flows", text: "")?.entityID
                == inferred.id, "an inferred project labels exactly as it did before")
    }

    @Test("CF-70 the longest name wins over its own substring")
    func longestNameWins() {
        let migration = Entity(
            id: TestID.stable("entity", "project", "Fenwick Migration"),
            kind: .project, title: "Fenwick Migration",
            source: .authored, aliases: [],
            createdAt: TestClock.reference, updatedAt: TestClock.reference
        )
        let bare = Entity(
            id: TestID.stable("entity", "project", "Fenwick"),
            kind: .project, title: "Fenwick",
            createdAt: TestClock.reference, updatedAt: TestClock.reference
        )
        let ontology = Ontology.build(from: [migration, bare])
        let hit = ontology.match(windowTitle: "fenwick migration \u{2014} notes", text: "")
        #expect(hit?.entityID == migration.id)
    }
}
