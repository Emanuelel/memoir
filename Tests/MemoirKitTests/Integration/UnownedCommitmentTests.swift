import Foundation
import Testing
import MemoirFixtures
@testable import MemoirKit

// CF-79: a promise has to be yours.
//
// A browser shows you other people's first-person sentences all day. Measured on a real
// database: 25 stored commitments, 17 of them somebody else's words read off a web page:
// a tweet, a LinkedIn reply, an AI-drafted email, the user's own landing-page copy, every
// one presented as something they owed. Kept, because the text is real; never asserted,
// because inventing an obligation is the worst thing this product can do.

@Suite("CF-79 a promise has to be yours")
struct UnownedCommitmentTests {

    /// The real sentences that motivated this, as they were captured.
    private static let readSentences = [
        "I'll have to check out your post",
        "AI Draft: Sounds great, Thursday at 3pm works on my end. I'll send the deck over.",
        "Memoir is a macOS menu-bar app that quietly builds a memory of your working day.",
    ]

    private func browserCapture(_ text: String, at ts: Date, name: String) -> CaptureEvent {
        Fixtures.capture(
            text: text, app: "Google Chrome", bundleID: "com.google.Chrome",
            windowTitle: "LinkedIn", at: ts, name: name
        )
    }

    /// Every tab is a reading surface, including the ones people write in.
    ///
    /// This case used to assert the opposite, and the reasoning behind it was good: half the
    /// tools people write in are web apps, and a promise typed into a pull request is as real
    /// as one typed into Notes. So a host allowlist — pull requests, inboxes, chats — exempted
    /// those tabs from the reading rule.
    ///
    /// It is reversed here on evidence the original decision did not have. Being somewhere you
    /// COULD have written a sentence is not evidence that you did, and you read a pull request
    /// far more often than you write one. Measured on a real memory: 308 open commitments came
    /// from a browser and only 59 carried the flag, because the rest sat on allowlisted hosts
    /// — against ONE commitment the user actually authored in seventy-five days. The three
    /// loudest were a marketing email about a workshop and two sentences lifted out of the
    /// user's own essay, each given a due date and shown back as a debt.
    ///
    /// `provisional` deletes nothing. The row is kept, searchable and citable, and only barred
    /// from being asserted as something the user owes. A missed promise is recoverable — PUSH
    /// exists, and one sentence restores it — and an invented one is not. The allowlist was on
    /// the wrong side of that asymmetry.
    @Test("CF-79 every tab is a reading surface, including the ones people write in")
    func everyTabIsAReadingSurface() {
        // A pull request. The user may well have typed this; the record cannot show it.
        let pr = Fixtures.capture(
            text: "I'll cut the release once this lands.", app: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "Add rate limiter backoff by priya-r - Pull Request #482 - acme/platform",
            at: TestClock.reference, name: "pr"
        )
        #expect(RuleExtractor.isReadingSurface(pr),
                "a tab was exempted because of where it was, not because of who wrote it")

        // An inbox: other people's words by construction.
        let inbox = Fixtures.capture(
            text: "I'll send the deck over on Thursday.", app: "Google Chrome",
            bundleID: "com.google.Chrome", windowTitle: "Inbox - Gmail",
            at: TestClock.reference, name: "inbox"
        )
        #expect(RuleExtractor.isReadingSurface(inbox))

        // A feed, which was never in doubt.
        let feed = Fixtures.capture(
            text: "I'll have to check out your post", app: "Google Chrome",
            bundleID: "com.google.Chrome", windowTitle: "Feed | LinkedIn",
            at: TestClock.reference, name: "feed"
        )
        #expect(RuleExtractor.isReadingSurface(feed))

        // And a native editor is still not a reading surface: the rule is about browsers.
        let notes = Fixtures.capture(
            text: "I'll cut the release once this lands.", app: "Notes",
            bundleID: "com.apple.Notes", windowTitle: "Release plan",
            at: TestClock.reference, name: "notes"
        )
        #expect(!RuleExtractor.isReadingSurface(notes))
    }

    @Test("CF-79 a browser is a reading surface; a note is not")
    func classifiesSurfaces() {
        let page = browserCapture("anything", at: TestClock.reference, name: "page")
        #expect(RuleExtractor.isReadingSurface(page))

        let note = Fixtures.capture(
            text: "anything", app: "Notes", bundleID: "com.apple.Notes",
            windowTitle: "Today", at: TestClock.reference, name: "note"
        )
        #expect(!RuleExtractor.isReadingSurface(note), "somewhere the user writes is not reading")

        // An assistant tab is handled upstream and more strictly; it must not be double-counted
        // as merely "reading", or the stricter rule would be bypassed.
        let claude = Fixtures.capture(
            text: "anything", app: "Google Chrome", bundleID: "com.google.Chrome",
            windowTitle: "claude.ai: a conversation", at: TestClock.reference, name: "claude"
        )
        #expect(!RuleExtractor.isReadingSurface(claude))
        #expect(RuleExtractor.isAssistantSurface(claude))
    }

    @Test("CF-79 commitments read off a page are stored but never surfaced")
    func readCommitmentsAreProvisional() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])

            for (i, text) in Self.readSentences.enumerated() {
                try await store.insert(capture: browserCapture(
                    text, at: TestClock.minutes(Double(i)), name: "read-\(i)"
                ))
            }
            // And one the user genuinely wrote, somewhere they write.
            try await store.insert(capture: Fixtures.capture(
                text: "I'll send Marco the migration notes by Friday.",
                app: "Notes", bundleID: "com.apple.Notes",
                windowTitle: "Work", at: TestClock.minutes(10), name: "written"
            ))
            _ = try await memory.consolidate(since: TestClock.reference, now: TestClock.minutes(11))

            let stored = try await store.entities(kind: .commitment, includeDeleted: false)
            let surfaced = try await store.openCommitments(now: TestClock.minutes(11))

            // Nothing is thrown away…
            #expect(!stored.isEmpty, "the text is real and stays in memory")
            // …but nothing read off a page is ever presented as a promise.
            #expect(surfaced.allSatisfy { !$0.provisional })
            for commitment in surfaced {
                #expect(!Self.readSentences.contains(where: { $0.contains(commitment.title) }),
                        "a sentence read on a web page was surfaced as owed: \(commitment.title)")
            }

            // The strip's counts are assertions too.
            let counts = try await store.commitmentCounts(now: TestClock.minutes(11))
            let provisionalDue = stored.filter { $0.provisional && $0.dueAt != nil }.count
            #expect(counts.overdue + counts.dueToday <= stored.count - provisionalDue)
        }
    }

    @Test("CF-79 a provisional commitment graduates when the user writes it themselves")
    func provisionalClearsOnRealAuthorship() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let text = "I'll send Marco the migration notes by Friday."

            // First seen on a page…
            try await store.insert(capture: browserCapture(text, at: TestClock.reference, name: "seen"))
            _ = try await memory.consolidate(since: TestClock.reference, now: TestClock.minutes(1))
            let afterReading = try await store.entities(kind: .commitment, includeDeleted: false)
            #expect(afterReading.allSatisfy { $0.provisional }, "read first, so unowned")

            // …then written by the user in their own notes.
            try await store.insert(capture: Fixtures.capture(
                text: text, app: "Notes", bundleID: "com.apple.Notes",
                windowTitle: "Work", at: TestClock.minutes(5), name: "wrote"
            ))
            _ = try await memory.consolidate(since: TestClock.reference, now: TestClock.minutes(6))

            let after = try await store.entities(kind: .commitment, includeDeleted: false)
            #expect(after.contains { !$0.provisional },
                    "ownership established elsewhere must clear the doubt")
        }
    }

    @Test("CF-79 the sweep demotes what the old extractor already stored")
    func demotesExistingRows() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])

            // A row written before the guard existed: not provisional, browser-only evidence.
            let capture = browserCapture(Self.readSentences[0], at: TestClock.reference, name: "legacy")
            let legacy = makeEntity(kind: .commitment, title: Self.readSentences[0])
            try await seed(store: store, captures: [capture], entities: [legacy],
                           provenance: [makeProvenance(entityID: legacy.id, captureID: capture.id,
                                                       snippet: Self.readSentences[0])])
            // And one with evidence from somewhere the user writes, which must be left alone.
            let realCapture = Fixtures.capture(
                text: "I'll file the tax return by Friday.", app: "Notes",
                bundleID: "com.apple.Notes", windowTitle: "Work",
                at: TestClock.minutes(1), name: "real"
            )
            let real = makeEntity(kind: .commitment, title: "I'll file the tax return by Friday.")
            try await seed(store: store, captures: [realCapture], entities: [real],
                           provenance: [makeProvenance(entityID: real.id, captureID: realCapture.id,
                                                       snippet: "I'll file the tax return by Friday.")])

            let preview = try await memory.demoteUnownedCommitments(dryRun: true)
            #expect(preview.count == 1, "only the browser-only row")
            #expect(preview.first?.id == legacy.id)
            // A dry run changes nothing.
            let beforeApply = try await store.entity(id: legacy.id)
            #expect(beforeApply?.provisional == false)

            _ = try await memory.demoteUnownedCommitments()
            let afterLegacy = try await store.entity(id: legacy.id)
            let afterReal = try await store.entity(id: real.id)
            #expect(afterLegacy?.provisional == true)
            #expect(afterReal?.provisional == false,
                    "a commitment with evidence from a writing surface is untouched")
        }
    }

    @Test("CF-79 what the user authored or corrected is never demoted")
    func neverDemotesAuthored() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])

            let capture = browserCapture("I'll renew the domain.", at: TestClock.reference, name: "page")
            var pushed = makeEntity(kind: .commitment, title: "I'll renew the domain.")
            pushed.source = .authored
            var corrected = makeEntity(kind: .commitment, title: "I'll post on LinkedIn.")
            corrected.corrected = true
            try await seed(
                store: store, captures: [capture], entities: [pushed, corrected],
                provenance: [
                    makeProvenance(entityID: pushed.id, captureID: capture.id, snippet: "x"),
                    makeProvenance(entityID: corrected.id, captureID: capture.id, snippet: "y"),
                ]
            )

            let demoted = try await memory.demoteUnownedCommitments(dryRun: true)
            #expect(demoted.isEmpty, "a promise the user typed is theirs whatever was on screen")
        }
    }
}

@Suite("CF-74 vault aliases are derived, not only declared")
struct VaultAliasDerivationTests {

    @Test("CF-74 a daily-note date prefix yields the subject as an alias")
    func stripsDatePrefix() {
        let aliases = VaultImporter.derivedAliases(
            title: "2026-07-14 AI companies hiring remote Spain",
            fileName: "2026-07-14 AI companies hiring remote Spain"
        )
        #expect(aliases.contains("AI companies hiring remote Spain"))
    }

    @Test("CF-74 separators become spaces")
    func splitsSeparators() {
        let aliases = VaultImporter.derivedAliases(
            title: "vault-inbox-wiring-test", fileName: "vault-inbox-wiring-test"
        )
        #expect(aliases.contains("vault inbox wiring test"))
    }

    @Test("CF-74 a short or generic name is never made an alias")
    func refusesWeakAliases() {
        // "notes" would attach half the day to one entity.
        #expect(VaultImporter.derivedAliases(title: "notes", fileName: "notes").isEmpty)
        #expect(VaultImporter.derivedAliases(title: "todo", fileName: "todo").isEmpty)
        #expect(VaultImporter.derivedAliases(title: "API", fileName: "API").isEmpty)
    }

    @Test("CF-74 derived aliases reach the store and match on screen")
    func aliasesMatchCaptures() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let vault = ws.root.appending(path: "Vault/Projects")
            try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
            try "# Hermes Agent Setup\n\nWiring the agent.\n".write(
                to: vault.appending(path: "hermes-agent-setup.md"), atomically: true, encoding: .utf8)

            _ = try await memory.importVault(at: ws.root.appending(path: "Vault"),
                                             now: TestClock.reference)
            let projects = try await store.entities(kind: nil, includeDeleted: false)
            let hermes = try #require(projects.first { $0.title.localizedCaseInsensitiveContains("hermes") })
            #expect(!hermes.aliases.isEmpty, "a note with no aliases: field still gets usable names")
            #expect(hermes.source == .authored)
        }
    }
}
