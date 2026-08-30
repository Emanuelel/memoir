//
//  EndToEndTests.swift
//  CF-40: the whole loop.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  FLOWS.md: "If only one test could survive, this is it."
//  ─────────────────────────────────────────────────────────────────────────────
//
//  Two journeys, each on one throwaway workspace, each crossing every module the
//  product actually ships:
//
//    capture → Store → RuleExtractor → MemoryService → BrainRouter → RulesOnlyBrain
//                                    ↘ memoir-mcp (a real subprocess, real read-only SQLite)
//
//  1. `wholeLoop`:          a commitment is captured, consolidated, dated, traced,
//                           named by the answer, and found again through MCP, with
//                           both paths pointing at the *same* original capture.
//  2. `correctionJourney`:  the same loop with a user correction in the middle. A
//                           correction that does not reach what the assistant says
//                           is a silent, trust-destroying failure; this is the guard.
//
//  Nothing here reads the wall clock: every date the product consumes is injected.
//  Nothing here reaches the network: `assertNoNetwork()` proves it.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-40 · the whole loop")
struct EndToEndTests {

    // MARK: - The world under test

    /// One capture carrying exactly one unmistakable commitment.
    ///
    /// The text is deliberately narrow. Everything in it that *could* become an entity
    /// has been kept below the extractor's thresholds ("Zephyr" and "Marco" each occur
    /// twice, below `RuleExtractor.repetitionThreshold`), so the pass produces a single
    /// commitment and an assertion about "the" commitment is unambiguous.
    private enum Scenario {

        /// An app name that is not a word in the capture text, so a rendered
        /// "Seen in: <app>" line proves a capture id was resolved rather than guessed.
        static let appName = "Linear"
        static let bundleID = "com.linear"
        static let windowTitle = "Zephyr migration kickoff"

        /// The distinctive token. It appears nowhere else in the suite.
        static let needle = "Zephyr"

        static let text = """
        Marco asked how we unblock the customer import.
        I'll send the Zephyr migration plan to Marco by Friday.
        The rest of the backlog is unchanged.
        """

        /// The exact line `RuleExtractor` turns into the commitment's title.
        ///
        /// Segments are lines; the title is the cleaned segment, and this one is short
        /// enough that `MemoryText.truncate(_:max: 140)` leaves it alone.
        static let commitmentTitle = "I'll send the Zephyr migration plan to Marco by Friday."

        /// A fragment of the original title that the corrected title does not contain,
        /// used to prove a correction really replaced it everywhere.
        static let originalFragment = "I'll send"

        /// What the user renames it to.
        static let correctedTitle = "Ship the Zephyr migration plan to Marco"

        /// The question the user asks.
        static let question = "what do I owe anyone"

        /// "by Friday", read on Monday 16 March 2026, is Friday 20 March at 17:00 local.
        ///
        /// `MemoryDateResolver` resolves day-granularity expressions to 17:00 **local**,
        /// so the expectation is built with the local calendar rather than a hardcoded
        /// UTC instant. The reference is 10:00 UTC on a Monday, which lands on Sunday 15,
        /// Monday 16 or Tuesday 17 March depending on the machine's offset, and the next
        /// Friday after each of those is the same day, 20 March.
        static var dueFriday: Date { TestClock.local(2026, 3, 20, 17, 0) }

        /// The single capture, timestamped from the injected clock.
        static func capture(at ts: Date = TestClock.reference) -> CaptureEvent {
            Fixtures.capture(
                text: text,
                app: appName,
                bundleID: bundleID,
                windowTitle: windowTitle,
                at: ts,
                name: "cf40-zephyr"
            )
        }
    }

    // MARK: - CF-40 · the whole loop

    @Test("CF-40 a captured commitment reaches the answer and the MCP server, tracing to one capture")
    func wholeLoop() async throws {
        try await TestWorkspace.with { ws in

            // ── 1. Capture ────────────────────────────────────────────────────────
            let store = try await ws.store()
            let capture = Scenario.capture()
            try await store.insert(capture: capture)

            let roundTripped = try await store.capture(id: capture.id)
            let stored = try #require(roundTripped, "the capture did not survive the round trip")
            #expect(stored.text == Scenario.text)
            #expect(stored.appName == Scenario.appName)

            // ── 2. Consolidate ────────────────────────────────────────────────────
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let touched = try await memory.consolidate(
                since: TestClock.days(-1),
                now: TestClock.hours(1)
            )
            #expect(touched >= 1, "consolidation found nothing in text that plainly contains a promise")

            // ── 3. The commitment, its date, and its provenance ───────────────────
            let commitments = try await store.entities(kind: .commitment, includeDeleted: false)
            let commitmentTitles = commitments.map(\.title).joined(separator: " | ")
            #expect(
                commitments.count == 1,
                "expected exactly one commitment, got \(commitments.count): \(commitmentTitles)"
            )
            let commitment = try #require(commitments.first)
            #expect(commitment.title == Scenario.commitmentTitle)
            #expect(commitment.title.contains(Scenario.needle))
            #expect(commitment.corrected == false)
            #expect(commitment.deleted == false)

            let due = try #require(commitment.dueAt, "\"by Friday\" did not resolve to a date")
            #expect(
                due == Scenario.dueFriday,
                "due date is \(TestClock.iso(due)), expected \(TestClock.iso(Scenario.dueFriday))"
            )
            #expect(TestClock.sameLocalDay(due, Scenario.dueFriday))

            let provenance = try await store.provenance(entityID: commitment.id)
            #expect(provenance.isEmpty == false, "an entity with no provenance is not traceable")
            #expect(
                provenance.allSatisfy({ $0.captureID == capture.id }),
                "provenance points at a capture that is not the one this came from"
            )

            let titleRow = try #require(
                provenance.first(where: { $0.field == "title" }),
                "no provenance for the title the answer will quote"
            )
            #expect(
                Scenario.text.contains(titleRow.snippet),
                "provenance snippet \"\(titleRow.snippet)\" does not literally appear in the capture"
            )
            let resolvedSource = try await store.capture(id: titleRow.captureID)
            let sourceCapture = try #require(resolvedSource, "provenance points at a capture that does not exist")
            #expect(sourceCapture.id == capture.id)

            // The date is traceable too: the extractor records which words it read.
            let dueRows = provenance.filter { $0.field == "dueAt" }
            #expect(dueRows.isEmpty == false, "a resolved due date must say which words it was read from")
            #expect(dueRows.contains(where: { $0.snippet.localizedCaseInsensitiveContains("friday") }))

            // ── 4. Ask, through the real router ───────────────────────────────────
            let packet = try await memory.context(
                for: Scenario.question,
                budget: 2_000,
                now: TestClock.minutes(30)
            )
            #expect(packet.approxTokens <= 2_000)
            #expect(
                packet.captureIDs.contains(capture.id),
                "the context packet did not consult the only capture on file"
            )

            let router = BrainRouter(preferred: .rulesOnly, store: store, config: TestBrainConfig.localOnly)
            let answer = try await router.answer(question: Scenario.question, context: packet)

            #expect(answer.brain == .rulesOnly, "the answer must name the brain that actually ran")
            #expect(answer.text.isEmpty == false)
            #expect(
                answer.text.contains(Scenario.commitmentTitle),
                "the answer does not name the commitment:\n\(answer.text)"
            )
            #expect(
                answer.citedCaptureIDs.contains(capture.id),
                "the answer cited \(answer.citedCaptureIDs), not the capture it came from"
            )
            for cited in answer.citedCaptureIDs {
                let row = try await store.capture(id: cited)
                #expect(row != nil, "cited capture \(cited) does not resolve to a real row")
            }
            assertNoNetwork()

            // ── 5. The same commitment, through the real memoir-mcp subprocess ───────
            // Fold the WAL back into the file first: the server opens READONLY and must
            // see everything written above.
            await store.close()

            let mcp = try EndToEndMCP.run(
                database: ws.dbURL,
                stderrURL: ws.root.appendingPathComponent("mcp-stderr.log"),
                calls: [
                    EndToEndMCP.Call(id: 2, name: "open_commitments", argumentsJSON: "{}"),
                    EndToEndMCP.Call(id: 3, name: "recall", argumentsJSON: #"{"query":"Zephyr","limit":10}"#),
                ]
            )

            #expect(mcp.exitStatus == 0, "memoir-mcp exited \(mcp.exitStatus). stderr:\n\(mcp.stderrText)")
            #expect(mcp.protocolVersion == "2025-06-18")
            #expect(mcp.serverName == "memoir")
            #expect(mcp.errors.isEmpty, "memoir-mcp returned JSON-RPC errors: \(mcp.errors)")
            #expect(
                mcp.unparsableLines.isEmpty,
                "stdout carried non-JSON: \(mcp.unparsableLines.joined(separator: " ⏎ "))"
            )

            let openCommitments = try #require(
                mcp.toolTexts[2],
                "open_commitments produced no content block. stderr:\n\(mcp.stderrText)"
            )
            #expect(
                openCommitments.contains(Scenario.commitmentTitle),
                "MCP does not list the commitment:\n\(openCommitments)"
            )

            // ── 6. Both paths trace back to the same capture ──────────────────────
            let recall = try #require(mcp.toolTexts[3], "recall produced no content block")
            #expect(recall.contains(Scenario.commitmentTitle))
            #expect(
                recall.contains("unknown app") == false,
                "MCP could not resolve a provenance capture id to a row:\n\(recall)"
            )

            let seenIn = EndToEndMCP.bulletsUnder("Seen in:", in: recall)
            #expect(seenIn.isEmpty == false, "the MCP entity block carried no provenance:\n\(recall)")
            #expect(
                seenIn.allSatisfy({ $0.hasPrefix("- \(Scenario.appName) · ") }),
                "provenance was not attributed to \(Scenario.appName): \(seenIn)"
            )
            #expect(
                seenIn.contains(where: { $0.contains(titleRow.snippet) }),
                "MCP shows a different snippet than the store recorded. store: \"\(titleRow.snippet)\", mcp: \(seenIn)"
            )

            // The loop closes: the capture that was written, the capture the memory
            // traces the commitment to, and the capture the answer cited are one row.
            let tracedCaptureIDs = Set(provenance.map(\.captureID))
            #expect(tracedCaptureIDs == [capture.id])
            #expect(
                Set(answer.citedCaptureIDs) == tracedCaptureIDs,
                "the answer cited \(answer.citedCaptureIDs) but the memory traces to \(tracedCaptureIDs)"
            )

            assertNoNetwork()
        }
    }

    // MARK: - CF-40 · the correction journey

    @Test("CF-40 a user correction propagates to the answer and to the MCP server")
    func correctionJourney() async throws {
        try await TestWorkspace.with { ws in

            // ── Capture and consolidate, exactly as above ─────────────────────────
            let store = try await ws.store()
            let capture = Scenario.capture()
            try await store.insert(capture: capture)

            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            try await memory.consolidate(since: TestClock.days(-1), now: TestClock.hours(1))

            let firstPass = try await store.entities(kind: .commitment, includeDeleted: false)
            let original = try #require(firstPass.first, "nothing was extracted to correct")
            #expect(original.title == Scenario.commitmentTitle)
            let originalDue = try #require(original.dueAt)

            // ── The user rewrites the title, exactly as the memory browser does ───
            var edited = original
            edited.title = Scenario.correctedTitle
            edited.corrected = true
            edited.updatedAt = TestClock.hours(2)
            try await store.upsert(entity: edited)

            // ── Consolidate again, twice, over the very same source text ──────────
            // The extractor still proposes the original wording every time. The
            // correction has to win every time.
            try await memory.consolidate(since: TestClock.days(-1), now: TestClock.hours(3))
            try await memory.consolidate(since: TestClock.days(-1), now: TestClock.hours(4))

            let after = try await store.entities(kind: .commitment, includeDeleted: false)
            let afterTitles = after.map(\.title).joined(separator: " | ")
            #expect(
                after.count == 1,
                "re-extraction must merge into the corrected row, not add a second one. Got: \(afterTitles)"
            )
            let kept = try #require(after.first)
            #expect(kept.id == original.id, "the correction was applied to a different row")
            #expect(kept.title == Scenario.correctedTitle, "extraction overwrote a user correction")
            #expect(kept.corrected, "the corrected flag was lost")
            #expect(kept.dueAt == originalDue, "the due date the user kept was rewritten")
            #expect(kept.confidence >= original.confidence)

            // Provenance survives a rename: it still points at the original capture.
            let provenance = try await store.provenance(entityID: kept.id)
            #expect(provenance.isEmpty == false)
            #expect(provenance.allSatisfy({ $0.captureID == capture.id }))

            // ── Ask ───────────────────────────────────────────────────────────────
            let packet = try await memory.context(
                for: Scenario.question,
                budget: 2_000,
                now: TestClock.minutes(30)
            )
            let router = BrainRouter(preferred: .rulesOnly, store: store, config: TestBrainConfig.localOnly)
            let answer = try await router.answer(question: Scenario.question, context: packet)

            #expect(answer.brain == .rulesOnly)
            #expect(
                answer.text.contains(Scenario.correctedTitle),
                "the answer ignored the correction:\n\(answer.text)"
            )
            #expect(
                answer.text.contains(Scenario.originalFragment) == false,
                "the answer still uses the wording the user replaced:\n\(answer.text)"
            )
            assertNoNetwork()

            // ── The MCP server has to agree ───────────────────────────────────────
            await store.close()

            let mcp = try EndToEndMCP.run(
                database: ws.dbURL,
                stderrURL: ws.root.appendingPathComponent("mcp-stderr.log"),
                calls: [EndToEndMCP.Call(id: 2, name: "open_commitments", argumentsJSON: "{}")]
            )

            #expect(mcp.exitStatus == 0, "memoir-mcp exited \(mcp.exitStatus). stderr:\n\(mcp.stderrText)")
            #expect(mcp.errors.isEmpty, "memoir-mcp returned JSON-RPC errors: \(mcp.errors)")

            let openCommitments = try #require(
                mcp.toolTexts[2],
                "open_commitments produced no content block. stderr:\n\(mcp.stderrText)"
            )
            #expect(
                openCommitments.contains(Scenario.correctedTitle),
                "MCP ignored the correction:\n\(openCommitments)"
            )
            #expect(
                openCommitments.contains(Scenario.originalFragment) == false,
                "MCP still serves the wording the user replaced:\n\(openCommitments)"
            )
            #expect(
                openCommitments.contains("you corrected this"),
                "MCP does not tell the calling agent this was user-corrected:\n\(openCommitments)"
            )

            assertNoNetwork()
        }
    }
}

// MARK: - Driving the real MCP binary

/// A one-shot JSON-RPC conversation with the compiled `memoir-mcp` executable.
///
/// The server is the real thing, run as a subprocess against the workspace database.
/// The exchange is deliberately batched and synchronous (write every frame, close
/// stdin, read stdout to EOF, wait for exit), so there is no polling, no sleeping and
/// no interleaving to get wrong. The traffic is a few kilobytes, comfortably inside a
/// pipe buffer, so nothing can deadlock.
///
/// stderr is redirected to a file rather than a pipe: the server logs there on every
/// run, and an unread pipe is a deadlock waiting to happen. The captured text is
/// attached to failure messages.
enum EndToEndMCP {

    /// One `tools/call` to make.
    struct Call: Sendable {
        /// JSON-RPC request id. Must not be 1, which the handshake uses.
        let id: Int
        /// Tool name from `ToolCatalog.names`.
        let name: String
        /// The `arguments` object, already serialised, e.g. `"{}"`.
        let argumentsJSON: String
    }

    /// Everything the conversation produced. Every field is `Sendable`.
    struct Transcript: Sendable {
        /// `result.protocolVersion` from `initialize`.
        let protocolVersion: String?
        /// `result.serverInfo.name` from `initialize`.
        let serverName: String?
        /// The first text content block of each `tools/call`, keyed by request id.
        let toolTexts: [Int: String]
        /// Any `error` member, keyed by request id.
        let errors: [Int: String]
        /// stdout lines that were not valid JSON. Must always be empty.
        let unparsableLines: [String]
        /// Everything the server wrote to stderr.
        let stderrText: String
        /// Process exit status.
        let exitStatus: Int32
    }

    /// Runs the handshake plus `calls` against `database` and returns what came back.
    ///
    /// - Parameters:
    ///   - database: the SQLite file to point the server at. Passed with `--db`, which is
    ///     the only thing standing between this test and the user's real memory: the
    ///     task-local `Paths` override does not cross a process boundary.
    ///   - stderrURL: where the server's diagnostics are collected.
    ///   - calls: the tool calls to make, in order.
    static func run(database: URL, stderrURL: URL, calls: [Call]) throws -> Transcript {
        let binary = try MCPBinary.url()

        var frames: [String] = [
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
                + "\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},"
                + "\"clientInfo\":{\"name\":\"memoir-integration-tests\",\"version\":\"1.0\"}}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        ]
        for call in calls {
            let params = "{\"name\":\"\(call.name)\",\"arguments\":\(call.argumentsJSON)}"
            frames.append(
                "{\"jsonrpc\":\"2.0\",\"id\":\(call.id),\"method\":\"tools/call\",\"params\":\(params)}"
            )
        }

        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: stderrURL)

        let process = Process()
        process.executableURL = binary
        process.arguments = MCPBinary.arguments(database: database)
        var environment = ProcessInfo.processInfo.environment
        // Belt and braces: even if `--db` were ignored, this must not be the real database.
        environment["MEMOIR_DB_PATH"] = database.path
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorHandle

        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data((frames.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()

        let stdoutData = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try? errorHandle.close()

        var protocolVersion: String?
        var serverName: String?
        var toolTexts: [Int: String] = [:]
        var errors: [Int: String] = [:]
        var unparsable: [String] = []

        let lines = String(decoding: stdoutData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let text = String(line)
            guard
                let data = text.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                unparsable.append(text)
                continue
            }
            let id = object["id"] as? Int
            if let failure = object["error"] as? [String: Any] {
                errors[id ?? -1] = String(describing: failure)
                continue
            }
            guard let result = object["result"] as? [String: Any] else { continue }
            if id == 1 {
                protocolVersion = result["protocolVersion"] as? String
                serverName = (result["serverInfo"] as? [String: Any])?["name"] as? String
            }
            if let id,
               let content = result["content"] as? [[String: Any]],
               let block = content.first?["text"] as? String {
                toolTexts[id] = block
            }
        }

        return Transcript(
            protocolVersion: protocolVersion,
            serverName: serverName,
            toolTexts: toolTexts,
            errors: errors,
            unparsableLines: unparsable,
            stderrText: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "",
            exitStatus: process.terminationStatus
        )
    }

    /// The run of `- ` bullet lines immediately following `heading` in markdown output.
    ///
    /// Used to isolate the provenance block of an entity from the rest of a `recall`
    /// answer, so an assertion about attribution cannot accidentally be satisfied by
    /// the raw-capture section further down.
    static func bulletsUnder(_ heading: String, in markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading })
        else { return [] }
        return Array(lines[(start + 1)...].prefix(while: { $0.hasPrefix("- ") }))
    }
}
