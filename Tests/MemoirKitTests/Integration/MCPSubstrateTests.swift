import Foundation
import Testing
import MemoirFixtures
@testable import MemoirKit

// CF-35: the substrate tools answer, with provenance, without writing.
// The seven additions (what_changed_since, prior_art, working_set, sources_for,
// verify, timesheet, propose_memory) ride the same subprocess contract as the
// original five: real binary, real stdio, real read-only database.
//
// CF-77: an agent proposal is staged, never recorded. `propose_memory` writes to a
// review file next to the database; the database itself is untouched, and only an
// explicit accept in the app turns a proposal into memory. CF-51 is the same law for
// what the user says out loud; this is the law for what an agent suggests.

@Suite("CF-35 substrate tools", .serialized)
struct MCPSubstrateTests {

    @Test("CF-35 every new read-only tool answers from the seeded database")
    func substrateToolsAnswer() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            let dbBefore = try FileFingerprint.of(ws.dbURL)

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            func answer(
                _ name: String,
                _ arguments: [String: Any],
                id: Int,
                sourceLocation: SourceLocation = #_sourceLocation
            ) async throws -> String {
                let frame = try await server.callTool(name, arguments: arguments, id: id, sourceLocation: sourceLocation)
                #expect(frame.error == nil, "\(name) protocol error: \(frame.line)", sourceLocation: sourceLocation)
                let text = try #require(frame.contentText, "\(name) malformed content: \(frame.line)", sourceLocation: sourceLocation)
                #expect(!text.isEmpty, "\(name) answered with nothing", sourceLocation: sourceLocation)
                return text
            }

            // what_changed_since: the March seed is all "new" against a March 1 baseline.
            let changed = try await answer("what_changed_since", ["since": "2026-03-01"], id: 20)
            #expect(changed.contains("New in memory"), "seeded entities are new against the baseline:\n\(changed)")
            #expect(changed.contains(MCPSeed.project))

            // prior_art: dated history for a topic, first-seen first.
            let art = try await answer("prior_art", ["topic": "rate limiter"], id: 21)
            #expect(art.contains("First seen"), "prior_art must date the history:\n\(art)")
            #expect(art.contains("Timeline"))
            #expect(art.contains(MCPSeed.busiestApp), "the Slack sighting must appear")

            // prior_art on genuinely new ground says so.
            let fresh = try await answer("prior_art", ["topic": "zeppelin mainframe cobol"], id: 22)
            #expect(fresh.contains("new ground"), "no history must be said plainly:\n\(fresh)")

            // working_set: seeded data is months old, so the honest shape is the
            // fallback; either way it answers and names real activity.
            let workingSet = try await answer("working_set", [:], id: 23)
            #expect(workingSet.contains("# Working set"))

            // sources_for: quoted evidence with app and timestamp.
            let sources = try await answer("sources_for", ["claim": "rate limiter fix"], id: 24)
            #expect(sources.contains("# Sources for"))
            #expect(sources.contains(">"), "evidence must be quoted, not paraphrased")
            #expect(sources.contains(MCPSeed.busiestApp))

            // sources_for with no evidence is honest about absence and its limits.
            let noSources = try await answer("sources_for", ["claim": "zeppelin mainframe cobol"], id: 25)
            #expect(noSources.contains("No evidence in the record"))
            #expect(noSources.contains("not disproof"), "absence of evidence must carry the coverage caveat")

            // verify: the seed is historical, so evidence exists and is dated; the
            // tool must find it and state its epistemics.
            let verify = try await answer("verify", ["claim": "rate limiter"], id: 26)
            #expect(!verify.contains("Not in the record"), "seeded evidence exists:\n\(verify)")
            // The promise is narrower than it used to be, on purpose. It used to say
            // "Supported by fresh evidence", which reads as endorsement of the claim; what it
            // can actually observe is that some words were near each other on a screen.
            #expect(verify.contains("appeared together"),
                    "verify must say what it observed:\n\(verify)")
            #expect(verify.contains("not that the claim is true") || verify.contains("not confirmation"),
                    "verify must state its limit:\n\(verify)")
            #expect(!verify.contains("Supported by fresh evidence"),
                    "the endorsement wording is back:\n\(verify)")

            let unverifiable = try await answer("verify", ["claim": "zeppelin mainframe cobol"], id: 27)
            #expect(unverifiable.contains("Not in the record"))

            // timesheet: 40m Slack + 15m Mail seeded in March; idle excluded.
            let sheet = try await answer("timesheet", ["from": "2026-03-01", "to": "2026-03-31"], id: 28)
            #expect(sheet.contains("# Timesheet"), "\(sheet)")
            #expect(sheet.contains("Total: 55m"), "40m Slack + 15m Mail, idle excluded:\n\(sheet)")
            #expect(!sheet.contains("Screen Saver"), "idle time belongs to nobody")

            // The whole battery of new tools wrote nothing (CF-33 extended).
            let status = await server.waitForExit()
            #expect(status == 0)
            let dbAfter = try FileFingerprint.of(ws.dbURL)
            #expect(dbBefore == dbAfter, "read-only tools must leave the database byte-identical")
            expectPureJSONStdout(server)
        }
    }

    @Test("CF-80 verify certifies only what the record actually says")
    func verifyRefusesUnsupportedClaims() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            func verify(_ claim: String, id: Int) async throws -> String {
                let frame = try await server.callTool("verify", arguments: ["claim": claim], id: id)
                #expect(frame.error == nil, "verify protocol error: \(frame.line)")
                return try #require(frame.contentText)
            }

            // A claim the record genuinely carries is supported.
            let real = try await verify(MCPSeed.project, id: 70)
            #expect(real.contains("evidence") || real.contains("Stale"),
                    "a claim the record does carry must be dated:\n\(real)")

            // Everything below is FALSE. Each was certified "supported by fresh evidence"
            // by the first implementation, because the search fell back to OR and a claim
            // full of stopwords matches every capture ever taken. A tool whose whole job
            // is catching stale claims certifying "the moon is made of cheese" is the
            // worst failure this product can have: confident, cited, and wrong.
            // The invariant is that verify never VOUCHES for these, not that it uses one
            // particular sentence. Both refusals are honest: "not in the record" when the
            // words were looked for and missing, "cannot verify" when the claim carries no
            // distinctive words to look for at all. What it may never do is date evidence.
            for (index, claim) in [
                "the moon is made of cheese",
                "the database runs on PostgreSQL",
                "zzzqqq nonexistent token",
                "everything is fine and nothing is the matter",
            ].enumerated() {
                let answer = try await verify(claim, id: 71 + index)
                #expect(!answer.contains("Supported by fresh evidence"),
                        "verify vouched for \"\(claim)\":\n\(answer)")
                #expect(!answer.contains("**Stale."),
                        "verify dated evidence for \"\(claim)\", which the record does not carry:\n\(answer)")
                #expect(answer.contains("Not in the record") || answer.contains("Cannot verify"),
                        "verify must refuse \"\(claim)\" plainly:\n\(answer)")
            }

            // A claim of nothing but common words has nothing to look for, and must say
            // that rather than match the whole corpus.
            let empty = try await verify("the and of is a", id: 80)
            #expect(empty.contains("Cannot verify"), "no distinctive terms must be named as the reason:\n\(empty)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-86 sources_for quotes only captures that carry the claim")
    func sourcesForRefusesUnsupportedClaims() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            func sources(_ claim: String, id: Int) async throws -> String {
                let frame = try await server.callTool("sources_for", arguments: ["claim": claim], id: id)
                #expect(frame.error == nil, "sources_for protocol error: \(frame.line)")
                return try #require(frame.contentText)
            }

            // A claim the record genuinely carries is still quoted, with provenance.
            let real = try await sources(MCPSeed.project, id: 100)
            #expect(real.contains("# Sources for"), "a supported claim must still be sourced:\n\(real)")
            #expect(real.contains(">"), "evidence must be quoted, not paraphrased:\n\(real)")

            // Everything below is unsupported. The first implementation handed back the most
            // recent captures for each of them (correctly attributed, entirely irrelevant)
            // because search widens to OR and then falls through to recency. An agent is told
            // to cite this rather than assert, so it cited a villa advert as architecture
            // evidence. The invariant is that nothing is QUOTED for a claim the record does
            // not carry; which of the two honest refusals it gives does not matter.
            for (index, claim) in [
                "the moon is made of cheese",
                "the database runs on PostgreSQL",
                "zzzqqq nonexistent token",
                "everything is fine and nothing is the matter",
            ].enumerated() {
                let answer = try await sources(claim, id: 101 + index)
                #expect(!answer.contains("# Sources for"),
                        "sources_for furnished evidence for \"\(claim)\":\n\(answer)")
                #expect(answer.contains("No evidence in the record") || answer.contains("Cannot source"),
                        "sources_for must refuse \"\(claim)\" plainly:\n\(answer)")
            }

            // Refusal names what it looked for, so the caller can tell a bad claim from a
            // bad query: the difference between "not on record" and "you asked wrong".
            let named = try await sources("zzzqqq nonexistent token", id: 110)
            #expect(named.contains("Looked for:"), "an absence must say what was sought:\n\(named)")

            // A claim of nothing but common words has nothing to look for, and must say so
            // rather than match the whole corpus.
            let empty = try await sources("the and of is a", id: 111)
            #expect(empty.contains("Cannot source"), "no distinctive terms must be named as the reason:\n\(empty)")

            // The same page captured over and over is one source, not many. A tab left open
            // produces a capture a minute; before the collapse, a claim came back with twelve
            // citations that were twelve photographs of one screen. A reader counts a list of
            // sources as corroboration, so repetition forges it.
            let repeated = "quenchberry telemetry handshake"
            let repeatStore = try await ws.store()
            for minute in 1...9 {
                try await repeatStore.insert(capture: Fixtures.capture(
                    text: "Design notes for the \(repeated) and the rollout plan behind it.",
                    app: "Google Chrome", bundleID: "com.google.Chrome",
                    windowTitle: "Design notes", at: TestClock.minutes(Double(-minute)), name: "repeat-\(minute)"
                ))
            }
            await repeatStore.close()

            let dupeServer = try startMCPServer(ws, database: ws.dbURL)
            defer { dupeServer.stop() }
            try await dupeServer.handshake()
            let dupeFrame = try await dupeServer.callTool("sources_for", arguments: ["claim": repeated], id: 140)
            let dupes = try #require(dupeFrame.contentText)
            let quoted = dupes.components(separatedBy: "\n  > ").count - 1
            #expect(quoted == 1, "nine captures of one page must collapse to one source, got \(quoted):\n\(dupes)")

            // sources_for and verify stand on the same floor: they may not disagree about
            // whether the record carries a claim. Disagreement is how the villa got cited.
            for (index, claim) in ["the moon is made of cheese", MCPSeed.project].enumerated() {
                let sourced = try await sources(claim, id: 120 + index)
                let frame = try await server.callTool("verify", arguments: ["claim": claim], id: 130 + index)
                let verified = try #require(frame.contentText)
                let sourcedFound = sourced.contains("# Sources for")
                let verifiedFound = !verified.contains("Not in the record") && !verified.contains("Cannot verify")
                #expect(sourcedFound == verifiedFound,
                        "sources_for and verify disagree on \"\(claim)\" (sourced: \(sourcedFound), verified: \(verifiedFound))")
            }

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-95 the answer names the work, not the window it happened in")
    func whatHappenedNamesTheWork() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)

            // An hour in an editor, on a named piece of work. Before this, the only thing
            // the answer could say about it was "Xcode", which is the one thing the user
            // already knew. The ontology has carried project names since CF-76 and the
            // timesheet has used them; this tool aggregated raw session app names instead.
            let project = makeEntity(
                id: TestID.stable("cf95", "migration"),
                kind: .project,
                title: "Schema migration",
                detail: "Repository",
                confidence: 0.9
            )
            try await store.upsert(entity: project)
            let start = TestClock.hours(-3)
            try await store.upsert(session: Session(
                id: TestID.stable("cf95", "session"),
                appBundleID: "com.apple.dt.Xcode",
                appName: "Xcode",
                startedAt: start,
                endedAt: start.addingTimeInterval(3_600),
                idle: false
            ))
            for minute in stride(from: 0, to: 60, by: 10) {
                try await store.insert(capture: Fixtures.capture(
                    text: "Schema migration: adding the supplementary column",
                    app: "Xcode", bundleID: "com.apple.dt.Xcode",
                    windowTitle: "Schema migration",
                    at: start.addingTimeInterval(Double(minute) * 60),
                    name: "cf95-\(minute)"
                ))
            }
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let from = ISO8601DateFormatter().string(from: start.addingTimeInterval(-3_600))
            let to = ISO8601DateFormatter().string(from: start.addingTimeInterval(7_200))
            let frame = try await server.callTool(
                "what_happened", arguments: ["from": from, "to": to], id: 210
            )
            #expect(frame.error == nil, "what_happened protocol error: \(frame.line)")
            let text = try #require(frame.contentText)

            #expect(text.contains("Schema migration"),
                    "the answer must name the work, not just the app:\n\(text)")

            // And unlabelled time is still never guessed into a project. The rule that
            // makes the timesheet's totals trustworthy applies here unchanged.
            #expect(text.contains("## What the time went on"), "\(text)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-98 time nothing can name still says what was on the screen")
    func unlabelledTimeNamesTheScreen() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)

            // An hour in an app, on a subject the ontology has never heard of. Before this
            // the whole answer was "Claude, 1h", which is the one fact the user already
            // had. The window title knew all along.
            let start = TestClock.hours(-5)
            try await store.upsert(session: Session(
                id: TestID.stable("cf98", "session"),
                appBundleID: "com.figma.Desktop", appName: "Figma",
                startedAt: start, endedAt: start.addingTimeInterval(3_600), idle: false
            ))
            for minute in stride(from: 0, to: 60, by: 10) {
                try await store.insert(capture: Fixtures.capture(
                    text: "working through the paywall copy",
                    app: "Figma", bundleID: "com.figma.Desktop",
                    // The badge and the trailing app name are both chrome, and the badge
                    // changes on every capture: left in, one page looks like six.
                    windowTitle: "(\(minute)) Paywall copy rewrite - Figma",
                    at: start.addingTimeInterval(Double(minute) * 60), name: "cf98-\(minute)"
                ))
            }
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let iso = ISO8601DateFormatter()
            let frame = try await server.callTool("what_happened", arguments: [
                "from": iso.string(from: start.addingTimeInterval(-600)),
                "to": iso.string(from: start.addingTimeInterval(7_200)),
            ], id: 220)
            #expect(frame.error == nil, "what_happened protocol error: \(frame.line)")
            let text = try #require(frame.contentText)

            #expect(text.contains("Paywall copy rewrite"),
                    "unlabelled time must still say what was on screen:\n\(text)")
            #expect(!text.contains("(0) Paywall"), "the unread badge is chrome:\n\(text)")
            #expect(!text.contains("Paywall copy rewrite - Figma"),
                    "the app name is stapled on by the window manager, not part of the subject:\n\(text)")
            // Still honest that this is a screen, not a project Memoir knows.
            #expect(text.contains("_unlabelled_"), "a caption is not an attribution:\n\(text)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-99 a caption never out-measures the row it captions")
    func captionsAreAShareOfMeasuredTime() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)

            // Ten minutes of work, and an hour of captures: the window stayed open while the
            // app was not frontmost, which is ordinary. Derived from capture spacing alone
            // the subject would claim an hour beside a row measured at ten minutes: on the
            // real database a row of 11m listed subjects summing to 57m.
            let start = TestClock.hours(-6)
            try await store.upsert(session: Session(
                id: TestID.stable("cf99", "session"),
                appBundleID: "com.figma.Desktop", appName: "Figma",
                startedAt: start, endedAt: start.addingTimeInterval(600), idle: false
            ))
            for minute in stride(from: 0, to: 60, by: 5) {
                try await store.insert(capture: Fixtures.capture(
                    text: "still on the paywall board",
                    app: "Figma", bundleID: "com.figma.Desktop",
                    windowTitle: "Paywall board - Figma",
                    at: start.addingTimeInterval(Double(minute) * 60), name: "cf99-\(minute)"
                ))
            }
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let iso = ISO8601DateFormatter()
            let frame = try await server.callTool("what_happened", arguments: [
                "from": iso.string(from: start.addingTimeInterval(-600)),
                "to": iso.string(from: start.addingTimeInterval(7_200)),
            ], id: 230)
            let text = try #require(frame.contentText)
            let row = try #require(
                text.split(separator: "\n").first { $0.contains("Paywall board") }.map(String.init)
            )

            // Ten measured minutes, and the caption describes those ten, not the hour the
            // window happened to be open for. CF-76's totals are the arithmetic.
            #expect(row.contains("10m"), "the measured total must survive:\n\(row)")
            #expect(!row.contains("(1h"), "the caption out-measured its own row:\n\(row)")
            #expect(!row.contains("(55m"), "the caption out-measured its own row:\n\(row)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-94 the handshake answers in the version the client asked for")
    func protocolVersionIsNegotiated() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            func handshake(asking version: String) async throws -> (version: String?, answered: Bool) {
                let server = try startMCPServer(ws, database: ws.dbURL)
                defer { server.stop() }
                let initialize = try await server.request(
                    "initialize",
                    params: [
                        "protocolVersion": version,
                        "capabilities": [String: Any](),
                        "clientInfo": ["name": "probe", "version": "1.0.0"],
                    ],
                    id: 1
                )
                try server.notify("notifications/initialized")
                let call = try await server.callTool("today", id: 2)
                return (initialize.result?["protocolVersion"] as? String, call.contentText != nil)
            }

            // Structured content needs 2025-06-18, so that is what this server prefers,
            // but the newest revision is not the server's to announce. A client that opens
            // with 2024-11-05 and is answered with a protocol it never offered is entitled
            // to hang up, and the whole connection would be lost to gain a field that client
            // was always going to ignore. Both must be answered, and answered in kind.
            let old = try await handshake(asking: "2024-11-05")
            #expect(old.version == "2024-11-05", "the client's own version must come back: \(String(describing: old.version))")
            #expect(old.answered, "an older client must still get its answers")

            let new = try await handshake(asking: "2025-06-18")
            #expect(new.version == "2025-06-18")
            #expect(new.answered)

            // Something we do not speak falls back to what we prefer, per the spec.
            let alien = try await handshake(asking: "1999-01-01")
            #expect(alien.version == "2025-06-18", "an unknown revision must be answered with ours")
        }
    }

    @Test("CF-91 open_commitments narrows to one person, by the conversation around it")
    func openCommitmentsScopesToAPerson() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)

            // The promise never says who it is to. "I'll get the invoice over to you this
            // week" names nobody; the thread it was typed into does. Scoping on the
            // commitment text alone would answer "what did I tell Marco" with nothing.
            let capture = Fixtures.capture(
                text: "Marco: any news on the invoice?\nMe: I'll get the invoice over to you this week",
                app: "WhatsApp", bundleID: "net.whatsapp.WhatsApp",
                windowTitle: "Marco \u{2014} WhatsApp", at: TestClock.minutes(-30), name: "marco-thread"
            )
            try await store.insert(capture: capture)
            let promise = makeEntity(
                id: TestID.stable("scope", "invoice"),
                kind: .commitment,
                title: "I'll get the invoice over to you this week",
                detail: "Commitment in WhatsApp",
                confidence: 0.8
            )
            try await store.upsert(entity: promise)
            try await store.add(provenance: makeProvenance(
                entityID: promise.id, captureID: capture.id,
                field: "title", snippet: "I'll get the invoice over to you this week",
                at: TestClock.minutes(-30)
            ))
            let unrelated = makeEntity(
                id: TestID.stable("scope", "unrelated"),
                kind: .commitment,
                title: "book the rehearsal room before Friday",
                detail: "Commitment in Notes",
                confidence: 0.8
            )
            try await store.upsert(entity: unrelated)
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            func commitments(_ arguments: [String: Any], id: Int) async throws -> String {
                let frame = try await server.callTool("open_commitments", arguments: arguments, id: id)
                #expect(frame.error == nil, "open_commitments protocol error: \(frame.line)")
                return try #require(frame.contentText)
            }

            // Unscoped, both are open.
            let all = try await commitments([:], id: 170)
            #expect(all.contains("invoice"))
            #expect(all.contains("rehearsal room"))

            // Scoped, only the one whose conversation names him.
            let marco = try await commitments(["person": "Marco"], id: 171)
            #expect(marco.contains("invoice"), "the promise made in Marco's thread is his:\n\(marco)")
            #expect(!marco.contains("rehearsal room"),
                    "an unrelated commitment leaked into a person's list:\n\(marco)")

            // A person with nothing outstanding gets an honest nothing, and the caveat that
            // silence is not proof: Memoir only ever saw what was on screen.
            let nobody = try await commitments(["person": "Zephyrine"], id: 172)
            #expect(nobody.contains("No open commitments involving"), "\(nobody)")
            #expect(nobody.contains("not proof"), "absence must carry its caveat:\n\(nobody)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-92 an answer leads with the answer, not with its evidence")
    func toolsLeadWithTheAnswer() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let frame = try await server.callTool(
                "what_happened", arguments: ["from": "2026-03-01", "to": "2026-03-31"], id: 180
            )
            #expect(frame.error == nil, "what_happened protocol error: \(frame.line)")
            let text = try #require(frame.contentText)

            // The first line has to be the answer: the total and where it went. Before this
            // the reply opened with a date heading and put the total on line three, under
            // twelve app rows and twenty-five note titles.
            let first = try #require(text.split(separator: "\n").first.map(String.init))
            #expect(first.contains(MCPSeed.busiestApp),
                    "the lead sentence must name where the time went:\n\(first)")
            #expect(first.contains("active"), "the lead sentence must carry the total:\n\(first)")

            // And the standing entity dump is gone: what is listed is what moved.
            #expect(!text.contains("## What came up"), "the standing entity list is back:\n\(text)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-90 a provisional commitment stays unsurfaced over MCP too")
    func provisionalCommitmentsAreNotListedOverMCP() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)

            // CF-79 stores a commitment read off a page but never shows it. That law held in
            // the app and silently did not hold here: `provisional` was missing from the
            // MCP's entity field list, so it was never SELECTed, every row decoded as false,
            // and both `!provisional` filters in ToolHandler were dead code. A column absent
            // from the query is indistinguishable from a column that is false.
            try await store.upsert(entity: makeEntity(
                id: TestID.stable("mcp-provisional", "unowned"),
                kind: .commitment,
                title: "somebody else's promise read off a page",
                detail: "Commitment in Google Chrome",
                confidence: 0.6,
                provisional: true
            ))
            try await store.upsert(entity: makeEntity(
                id: TestID.stable("mcp-provisional", "owned"),
                kind: .commitment,
                title: "the promise the user actually made",
                detail: "Commitment in Notes",
                confidence: 0.9
            ))
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let frame = try await server.callTool("open_commitments", arguments: [:], id: 160)
            #expect(frame.error == nil, "open_commitments protocol error: \(frame.line)")
            let text = try #require(frame.contentText)

            #expect(text.contains("the promise the user actually made"),
                    "a real commitment must still be listed:\n\(text)")
            #expect(!text.contains("somebody else's promise read off a page"),
                    "a provisional commitment was surfaced over MCP:\n\(text)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-88 recall answers with what matches, or says nothing did")
    func recallDropsRowsSharingOnlyAStopword() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)

            // A capture that shares nothing with the question but the word "about". On the
            // real database this was an ad-tracker URL and a note about prayer apps, both
            // returned for "repo about screen memory", because search widens AND to OR and
            // "about" is in every other sentence ever captured.
            try await store.insert(capture: Fixtures.capture(
                text: "Nothing to do with the question, but it is about something.",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "unrelated", at: TestClock.minutes(-20), name: "stopword-only"
            ))
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            func recall(_ query: String, id: Int) async throws -> String {
                let frame = try await server.callTool("recall", arguments: ["query": query], id: id)
                #expect(frame.error == nil, "recall protocol error: \(frame.line)")
                return try #require(frame.contentText)
            }

            // The floor is deliberately gentler than verify's: ONE distinctive word in
            // common is enough to stay in, because recall is answering "what might this be"
            // rather than "does the record carry this claim".
            let real = try await recall("rate limiter", id: 150)
            #expect(real.contains("# Recall"), "a query the record answers must still answer:\n\(real)")

            // A row carrying none of the distinctive words was never a match by any reading.
            let stopwords = try await recall("zzzqqq about nonexistent", id: 151)
            #expect(!stopwords.contains("Nothing to do with the question"),
                    "recall returned a row sharing only a stopword:\n\(stopwords)")
            #expect(stopwords.contains("Nothing in Memoir's memory matches"),
                    "an empty result must be said plainly:\n\(stopwords)")
            #expect(stopwords.contains("Looked for:"),
                    "an absence must name what was sought:\n\(stopwords)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-81 a conversation with an assistant is never quoted as evidence")
    func assistantChatIsNotEvidence() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)

            // A conversation with a model, on screen like anything else. Its content is
            // prompts and generated replies, including replies that quote Memoir's own
            // output back at it. Debugging a memory in front of the memory is how it
            // learns its own bugs, and the writer already refuses to cite this as fact.
            let marker = "quenchberry protocol"
            try await store.insert(capture: Fixtures.capture(
                text: "You asked about the \(marker). Answer: the \(marker) ships on Friday.",
                app: "Claude", bundleID: "com.anthropic.claudefordesktop",
                windowTitle: "Claude", at: TestClock.minutes(-30), name: "assistant-desktop"
            ))
            // The same thing in a browser tab, where the bundle ID says nothing.
            try await store.insert(capture: Fixtures.capture(
                text: "Sure, I'll note that the \(marker) ships on Friday.",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "claude.ai \u{2014} \(marker)", at: TestClock.minutes(-25), name: "assistant-web"
            ))
            // The web app as it is actually titled, which names no domain at all. This is
            // what the domain check missed: six of ten rows of a real `recall` came back as
            // Claude explaining it could not read the user's WhatsApp, offered as evidence
            // about their WhatsApp (CF-106).
            try await store.insert(capture: Fixtures.capture(
                text: "I don't have access to your \(marker) or any other private data.",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Test question - Claude – Part of group ✅Demo - Google Chrome",
                at: TestClock.minutes(-24), name: "assistant-web-untitled"
            ))
            // …and a bare new conversation, whose whole title is the product.
            try await store.insert(capture: Fixtures.capture(
                text: "How can I help you with the \(marker)?",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Claude - Google Chrome",
                at: TestClock.minutes(-23), name: "assistant-web-bare"
            ))
            // The other half of the rule, and the half that makes it a filter rather than a
            // shredder: the user genuinely READING about an assistant is evidence, and the
            // most valuable kind this product keeps. A substring match would have taken 87
            // browser captures on the database this was found in, nearly all of them these.
            let readingMarker = "hackenbush gambit"
            try await store.insert(capture: Fixtures.capture(
                text: "A thread about the \(readingMarker) and why it matters.",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "mirafenn on X: \"feels like Claude skills wrapped\" - \(readingMarker) - Google Chrome",
                at: TestClock.minutes(-22), name: "reading-about-claude"
            ))
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            func answer(_ name: String, _ arguments: [String: Any], id: Int) async throws -> String {
                let frame = try await server.callTool(name, arguments: arguments, id: id)
                #expect(frame.error == nil, "\(name) protocol error: \(frame.line)")
                return try #require(frame.contentText)
            }

            // No tool that QUOTES evidence may quote any of them.
            for (index, tool) in ["recall", "prior_art", "sources_for", "verify"].enumerated() {
                let key = tool == "recall" ? "query" : (tool == "prior_art" ? "topic" : "claim")
                let text = try await answer(tool, [key: marker], id: 90 + index)
                #expect(!text.contains("ships on Friday"),
                        "\(tool) quoted a conversation with an assistant as evidence:\n\(text)")
                #expect(!text.contains("don't have access"),
                        "\(tool) quoted the Claude web app, which names no domain in its title:\n\(text)")
                #expect(!text.contains("How can I help"),
                        "\(tool) quoted a conversation whose whole title is the product name:\n\(text)")
            }

            // But a page the user was READING about an assistant survives, in the tool
            // agents lean on hardest. Dropping this would be the worse bug of the two:
            // silence about something they genuinely looked at, with no way to notice.
            let reading = try await answer("recall", ["query": readingMarker], id: 94)
            #expect(reading.contains("why it matters"),
                    "recall dropped a page the user was reading about an assistant:\n\(reading)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-17b the server refuses out of scope before it searches")
    func serverRefusesWhatAScreenCannotKnow() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)

            // The corpus contains something a keyword search will happily return for any of
            // these, which is the whole problem: a question about lunch has no right answer
            // in a screen memory, and a search will always find SOMETHING. Measured on the
            // real database before this guard, recall("what did I have for lunch") came back
            // with two commitments about Live Mode under the heading "What Memoir knows".
            let marker = "quenchberry protocol"
            try await store.insert(capture: Fixtures.capture(
                text: "lunch money password call \(marker): every trigger word in one row.",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "notes", at: TestClock.minutes(-20), name: "trigger-row"
            ))
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            func answer(_ name: String, _ arguments: [String: Any], id: Int) async throws -> String {
                let frame = try await server.callTool(name, arguments: arguments, id: id)
                #expect(frame.error == nil, "\(name) protocol error: \(frame.line)")
                return try #require(frame.contentText)
            }

            // One from each family the guard covers, across the tools that take free text.
            let refused: [(tool: String, key: String, ask: String)] = [
                ("recall", "query", "what did I have for lunch"),
                ("recall", "query", "how much money did I spend today"),
                ("recall", "query", "what is my password for github"),
                // A search KEY, not a question: no interrogative, so none of the app's
                // question-shaped credential phrases fire. Measured: this one still ran
                // after the guard was ported, which is why the server has a stricter rule.
                ("recall", "query", "github password"),
                ("recall", "query", "stripe api key"),
                ("sources_for", "claim", "the seed phrase"),
                ("recall", "query", "who called me today"),
                ("recall", "query", "what did I browse in incognito"),
                ("prior_art", "topic", "what did I buy today"),
                ("sources_for", "claim", "my password is on the fridge"),
                ("verify", "claim", "what did I have for lunch"),
                ("who_is", "name", "who called me"),
            ]
            for (index, case_) in refused.enumerated() {
                let text = try await answer(case_.tool, [case_.key: case_.ask], id: 300 + index)
                #expect(text.contains("declined this lookup"),
                        "\(case_.tool)(\(case_.ask)) searched instead of refusing:\n\(text)")
                #expect(!text.contains(marker),
                        "\(case_.tool)(\(case_.ask)) leaked a capture it should never have read:\n\(text)")
            }

            // And the tools stay useful. A refusal that swallows real questions is a worse
            // bug than the one it fixes: "that article about password managers" is a
            // legitimate memory, and so is time spent, which shares its verb with money.
            let allowed: [(tool: String, key: String, ask: String)] = [
                ("recall", "query", "the article about password managers"),
                ("recall", "query", "our password rotation policy"),
                ("recall", "query", "the 1password migration"),
                ("recall", "query", "did I spend more time in chrome or claude"),
                ("recall", "query", "\(marker)"),
                ("prior_art", "topic", "\(marker)"),
            ]
            for (index, case_) in allowed.enumerated() {
                let text = try await answer(case_.tool, [case_.key: case_.ask], id: 320 + index)
                #expect(!text.contains("declined this lookup"),
                        "\(case_.tool)(\(case_.ask)) was refused and should not have been:\n\(text)")
            }

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-17b Memoir's own window is not somewhere the user was")
    func memoirsOwnWindowIsNotEvidence() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)

            // The ask bar displays Memoir's ANSWERS, and the capture loop reads the screen
            // they are drawn on. So an answer becomes a capture, the capture is returned as
            // memory, and the memory is cited as evidence for the answer that produced it.
            // `isAssistantConversation` never caught this one: the bundle is Memoir's own.
            let marker = "wintergreen ledger"
            try await store.insert(capture: Fixtures.capture(
                text: "You left off on the \(marker) at 14:05, 40 min in Xcode.",
                app: "Memoir", bundleID: "sh.memoir.app",
                windowTitle: "Memoir", at: TestClock.minutes(-10), name: "memoir-own-window"
            ))
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            for (index, tool) in ["recall", "prior_art", "sources_for", "working_set"].enumerated() {
                let key = tool == "recall" ? "query" : (tool == "prior_art" ? "topic" : "claim")
                let arguments: [String: Any] = tool == "working_set" ? [:] : [key: marker]
                let frame = try await server.callTool(tool, arguments: arguments, id: 340 + index)
                #expect(frame.error == nil, "\(tool) protocol error: \(frame.line)")
                let text = try #require(frame.contentText)
                #expect(!text.contains("40 min in Xcode"),
                        "\(tool) quoted Memoir's own answer back as memory:\n\(text)")
            }

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-82 working_set spends its budget on distinct things")
    func workingSetFallbackDeduplicates() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)

            // The same page, captured five times a minute apart, exactly as a browser left
            // open produces, and the NEWEST captures in the store, so without dedupe they
            // take every slot. Plus two genuinely different things just behind them. All far
            // older than an hour, so the tool takes its "nothing in the last hour" path.
            let page = "Memoir avatar and website design \u{2014} Back to projects \u{2014} I like 1f, delete the other"
            for i in 0..<5 {
                try await store.insert(capture: Fixtures.capture(
                    text: page, app: "Google Chrome", bundleID: "com.google.Chrome",
                    windowTitle: "Memoir avatar and website design",
                    at: TestClock.minutes(Double(54 - i)), name: "dupe-\(i)"
                ))
            }
            try await store.insert(capture: Fixtures.capture(
                text: "Latest Decisions: the migration lands Thursday.", app: "Obsidian",
                bundleID: "md.obsidian", windowTitle: "Latest Decisions",
                at: TestClock.minutes(46), name: "distinct-obsidian"
            ))
            try await store.insert(capture: Fixtures.capture(
                text: "FenwickImporter.swift: parsing the ledger rows.", app: "Xcode",
                bundleID: "com.apple.dt.Xcode", windowTitle: "FenwickImporter.swift",
                at: TestClock.minutes(45), name: "distinct-xcode"
            ))
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let frame = try await server.callTool("working_set", arguments: [:], id: 95)
            #expect(frame.error == nil, "working_set protocol error: \(frame.line)")
            let text = try #require(frame.contentText)

            // The repeated page may appear once. Four more copies of it is a context load
            // that is 80% redundant: the agent learns one thing and pays for five.
            let pageMentions = text.components(separatedBy: "Memoir avatar and website design").count - 1
            #expect(pageMentions <= 1,
                    "the same page was listed \(pageMentions) times:\n\(text)")

            // And the budget it freed goes to things the agent has not already seen.
            #expect(text.contains("Obsidian") || text.contains("Xcode"),
                    "distinct activity must reach the list:\n\(text)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-93 every answer comes back counted, and the counts validate against the schema")
    func toolsAnswerWithStructuredContent() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            // Every tool advertises one, and it is a real schema rather than a decorative
            // dictionary, the same bar CF-30 holds `inputSchema` to.
            let list = try await server.request("tools/list", id: 200)
            let tools = try #require((list.result?["tools"]) as? [[String: Any]])
            var schemas: [String: Any] = [:]
            for tool in tools {
                let name = (tool["name"] as? String) ?? "?"
                let schema = try #require(tool["outputSchema"], "\(name) advertises no outputSchema")
                let reparsed = try JSONSerialization.jsonObject(
                    with: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
                )
                let problems = MiniSchema.structuralProblems(in: reparsed)
                #expect(problems.isEmpty, "\(name).outputSchema is not valid: \(problems.joined(separator: "; "))")
                schemas[name] = reparsed
            }
            #expect(schemas.count == 13, "all thirteen tools must declare their output shape")

            /// One call, checked against the schema the server itself just advertised.
            ///
            /// The spec makes validation a MUST: a strict client throws the whole answer
            /// away rather than degrading to the text, so a payload that does not fit its
            /// own schema is worse than no payload at all.
            func counted(
                _ name: String,
                _ arguments: [String: Any] = [:],
                id: Int,
                sourceLocation: SourceLocation = #_sourceLocation
            ) async throws -> (text: String, structured: [String: Any]) {
                let frame = try await server.callTool(name, arguments: arguments, id: id, sourceLocation: sourceLocation)
                #expect(frame.error == nil, "\(name) protocol error: \(frame.line)", sourceLocation: sourceLocation)
                let text = try #require(
                    frame.contentText, "\(name) lost its text block: \(frame.line)", sourceLocation: sourceLocation
                )
                #expect(!text.isEmpty, "\(name) answered with nothing", sourceLocation: sourceLocation)
                let structured = try #require(
                    frame.structuredContent, "\(name) returned no structuredContent: \(frame.line)",
                    sourceLocation: sourceLocation
                )
                let schema = try #require(schemas[name], sourceLocation: sourceLocation)
                let problems = MiniSchema.validate(structured, against: schema)
                #expect(
                    problems.isEmpty,
                    "\(name).structuredContent does not satisfy its own schema: \(problems.joined(separator: "; "))",
                    sourceLocation: sourceLocation
                )
                #expect(
                    structured["tool"] as? String == name,
                    "\(name) returned a payload naming \(String(describing: structured["tool"]))",
                    sourceLocation: sourceLocation
                )
                #expect(
                    (structured["summary"] as? String)?.isEmpty == false,
                    "\(name) has nothing to put in a chip: \(frame.line)",
                    sourceLocation: sourceLocation
                )
                // The envelope must carry the answer, not just its measurements.
                //
                // This suite checked that both halves left the server and never that the
                // half a client actually reads contains anything to read. A client that
                // supports `outputSchema` renders `structuredContent` *instead of* the
                // text block, so for a year `recall` could answer `15 captures` with no
                // captures in it and every assertion here still passed (CF-104).
                #expect(
                    structured["text"] as? String == text,
                    "\(name) put the answer only in the text block: \(frame.line)",
                    sourceLocation: sourceLocation
                )
                return (text, structured)
            }

            func counts(_ structured: [String: Any]) throws -> [String: Int] {
                let raw = try #require(structured["counts"] as? [String: Any])
                return raw.compactMapValues { ($0 as? NSNumber)?.intValue }
            }

            // recall: the counts are the prose counted. The citation lines are the ones a
            // chip would be summarising, so a mismatch here is a chip that lies.
            let recall = try await counted("recall", ["query": "rate limiter", "limit": 10], id: 201)
            let recallCounts = try counts(recall.structured)
            let citations = recall.text
                .components(separatedBy: "## Where it was seen").last?
                .split(separator: "\n").filter { $0.hasPrefix("- **") }.count ?? 0
            #expect(recallCounts["captures"] == citations,
                    "recall counted \(String(describing: recallCounts["captures"])) captures and cited \(citations)")
            #expect(recallCounts["entities"] ?? 0 > 0, "the seeded entities are not counted:\n\(recall.text)")
            #expect(recall.structured["status"] as? String == "ok")

            // And the freshness a chip renders: the seed is months old, and says so.
            let age = try #require((recall.structured["ageSeconds"] as? NSNumber)?.intValue)
            #expect(age > 86_400, "the March seed cannot be less than a day old")
            #expect((recall.structured["newest"] as? String)?.hasPrefix("2026-03") == true,
                    "newest must be the newest matching capture: \(String(describing: recall.structured["newest"]))")

            // what_happened: idle is excluded from the counts exactly as it is excluded
            // from the total, and `projects` counts the NAMED work rather than the rows:
            // time that degraded honestly to an app name is in the breakdown but is not a
            // project, and counting it as one would be the guess the timesheet refuses to
            // make (CF-95).
            let happened = try await counted(
                "what_happened", ["from": "2026-03-01", "to": "2026-03-31"], id: 202
            )
            let happenedCounts = try counts(happened.structured)
            let breakdown = (happened.text.components(separatedBy: "## What the time went on").last ?? "")
                .components(separatedBy: "\n## ").first?
                .split(separator: "\n").filter { $0.hasPrefix("- ") } ?? []
            let named = breakdown.filter { !$0.contains("_unlabelled_") }.count
            #expect(happenedCounts["projects"] == named,
                    "the project count disagrees with the breakdown:\n\(happened.text)")
            #expect(!breakdown.isEmpty, "the time has to be broken down somehow:\n\(happened.text)")
            #expect(happenedCounts["sessions"] == 2, "the idle session is not a session anybody worked in")

            // open_commitments: one dated and one undated, both seeded.
            let commitments = try counts(try await counted("open_commitments", id: 203).structured)
            #expect(commitments["commitments"] == 2)
            #expect(commitments["undated"] == 1)
            #expect((commitments["overdue"] ?? 0) + (commitments["upcoming"] ?? 0) == 1,
                    "the dated commitment is either overdue or coming up, depending on the day")

            // verify: the verdict a chip shows, and the sighting count behind it.
            let verified = try await counted("verify", ["claim": "rate limiter"], id: 204)
            #expect(verified.structured["status"] as? String == "ok")
            #expect((try counts(verified.structured))["sightings"] ?? 0 > 0)

            // The three outcomes that are NOT an answer, and which a tick would flatten
            // into one. Before this they were indistinguishable: all three came back as
            // `isError: false` with prose in the block.
            let absent = try await counted("verify", ["claim": "zeppelin mainframe cobol"], id: 205)
            #expect(absent.structured["status"] as? String == "empty",
                    "a claim the record does not carry is not an answer:\n\(absent.text)")
            #expect(absent.text.contains("Not in the record"), "the prose must be untouched:\n\(absent.text)")

            let vague = try await counted("verify", ["claim": "the and of is a"], id: 206)
            #expect(vague.structured["status"] as? String == "declined",
                    "a claim with nothing to look for was never searched for:\n\(vague.text)")

            let refused = try await counted("recall", ["query": "what did I have for lunch"], id: 207)
            #expect(refused.structured["status"] as? String == "declined",
                    "a scope refusal is not an empty result:\n\(refused.text)")
            #expect(refused.text.contains("declined this lookup"), "the refusal prose must be untouched")

            // The rest of the catalogue, every one of them validating. `propose_memory` is
            // left out on purpose: staging is its side effect, and CF-77 owns it.
            var id = 210
            for (tool, arguments) in [
                ("who_is", ["name": "Priya"] as [String: Any]),
                ("today", [:] as [String: Any]),
                ("what_changed_since", ["since": "2026-03-01"] as [String: Any]),
                ("prior_art", ["topic": "rate limiter"] as [String: Any]),
                ("working_set", [:] as [String: Any]),
                ("sources_for", ["claim": "rate limiter fix"] as [String: Any]),
                ("timesheet", ["from": "2026-03-01", "to": "2026-03-31"] as [String: Any]),
            ] {
                _ = try await counted(tool, arguments, id: id)
                id += 1
            }

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-77 propose_memory stages a proposal and writes nothing to memory")
    func proposeStagesWithoutWriting() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            let dbBefore = try FileFingerprint.of(ws.dbURL)
            let countsBefore = try mcpRowCounts(at: ws.dbURL)
            let proposalsURL = ProposalStore.url(alongsideDatabase: ws.dbURL)
            #expect(ProposalStore.load(at: proposalsURL).isEmpty)

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let frame = try await server.callTool("propose_memory", arguments: [
                "kind": "decision",
                "title": "Adopted reciprocal rank fusion for retrieval",
                "detail": "Chosen over score blending; positions are comparable, scores are not.",
            ], id: 30)
            let text = try #require(frame.contentText)
            #expect(text.contains("Staged for review"))
            #expect(text.contains("Nothing has been written to memory"))

            // Invalid kind is prose, not a protocol error, and stages nothing extra.
            let bad = try await server.callTool("propose_memory", arguments: [
                "kind": "opinion", "title": "should not land",
            ], id: 31)
            #expect(try #require(bad.contentText).contains("invalid `kind`"))

            let status = await server.waitForExit()
            #expect(status == 0)
            expectPureJSONStdout(server)

            // The stage: exactly one proposal, next to the database, not in it.
            let staged = ProposalStore.load(at: proposalsURL)
            #expect(staged.count == 1)
            #expect(staged.first?.kind == .decision)
            #expect(staged.first?.title == "Adopted reciprocal rank fusion for retrieval")
            #expect(staged.first?.origin == "mcp")

            // The database: byte-identical, row-identical. CF-33 holds through a write-shaped tool.
            let dbAfter = try FileFingerprint.of(ws.dbURL)
            #expect(dbBefore == dbAfter, "propose_memory must never touch the database")
            let countsAfter = try mcpRowCounts(at: ws.dbURL)
            #expect(countsBefore == countsAfter)
        }
    }

    @Test("CF-77 only the user's accept turns a proposal into an authored entity")
    func acceptIsTheOnlyPathIn() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let proposalsURL = ProposalStore.url(alongsideDatabase: ws.dbURL)

            let proposal = MemoryProposal(
                id: TestID.stable("proposal", "rrf"),
                ts: TestClock.reference,
                kind: .decision,
                title: "Adopted reciprocal rank fusion for retrieval",
                detail: "Chosen over score blending.",
                origin: "mcp"
            )
            try ProposalStore.append(proposal, at: proposalsURL)

            // Staged is not stored: the store has no decision yet.
            #expect(try await store.entities(kind: .decision, includeDeleted: false).isEmpty)

            // Reject leaves no trace.
            try ProposalStore.remove(id: proposal.id, at: proposalsURL)
            #expect(ProposalStore.load(at: proposalsURL).isEmpty)
            #expect(try await store.entities(kind: .decision, includeDeleted: false).isEmpty)

            // Only an accept writes, as authored, with provenance.
            try ProposalStore.append(proposal, at: proposalsURL)
            let entityID = try await memory.accept(proposal: proposal, now: TestClock.minutes(1))
            try ProposalStore.remove(id: proposal.id, at: proposalsURL)

            let decision = try #require(try await store.entity(id: entityID))
            #expect(decision.source == .authored, "acceptance is the act of authorship")
            #expect(decision.title == proposal.title)

            let evidence = try await store.provenance(entityID: entityID)
            #expect(!evidence.isEmpty, "an accepted proposal is traceable like everything else")
            let capture = try await store.capture(id: try #require(evidence.first?.captureID))
            #expect(capture?.appName.contains("Agent proposal") == true)
        }
    }
}
/// The gate that decides whether the returns block ships, checked before it exists.
///
/// This project has twice shipped a measurement that turned out to be measuring something
/// else, and once written a test that passed with its own feature reverted. The defence is
/// to fix the criterion in a file before the thing it judges is built, and then to pin the
/// file so it cannot drift toward whatever the result turns out to be.
@Suite("The ablation gate")
struct AblationSpecTests {

    /// The repository root, found by walking up from this file until Package.swift appears.
    ///
    /// Counting `deletingLastPathComponent()` calls is how this broke first: the test file
    /// sits four levels down, not three, and a miscount fails in a way that reads like the
    /// spec file is missing rather than like the path is wrong.
    static let repoRoot: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    private func spec() throws -> [String: Any] {
        let url = Self.repoRoot.appendingPathComponent("Evals/ablation.json")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the criterion is declared, complete, and demands a placebo margin")
    func criterionIsDeclaredInAdvance() throws {
        let spec = try spec()
        let criterion = try #require(spec["criterion"] as? [String: Any])
        let questions = try #require(spec["questions"] as? [[String: Any]])

        // The count in the criterion and the number of questions must agree, or the
        // threshold is a fraction of something nobody wrote down.
        let declared = try #require(criterion["questions"] as? Int)
        #expect(declared == questions.count,
                "the criterion counts \(declared) questions and the file has \(questions.count)")

        // A minimum alone is passable by adding text. The margin over the placebo is the
        // half that measures the block rather than its length.
        let minimum = try #require(criterion["fullMinimumUses"] as? Int)
        let margin = try #require(criterion["fullMustExceedPlaceboBy"] as? Int)
        #expect(minimum > 0, "a gate with no minimum is not a gate")
        #expect(margin > 0, "without a placebo margin this measures prompt length, not content")
        #expect(minimum <= questions.count)

        // Every question carries its reason, because a question set assembled without one
        // is a set that can be quietly extended until something passes.
        for q in questions {
            let id = (q["id"] as? String) ?? "(unnamed)"
            #expect((q["ask"] as? String)?.isEmpty == false, "\(id) has no question")
            #expect((q["why"] as? String)?.isEmpty == false, "\(id) does not say why it is in the set")
        }

        // The owner's three questions are the reason any of this exists. They are named
        // here so a later edit that drops them fails rather than passes.
        let ids = Set(questions.compactMap { $0["id"] as? String })
        for required in ["life-now", "job-personal", "where-next"] {
            #expect(ids.contains(required), "the gate lost the question it was built for: \(required)")
        }
        // And at least one question written to FAVOUR the block, so a null result cannot be
        // blamed on an unfriendly set.
        #expect(ids.contains("recurring"), "the set has no question favourable to the block")
    }

    @Test("the harness exists and refuses to pass when it cannot run")
    func harnessRefusesToPassWhenItCannotRun() throws {
        let root = Self.repoRoot
        for script in ["Scripts/ablate.sh", "Scripts/ablate_score.py"] {
            let url = root.appendingPathComponent(script)
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(script)")
            let body = try String(contentsOf: url, encoding: .utf8)
            // An unrunnable gate must exit non-zero. A harness that prints "could not run"
            // and exits 0 is the failure mode this whole file exists to prevent. Written
            // two ways because one arm is shell and the other is Python.
            #expect(body.contains("exit 3") || body.contains("return 3"),
                    "\(script) has no failure path for being unable to run")
        }
    }
}

