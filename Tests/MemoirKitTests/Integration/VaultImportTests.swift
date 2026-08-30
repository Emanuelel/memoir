import Foundation
import Testing
import MemoirFixtures
@testable import MemoirKit

// CF-74: the vault is read, never written, and what it says is authored.
//
// A markdown folder is an ontology the user already hand-built. Importing it must:
// produce authored entities with aliases and provenance pointing at real capture rows
// (CF-15 applies to vault entities too); be idempotent; treat the file as canon on
// re-import; and never, under any circumstances, write into the folder.

@Suite("CF-74 vault import")
struct VaultImportTests {

    /// Builds a small vault on disk inside the workspace and returns its root.
    private func makeVault(in ws: TestWorkspace) throws -> URL {
        let root = ws.root.appendingPathComponent("vault", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("People"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Memoir"), withIntermediateDirectories: true)

        try """
        ---
        aliases: [fenwick, FEN-42]
        ---
        Move billing off the legacy Fenwick stack before the contract renews.

        ## Status
        Rate limiter is the open question.
        """.write(to: root.appendingPathComponent("Projects/Fenwick Migration.md"), atomically: true, encoding: .utf8)

        try """
        ---
        aliases:
          - priya
        ---
        Platform lead on the billing side. Owns the rate limiter review.
        """.write(to: root.appendingPathComponent("People/Priya Raman.md"), atomically: true, encoding: .utf8)

        try """
        ---
        type: commitment
        due: 2026-03-20
        ---
        Send the revised invoice to Fenwick accounts.
        """.write(to: root.appendingPathComponent("Send revised invoice.md"), atomically: true, encoding: .utf8)

        // Never read: tool internals and Memoir's own write-back area.
        try "workspace config junk".write(
            to: root.appendingPathComponent(".obsidian/workspace.md"), atomically: true, encoding: .utf8)
        try "a daily note Memoir itself wrote".write(
            to: root.appendingPathComponent("Memoir/2026-03-15.md"), atomically: true, encoding: .utf8)

        return root
    }

    /// Every file's path, size and modification date under a folder, for the
    /// read-only proof.
    private func fingerprint(_ folder: URL) throws -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            out.append("\(item.path)|\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)")
        }
        return out.sorted()
    }

    @Test("CF-74 notes become authored entities with aliases, kinds and provenance")
    func importProducesAuthoredEntities() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let vault = try makeVault(in: ws)

            let summary = try await memory.importVault(at: vault, now: TestClock.reference)
            #expect(summary.notesRead == 3, "three real notes; .obsidian and Memoir/ are skipped")

            let all = try await store.entities(kind: nil, includeDeleted: false)
            let byTitle = Dictionary(uniqueKeysWithValues: all.map { ($0.title, $0) })

            let fenwick = try #require(byTitle["Fenwick Migration"])
            #expect(fenwick.kind == .project, "the Projects folder names the kind")
            #expect(fenwick.source == .authored)
            #expect(fenwick.aliases == ["fenwick", "FEN-42"])
            #expect(fenwick.detail?.contains("legacy Fenwick stack") == true)

            let priya = try #require(byTitle["Priya Raman"])
            #expect(priya.kind == .person)
            #expect(priya.aliases == ["priya"], "block-list aliases parse too")

            let invoice = try #require(byTitle["Send revised invoice"])
            #expect(invoice.kind == .commitment, "frontmatter type wins")
            #expect(invoice.dueAt != nil)

            // CF-15 holds for vault entities: provenance points at a real capture row.
            let evidence = try await store.provenance(entityID: fenwick.id)
            #expect(!evidence.isEmpty)
            let capture = try await store.capture(id: try #require(evidence.first?.captureID))
            #expect(capture?.appName == "Vault")
            #expect(capture?.windowTitle == "Fenwick Migration")
        }
    }

    @Test("CF-74 re-import is idempotent; an edited note is canon")
    func reimportIsIdempotentAndCanon() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let vault = try makeVault(in: ws)

            _ = try await memory.importVault(at: vault, now: TestClock.reference)
            let countAfterFirst = try await store.entities(kind: nil, includeDeleted: false).count
            _ = try await memory.importVault(at: vault, now: TestClock.minutes(5))
            let countAfterSecond = try await store.entities(kind: nil, includeDeleted: false).count
            #expect(countAfterFirst == countAfterSecond, "re-import must not duplicate")

            // The user edits their note; the vault is canon for authored fields.
            try """
            ---
            aliases: [fenwick, FEN-42]
            ---
            Billing migration is DONE, retro scheduled.
            """.write(to: vault.appendingPathComponent("Projects/Fenwick Migration.md"),
                      atomically: true, encoding: .utf8)
            _ = try await memory.importVault(at: vault, now: TestClock.minutes(10))

            let fenwick = try #require(
                try await store.entities(kind: .project, includeDeleted: false)
                    .first { $0.title == "Fenwick Migration" }
            )
            #expect(fenwick.detail?.contains("DONE") == true, "the edited file wins")
            #expect(fenwick.source == .authored)
        }
    }

    @Test("CF-74 the importer never writes into the vault")
    func vaultIsNeverWritten() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let vault = try makeVault(in: ws)

            let before = try fingerprint(vault)
            _ = try await memory.importVault(at: vault, now: TestClock.reference)
            let after = try fingerprint(vault)
            #expect(before == after, "every path, size and mtime unchanged")
        }
    }

    @Test("CF-74 a missing folder throws instead of silently importing nothing")
    func missingFolderThrows() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            await #expect(throws: MemoirError.self) {
                try await memory.importVault(
                    at: ws.root.appendingPathComponent("no-such-folder"),
                    now: TestClock.reference
                )
            }
        }
    }

    @Test("CF-74 after import, on-screen aliases corroborate the vault entity")
    func onScreenAliasCorroborates() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let vault = try makeVault(in: ws)
            _ = try await memory.importVault(at: vault, now: TestClock.reference)

            // The screen mentions the alias; consolidation must corroborate, not twin.
            try await store.insert(capture: Fixtures.capture(
                text: "FEN-42 blocked on rate limiter review with priya",
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                windowTitle: "#fenwick \u{2014} Slack",
                at: TestClock.minutes(30), name: "alias-sighting"
            ))
            _ = try await memory.consolidate(since: TestClock.minutes(29), now: TestClock.minutes(31))

            let projects = try await store.entities(kind: .project, includeDeleted: false)
                .filter { $0.title.lowercased().contains("fen") }
            #expect(projects.count == 1, "no inferred twin beside the authored project")
            #expect(projects.first?.source == .authored)
        }
    }
}
