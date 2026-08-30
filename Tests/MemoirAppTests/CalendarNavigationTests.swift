import Foundation
import Testing

@testable import MemoirApp
@testable import MemoirKit

/// Navigating to a day, and the difference between the two ways of arriving at the Calendar pane.
///
/// The bug these pin: the pane owned its own `@StateObject`, so which day you were reading was
/// per-view state. Asking for "today" in the ask bar switched the tab and could leave you looking
/// at whatever month you had browsed to, and the shell had no way to reach the selection to fix
/// it. `ShellModel` already documents the rule this broke: pane models are held on the shell so
/// reopening the band does not throw away a selected person or a half-written entry.
@MainActor
struct CalendarNavigationTests {

    private func shell() throws -> (ShellModel, Store) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calnav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(path: dir.appendingPathComponent("memoir.sqlite"), mayMigrate: true)
        return (try ShellModel.forPreview(store: store), store)
    }

    @Test("Stepping the month moves the grid and leaves the day alone")
    func stepMonthMovesTheGrid() async throws {
        let (shell, store) = try shell()
        defer { Task { await store.close() } }

        let calendar = Calendar.current
        let model = shell.calendar
        let startMonth = model.visibleMonth
        let startDay = model.selected

        model.stepMonth(-1)
        #expect(calendar.dateComponents([.year, .month], from: model.visibleMonth)
                == calendar.dateComponents([.year, .month],
                                           from: calendar.date(byAdding: .month, value: -1, to: startMonth)!),
                "back did not move the grid")
        #expect(model.selected == startDay, "stepping the grid must not move the selected day")

        model.stepMonth(1)
        #expect(calendar.dateComponents([.year, .month], from: model.visibleMonth)
                == calendar.dateComponents([.year, .month], from: startMonth),
                "forward did not come back")
    }

    @Test("Asking for today returns to today, from any day you had browsed to")
    func openTodayResetsTheDay() async throws {
        let (shell, store) = try shell()
        defer { Task { await store.close() } }

        let calendar = Calendar.current
        let longAgo = calendar.date(byAdding: .year, value: -3, to: Date())!
        shell.calendar.select(longAgo)
        #expect(!shell.calendar.isToday, "the selection did not move")

        shell.openToday()

        #expect(shell.calendar.isToday, "asking for today must land on today")
        #expect(shell.pane == .calendar)
    }

    @Test("Clicking the tab keeps the day you were reading")
    func openingThePaneKeepsTheDay() async throws {
        // The other half, and the reason `openToday()` is a separate entry point rather than a
        // reset inside `open(pane:)`. Someone reading last August who switches to People and back
        // is still reading last August.
        let (shell, store) = try shell()
        defer { Task { await store.close() } }

        let lastAugust = Calendar.current.date(byAdding: .month, value: -12, to: Date())!
        shell.calendar.select(lastAugust)
        let chosen = shell.calendar.selected

        shell.open(pane: .portrait)
        shell.open(pane: .calendar)

        #expect(shell.calendar.selected == chosen, "the day was thrown away by a tab switch")
    }

    @Test("The selected day survives the band closing")
    func selectionSurvivesTheBandClosing() async throws {
        // Why the model is on the shell at all. A per-view `@StateObject` is recreated whenever
        // SwiftUI rebuilds the pane, and the band closing and reopening is exactly that.
        let (shell, store) = try shell()
        defer { Task { await store.close() } }

        let day = Calendar.current.date(byAdding: .day, value: -40, to: Date())!
        shell.calendar.select(day)
        let chosen = shell.calendar.selected

        shell.collapse()
        shell.open(pane: .calendar)

        #expect(shell.calendar.selected == chosen)
    }

    @Test("Stepping the grid by months does not move the selected day")
    func steppingMonthsKeepsSelection() async throws {
        // Browsing is not selecting. Paging back through the grid to look at last winter must not
        // silently change which day the right-hand column is showing.
        let (shell, store) = try shell()
        defer { Task { await store.close() } }

        let today = shell.calendar.selected
        shell.calendar.stepMonth(-2)

        #expect(shell.calendar.selected == today, "paging the grid moved the day")
        #expect(
            !Calendar.current.isDate(shell.calendar.visibleMonth, equalTo: today, toGranularity: .month),
            "the grid did not move"
        )
    }
}
