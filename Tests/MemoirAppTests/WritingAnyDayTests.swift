import Foundation
import Testing

@testable import MemoirApp
@testable import MemoirKit

/// Writing on the day you are reading, including one that has already happened.
///
/// The Journal was a surface of its own and could only ever write about today, which made the
/// product's own ten-year claim half-reachable: you could read August 2019 and not put a word
/// against it. Reading and writing a day are the same act on the same surface now.
///
/// Two things here are easy to get wrong and silent when you do, so both are pinned:
/// an entry is **filed under the day it is about** rather than the day it was typed, and an
/// edit **rewrites the row that exists** rather than minting a second one beside it.
@MainActor
struct WritingAnyDayTests {

    private func shell(_ name: String = "writeday") throws -> (ShellModel, Store, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(path: dir.appendingPathComponent("t.sqlite"), mayMigrate: true)
        return (try ShellModel.forPreview(store: store), store, dir)
    }

    @Test("An entry written about a past day is filed under that day, not today")
    func writingBackfills() async throws {
        let (shell, store, dir) = try shell()
        defer { Task { await store.close() }; try? FileManager.default.removeItem(at: dir) }

        let calendar = Calendar.current
        let tuesday = try #require(calendar.date(byAdding: .day, value: -12, to: Date()))
        let model = shell.calendar

        model.select(tuesday)
        model.draft = "Rained the whole afternoon and I got nothing done."
        model.write()

        // The write is a task; let it land.
        try await Task.sleep(for: .milliseconds(400))
        await model.reload()

        #expect(model.entries.map(\.title) == ["Rained the whole afternoon and I got nothing done."],
                "the entry did not land on the day it was written about")

        let entry = try #require(model.entries.first)
        #expect(calendar.isDate(entry.updatedAt, inSameDayAs: tuesday),
                "filed under the wrong day, so the month grid and on-this-day would both lie")
        #expect(calendar.isDateInToday(entry.createdAt),
                "the record should still know it was typed today")

        // And today itself stays empty: nothing was filed under it.
        model.select(Date())
        await model.reload()
        #expect(model.entries.isEmpty, "a back-dated entry leaked into today")
    }

    @Test("Rewriting an entry changes it in place and keeps its day")
    func editingKeepsTheDay() async throws {
        let (shell, store, dir) = try shell("editday")
        defer { Task { await store.close() }; try? FileManager.default.removeItem(at: dir) }

        let calendar = Calendar.current
        let monday = try #require(calendar.date(byAdding: .day, value: -6, to: Date()))
        let memory = shell.memory
        let original = try await memory.writeEntry("Send the draft by Thursday.", filedAt: monday)

        let model = shell.calendar
        model.select(monday)
        await model.reload()
        #expect(model.entries.count == 1)

        model.beginEdit(try #require(model.entries.first))
        model.editDraft = "Send the draft by Friday."
        model.saveEdit()

        try await Task.sleep(for: .milliseconds(400))
        await model.reload()

        // One entry, not two. The ordinary write path derives the id from the text, so an edit
        // routed through it would leave the original standing beside the new one.
        #expect(model.entries.count == 1, "the edit was written as a second entry")
        let edited = try #require(model.entries.first)
        #expect(edited.title == "Send the draft by Friday.")
        #expect(edited.id == original.id, "the row was replaced rather than rewritten")
        #expect(calendar.isDate(edited.updatedAt, inSameDayAs: monday),
                "saving an edit moved the entry out of its day")
    }

    @Test("An empty rewrite is refused rather than emptying the entry")
    func emptyEditIsRefused() async throws {
        let (shell, store, dir) = try shell("emptyedit")
        defer { Task { await store.close() }; try? FileManager.default.removeItem(at: dir) }

        let memory = shell.memory
        try await memory.writeEntry("Something worth keeping.", filedAt: Date())
        try await memory.rewriteEntry(id: MemoryService.pushID(
            for: PushIntent(kind: .note, title: "Something worth keeping.",
                            source: "Something worth keeping."), now: Date()), title: "   ")

        let written = try await store.notes(written: true, from: .distantPast, to: .distantFuture)
        #expect(written.map(\.title) == ["Something worth keeping."],
                "whitespace is not an edit; the entry should be untouched")
    }

    @Test("Moving to another day drops the draft rather than carrying it over")
    func draftBelongsToItsDay() async throws {
        let (shell, store, dir) = try shell("draftday")
        defer { Task { await store.close() }; try? FileManager.default.removeItem(at: dir) }

        let model = shell.calendar
        let earlier = try #require(Calendar.current.date(byAdding: .day, value: -3, to: Date()))

        model.select(earlier)
        model.draft = "half a sentence about Tuesday"
        model.select(Date())

        #expect(model.draft.isEmpty,
                "a draft carried across days would file Tuesday's sentence under today")
    }
}
