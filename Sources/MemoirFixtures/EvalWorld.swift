//
//  EvalWorld.swift
//  The synthetic memory the answer evals are graded against.
//

import Foundation
import MemoirKit

/// A week of invented screen activity, written into a real store by the real pipeline.
///
/// ## Why this exists
///
/// `Evals/answers.json` used to be graded against the author's own database. That made 66 of
/// its 78 cases ungradeable anywhere else: a failure meant "this was never captured on your
/// Mac" at least as often as it meant "the answer is wrong", which is a suite that reports a
/// number without measuring anything. It also meant the eval corpus WAS one person's browsing
/// history, sitting in a repository about to go public.
///
/// So the world is invented, and every name in it is invented with it. What is not invented is
/// how it gets into the database: the captures go through `Store`, and the entities come out of
/// the real `RuleExtractor` and the real `MemoryService.consolidate`. An expectation is only
/// worth grading if the memory answering it is the memory the product would actually have built.
///
/// ## The shape of the week
///
/// Monday 16 March 2026, asked at 12:00 local: ``WorkingDay/askedAt``, the same instant the
/// integration suite uses, so one clock covers both. Today carries the app sessions the
/// `accounting` group does arithmetic over and the pages the `resumption` group reloads. The
/// ten days before it carry the pages the `recall` group has to reach back for, because
/// recall's whole job is the thing you saw last week and cannot find again.
///
/// ## What it does NOT do
///
/// It binds no support directory. It cannot: a module has no scope to bind one in. The caller
/// must, and `memoir-eval-seed` does: `MemoryService.consolidate` reads the real `asks.jsonl`
/// through `recentAnswerFingerprints()` and silently drops any capture whose first 50 collapsed
/// characters match something already logged there. Seeding without the override does not fail;
/// it quietly produces a smaller world on a machine that has used Memoir, and a different one
/// on every machine.
public enum EvalWorld {

    /// The instant every eval question is asked at. Shared with the integration suite.
    public static var now: Date { WorkingDay.askedAt }

    /// Local midnight before ``now``.
    public static var dayStart: Date { WorkingDay.dayStart }

    /// `h` hours and `m` minutes into the local day containing ``now``.
    public static func at(_ h: Int, _ m: Int, dayOffset: Int = 0) -> Date {
        let base = TestClock.localCalendar.date(
            bySettingHour: h, minute: m, second: 0, of: WorkingDay.askedAt)!
        return base.addingTimeInterval(Double(dayOffset) * 86_400)
    }

    // MARK: - Apps

    /// Bundle identifiers, so a session and its captures cannot disagree about what an app is.
    public enum App {
        public static let chrome = (name: "Google Chrome", bundle: "com.google.Chrome")
        public static let claude = (name: "Claude", bundle: "com.anthropic.claudefordesktop")
        public static let obsidian = (name: "Obsidian", bundle: "md.obsidian")
        public static let slack = (name: "Slack", bundle: "com.tinyspeck.slackmacgap")
        public static let notes = (name: "Notes", bundle: "com.apple.Notes")
    }

    // MARK: - Today's sessions
    //
    // The `accounting` group is arithmetic over this table and nothing else. Written as data so
    // the totals in `facts.json` are COMPUTED from it: an expectation that names a figure a
    // human copied by hand is a second source of truth waiting to disagree with the first.

    /// One app session on the seeded day: app, start minute, end minute, measured from midnight.
    public struct Span: Sendable {
        public let app: (name: String, bundle: String)
        public let from: (h: Int, m: Int)
        public let to: (h: Int, m: Int)
        public let idle: Bool

        /// How long this span ran, in whole minutes.
        public var minutes: Int { (to.h * 60 + to.m) - (from.h * 60 + from.m) }
    }

    /// The working morning, 08:45 to 11:58, with a gap for lunch that never happens.
    ///
    /// Chrome wins on total time by a wide margin and is split across three spans, which is the
    /// case that matters: "which app did I use most today" has to sum a column rather than pick
    /// the longest single row. Claude is the longest single session and would win a naive
    /// implementation, so a wrong answer here is a WRONG answer rather than a coin flip.
    public static let spans: [Span] = [
        Span(app: App.chrome, from: (8, 45), to: (9, 30), idle: false),   // 45
        Span(app: App.claude, from: (9, 30), to: (10, 25), idle: false),  // 55
        Span(app: App.obsidian, from: (10, 25), to: (10, 50), idle: false), // 25
        Span(app: App.chrome, from: (10, 50), to: (11, 35), idle: false), // 45
        Span(app: App.slack, from: (11, 35), to: (11, 50), idle: false),  // 15
        Span(app: App.chrome, from: (11, 50), to: (11, 58), idle: false), // 8
    ]

    /// Minutes per app on the seeded day, summed from ``spans``.
    public static var minutesByApp: [String: Int] {
        spans.reduce(into: [:]) { $0[$1.app.name, default: 0] += $1.minutes }
    }

    /// Total tracked minutes on the seeded day.
    public static var totalMinutes: Int { spans.map(\.minutes).reduce(0, +) }

    /// The app with the most tracked time, and its minutes.
    public static var topApp: (name: String, minutes: Int) {
        let best = minutesByApp.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }!
        return (best.key, best.value)
    }

    // MARK: - Facts
    //
    // Written next to the database so `Scripts/eval.sh` and anyone reading `answers.json` can
    // check a figure against what was actually seeded rather than against a memory of it.

    /// The measured arithmetic of a seeded world.
    public struct Facts: Codable, Sendable {
        public let reference: Date
        public let dayStart: Date
        public let minutesByApp: [String: Int]
        public let totalMinutes: Int
        public let topApp: String
        public let topAppMinutes: Int
        public let firstSessionStart: Date
        public let lastSessionEnd: Date
        public let captureCount: Int
        public let entityCount: Int
        public let entitiesByKind: [String: Int]
        public let openCommitments: [String]
        public let overdueCommitments: [String]
        public let projects: [String]
    }

    // MARK: - Seeding

    /// Writes the world and consolidates it, returning the measured facts.
    ///
    /// - Important: bind `Paths.$supportDirectoryOverride` around this call. See the type's
    ///   documentation for what happens if you do not.
    public static func seed(into store: Store) async throws -> Facts {
        let captures = self.captures()
        let sessions = spans.map { span in
            makeSession(
                appName: span.app.name, bundleID: span.app.bundle,
                from: at(span.from.h, span.from.m), to: at(span.to.h, span.to.m),
                idle: span.idle)
        }
        try await MemoirFixtures.seed(store: store, captures: captures, sessions: sessions)

        // Ten days back, so the `recall` group has something to reach for. `RuleExtractor` and
        // nothing else: `LLMExtractor` would put an on-device model in the middle of a fixture
        // and the whole point of this database is that two machines build the same one.
        let memory = MemoryService(store: store, extractors: [RuleExtractor()])
        let touched = try await memory.consolidate(
            since: dayStart.addingTimeInterval(-11 * 86_400), captureLimit: 5_000, now: now)
        guard touched > 0 else { throw FixtureError.seedProducedNothing("entities") }

        let entities = try await store.entities(kind: nil, includeDeleted: false)
        let open = entities.filter { $0.kind == .commitment && $0.completedAt == nil && !$0.provisional }
        let stats = try await store.stats()

        return Facts(
            reference: now,
            dayStart: dayStart,
            minutesByApp: minutesByApp,
            totalMinutes: totalMinutes,
            topApp: topApp.name,
            topAppMinutes: topApp.minutes,
            firstSessionStart: sessions.map(\.startedAt).min() ?? now,
            lastSessionEnd: sessions.map(\.endedAt).max() ?? now,
            captureCount: stats.captureCount,
            entityCount: entities.count,
            entitiesByKind: entities.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 },
            openCommitments: open.map(\.title).sorted(),
            overdueCommitments: open.filter { ($0.dueAt.map { $0 < now }) == true }
                .map(\.title).sorted(),
            projects: entities.filter { $0.kind == .project }.map(\.title).sorted()
        )
    }
}

// MARK: - The corpus

extension EvalWorld {

    /// One page, message or note that was on screen, and when.
    ///
    /// Written out longhand rather than generated. Every ranking, every citation and every
    /// refusal in the eval depends on the text being the kind of thing a person actually reads,
    /// and generated filler measures the generator.
    static func captures() -> [CaptureEvent] {
        var out: [CaptureEvent] = []

        func page(
            _ name: String, _ app: (name: String, bundle: String),
            _ title: String, _ text: String,
            _ h: Int, _ m: Int, day: Int = 0
        ) {
            out.append(Fixtures.capture(
                text: text, app: app.name, bundleID: app.bundle,
                windowTitle: title, at: at(h, m, dayOffset: day), name: name))
        }

        // MARK: Today, the morning the `resumption` and `accounting` groups read
        //
        // Ordered, and the order is load-bearing: "what did I look at most recently" and
        // "where did I leave off" both have to land on the LAST of these and not on the most
        // interesting one. The real failure they are written against was an answer five hours
        // stale, so the newest capture is deliberately the dullest.

        page("gh-afterglance", App.chrome,
             "n1ghtjar/Afterglance: AI-powered screen memory - Google Chrome",
             """
             github.com/n1ghtjar/Afterglance Address and search bar
             n1ghtjar/Afterglance: AI-powered screen memory \u{2014} captures, analyses and lets you \
             search or chat with your screen history. Star 2.1k Fork 143 Issues 27
             README.md. Afterglance quietly records what appears on your display and lets you \
             ask about it later in plain language, so the thing you glanced at on Tuesday is \
             still reachable on Friday. Everything stays on the machine and nothing is \
             uploaded. Installation requires a recent toolchain. MIT licence.
             """, 8, 47)

        page("gh-quillvox", App.chrome,
             "hollowmere/quillvox: local dictation for macOS - Google Chrome",
             """
             github.com/hollowmere/quillvox Address and search bar
             hollowmere/quillvox: local dictation for macOS. Press a key, talk, and the words \
             land in whatever window you were in. Runs a speech model on the device, so \
             nothing is sent anywhere. Star 884 Fork 61.
             Roadmap: punctuation model, per-app vocabularies, a menu bar meter.
             """, 8, 58)

        page("motionvane", App.chrome,
             "Motionvane \u{2014} motion design studio - Google Chrome",
             """
             motionvane.ai Address and search bar
             Motionvane. A motion design studio for product teams. We make the twelve seconds \
             between tapping a button and understanding what happened. Work, Studio, Contact.
             Selected work: Halden Bank onboarding, Verity Health scheduling, Pell & Ross \
             checkout. Get in touch at hello@motionvane.ai.
             """, 9, 8)

        page("tweet-claude-skills", App.chrome,
             "mirafenn on X: \"feels like Claude skills wrapped\" - Google Chrome",
             """
             x.com Address and search bar
             mirafenn on X: I am not a hater but this literally just feels like Claude skills \
             wrapped into a nice sms app layer. 412 reposts 3.1k likes.
             Replies: fair, though the distribution is the product. · the sms part is the \
             whole trick. · every wrapper says this until it does not.
             """, 9, 22)

        // The Claude desktop app, not a browser tab, so the assistant-tab filter leaves it
        // alone, as it should: this is the user's own planning, which is evidence.
        page("claude-planning", App.claude,
             "Claude",
             """
             Planning the Fenwick import rewrite. The second pass fails whenever a row has an \
             empty category, and the retry loop makes it worse because it re-reads the whole \
             file. Splitting the parse from the write is the smaller change.
             Next: land the split, then measure the second pass again before touching the \
             retry budget.
             """, 9, 44)

        page("claude-notch", App.claude,
             "Claude",
             """
             Asked about the notch overlay: the menu bar loses about 74 points of usable width \
             on the 14 inch display, so a status item past the eighth one is unreachable. \
             Options are a compact mode, an overflow menu, or moving the whole thing into a \
             panel under the notch.
             """, 10, 6)

        page("obsidian-release", App.obsidian,
             "Release checklist \u{2014} Ivorywood - Obsidian",
             """
             Release checklist \u{2014} Ivorywood
             - [ ] Fenwick import: second pass green on the 40k row file
             - [ ] Notch overlay behind a flag, default off
             - [ ] Accessibility pass on the panel
             - [x] Crash reporter opt-in copy reviewed
             Notes: the demo is Thursday. Keep the flag off until the accessibility pass lands.
             """, 10, 31)

        page("obsidian-weeknotes", App.obsidian,
             "Week notes \u{2014} 16 March - Obsidian",
             """
             Week notes \u{2014} 16 March
             Ivorywood is the whole week. The import is the risk; everything else is finishing.
             TODO: send the March invoice to Fenwick by Friday.
             Read this morning: Afterglance, quillvox. Both local-first, both doing the thing \
             from opposite ends.
             """, 10, 43)

        page("lumenfield", App.chrome,
             "Generate images from a prompt | Lumenfield - Google Chrome",
             """
             lumenfield.ai/create Address and search bar
             Generate images from a prompt | Lumenfield. Describe a scene, pick a style, and \
             Lumenfield renders it. Styles: editorial, matte, blueprint, long exposure.
             Recent: "a harbour at first light, matte" · "a wall of index cards, editorial".
             """, 10, 58)

        page("tempolog", App.chrome,
             "Tempolog \u{2014} where your day went - Google Chrome",
             """
             tempolog.com Address and search bar
             Tempolog \u{2014} where your day went. A menu bar timer that watches which app is in \
             front and scores the day. 16:00 · 88% productive.
             Pricing: free for one Mac, 4 EUR a month for the family plan.
             """, 11, 12)

        page("gh-notchbar", App.chrome,
             "sablequill/notchbar: reclaim the menu bar around the notch - Google Chrome",
             """
             github.com/sablequill/notchbar Address and search bar
             sablequill/notchbar: reclaim the menu bar around the notch. Moves overflowing \
             status items into a panel that hangs under the notch instead of vanishing behind \
             it. Star 3.4k Fork 210.
             Works on every display; the notch is only where the problem is loudest.
             """, 11, 26)

        page("slack-thread", App.slack,
             "#ivorywood - Kestrel",
             """
             Nadia Kerr  11:38
             The Fenwick import is still failing on the second pass. Can you take a look before \
             the demo?

             Rafi Osman  11:41
             We decided to keep the notch overlay off by default until the accessibility pass \
             is done.

             Nadia Kerr  11:44
             Also I will put the demo script in here tomorrow morning so nobody writes it twice.

             Rafi Osman  11:46
             Works for me. Let's walk through the release checklist at the Thursday sync.
             """, 11, 38)

        // The last thing on screen, and deliberately unremarkable. "Where did I leave off"
        // must answer with THIS rather than with the most interesting page of the morning.
        page("macmini", App.chrome,
             "Mac mini M4 - Technical Specifications - Google Chrome",
             """
             support.apple.com Address and search bar
             Mac mini M4 - Technical Specifications. Chip: M4 with 10-core CPU. Memory: 16GB \
             unified, configurable to 32GB. Ports: two USB-C on the front, three Thunderbolt \
             on the back, HDMI, Ethernet.
             Height 5.0 cm, width and depth 12.7 cm, weight 0.67 kg.
             """, 11, 53)

        // MARK: The days before
        //
        // `recall` is the group that has to reach back. Everything here is older than today
        // and none of it is reachable from the resumption window, which is the point: a
        // question about last Thursday must not be answered from this morning.

        page("tamagotchi", App.chrome,
             "Tamagotchi Uni review \u{2014} the pet is the point - Google Chrome",
             """
             thewirefold.com Address and search bar
             Tamagotchi Uni review \u{2014} the pet is the point. Thirty years on, the appeal has not \
             moved: a small demanding thing that notices whether you showed up. The colour \
             screen and the wifi are beside the point.
             Related: the Tamagotchi patent drawings, and why every pet app copies the egg.
             """, 15, 20, day: -4)

        page("notes-invoice", App.notes,
             "Fenwick - March",
             """
             Fenwick \u{2014} March
             Scope: import rewrite, two weeks. Rate agreed on the call.
             TODO: send the February invoice to Fenwick by Friday.
             Ask Nadia for the new PO number before invoicing.
             """, 16, 5, day: -4)

        page("gh-halden", App.chrome,
             "brackenmoor/halden: a tiny state machine for Swift - Google Chrome",
             """
             github.com/brackenmoor/halden Address and search bar
             brackenmoor/halden: a tiny state machine for Swift. Declare states and the \
             transitions between them; anything else is a compile error. No dependencies, one \
             file, 400 lines. Star 612 Fork 39.
             """, 10, 10, day: -6)

        page("obsidian-ivorywood", App.obsidian,
             "Ivorywood \u{2014} the shape of it - Obsidian",
             """
             Ivorywood \u{2014} the shape of it
             The product is one question: what did I already look at. Everything else is \
             plumbing. Keep the capture cheap, keep the memory honest, and refuse rather than \
             guess.
             Open: how much of the week to keep, and whether the panel or the menu bar is home.
             """, 14, 30, day: -10)

        return out
    }
}
