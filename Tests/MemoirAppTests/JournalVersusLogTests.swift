import Foundation
import Testing

@testable import MemoirApp
@testable import MemoirKit

/// The difference between the sentence somebody wrote and the filename Memoir read.
///
/// The bug: the calendar's day listed everything `source == .authored`, and the vault importer
/// marks every imported markdown file authored on purpose: it is the user's writing, and the
/// merge law has to protect it from anything that guesses. So a day showed three Obsidian
/// filenames (*Architecture*, *Launch Copy*, *Competitive Landscape*) in the same type as the
/// one thing actually typed into the journal, with nothing to tell them apart.
///
/// The test that holds is provenance, and `MemoryService.commitPush` already states it: an entry
/// written here carries none, because there is no capture behind it. Everything Memoir picked
/// up, off a screen or out of a folder, points at the capture it came from.
@MainActor
struct JournalVersusLogTests {

    private func store(_ name: String = "jvl") throws -> (Store, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try Store(path: dir.appendingPathComponent("t.sqlite"), mayMigrate: true), dir)
    }

    /// One imported vault note, exactly as `VaultImporter` writes it: authored, with a capture
    /// behind it and provenance pointing at that capture.
    private func addVaultNote(_ title: String, to store: Store, at when: Date) async throws {
        let id = MemoryText.stableID("entity", EntityKind.note.rawValue,
                                     MemoryText.normalizedTitle(title))
        let capture = CaptureEvent(
            id: "vaultcap-\(id)", ts: when,
            appBundleID: VaultImporter.bundleID, appName: VaultImporter.appName,
            windowTitle: title, text: "the body of \(title)", textHash: "h-\(id)"
        )
        try await store.insert(capture: capture)
        try await store.upsert(entity: Entity(
            id: id, kind: .note, title: title, detail: nil, dueAt: nil,
            confidence: 0.95, source: .authored, createdAt: when, updatedAt: when
        ))
        try await store.add(provenance: Provenance(
            entityID: id, captureID: capture.id, field: "title", snippet: title, ts: when
        ))
    }

    @Test("a day separates what you wrote from what Memoir read out of a folder")
    func vaultNotesAreNotJournalEntries() async throws {
        let (store, dir) = try store()
        defer { Task { await store.close() }; try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        // The three that started this: real Obsidian filenames, imported today.
        for title in ["Architecture", "Launch Copy", "Competitive Landscape"] {
            try await addVaultNote(title, to: store, at: now)
        }
        // And something Memoir worked out on its own.
        try await addVaultNote("GTM value proposition", to: store, at: now)

        // The one thing actually written in the journal, through the path that writes one.
        let memory = MemoryService(store: store, extractors: [])
        try await memory.commitPush(PushIntent(kind: .note, title: "Long day. Slept badly.",
                                               source: "Long day. Slept badly."))

        let written = try await store.notes(written: true, from: .distantPast, to: .distantFuture)
        #expect(written.map(\.title) == ["Long day. Slept badly."],
                "the journal should hold only what was typed into it")

        let dayStart = Calendar.current.startOfDay(for: now)
        let picked = try await store.notes(written: false,
                                           from: dayStart,
                                           to: dayStart.addingTimeInterval(86_400))
        #expect(Set(picked.map(\.title)) == [
            "Architecture", "Launch Copy", "Competitive Landscape", "GTM value proposition"
        ], "everything with a capture behind it is something Memoir picked up")
    }

    @Test("the day separates the two, and writing is the calendar's")
    func bothPanesAgree() async throws {
        let (store, dir) = try store("jvl-panes")
        defer { Task { await store.close() }; try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        try await addVaultNote("Architecture", to: store, at: now)
        let memory = MemoryService(store: store, extractors: [])
        try await memory.commitPush(PushIntent(kind: .note, title: "Wrote this one.",
                                               source: "Wrote this one."))

        let shell = try ShellModel.forPreview(store: store)
        await shell.calendar.reload()
        #expect(shell.calendar.entries.map(\.title) == ["Wrote this one."])
        #expect(shell.calendar.picked.map(\.title) == ["Architecture"])

        // One surface now: the day you are reading is the day you write on, so there is no
        // second list to keep in step. The calendar's entries are the journal.
        #expect(shell.calendar.entries.map(\.title) == ["Wrote this one."],
                "an imported folder must not show up as a journal entry")
    }

    @Test("earlier years hold journal entries, not imported filenames")
    func onThisDayIsJournalOnly() async throws {
        let (store, dir) = try store("jvl-history")
        defer { Task { await store.close() }; try? FileManager.default.removeItem(at: dir) }

        let calendar = Calendar.current
        let lastYear = try #require(calendar.date(byAdding: .year, value: -1, to: Date()))
        try await addVaultNote("Competitive Landscape", to: store, at: lastYear)

        let memory = MemoryService(store: store, extractors: [])
        let entry = try await memory.commitPush(
            PushIntent(kind: .note, title: "A year ago today.", source: "A year ago today."),
            now: lastYear
        )
        #expect(entry.updatedAt == lastYear)

        let shell = try ShellModel.forPreview(store: store)
        await shell.calendar.reload()

        let history = shell.calendar.onThisDay.flatMap(\.entries).map(\.title)
        #expect(history == ["A year ago today."],
                "on this day is the reason for the decade; a filename is not a memory of one")
    }
}
