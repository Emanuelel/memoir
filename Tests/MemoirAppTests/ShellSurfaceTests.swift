import Foundation
import Testing

@testable import MemoirApp
@testable import MemoirKit

/// The two rules the band's surface has to keep: the microphone is never opened by
/// navigation, and the tabs sit in the order somebody chose rather than the order the
/// enum happens to declare.
@MainActor
struct ShellSurfaceTests {

    private func shell() throws -> (ShellModel, Store) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellsurface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(path: dir.appendingPathComponent("memoir.sqlite"), mayMigrate: true)
        return (try ShellModel.forPreview(store: store), store)
    }

    @Test("Opening Ask does not open the microphone")
    func askDoesNotOpenTheMic() async throws {
        // It used to: the band opened onto Ask and started listening in one motion. A hot mic
        // nobody asked for is the one thing this product cannot afford to do by surprise, so
        // the mic button is now the only thing that opens it.
        let (shell, store) = try shell()
        defer { Task { await store.close() } }

        shell.open(pane: .ask)

        #expect(shell.pane == .ask)
        #expect(shell.chat.voice.state == .idle, "landing on Ask opened the microphone")
    }

    @Test("No pane opens the microphone")
    func noPaneOpensTheMic() async throws {
        let (shell, store) = try shell()
        defer { Task { await store.close() } }

        for pane in ShellModel.PaneID.bandTabs {
            shell.open(pane: pane)
            #expect(shell.chat.voice.state == .idle, "opening \(pane.title) opened the microphone")
        }
    }

    @Test("Opening by hand lands where you left off, and does not rewrite the choice")
    func openingKeepsTheRememberedTab() async throws {
        // The bug: the face on the collapsed band called `open(pane: .portrait)`, and selecting
        // a pane persists it, so clicking the notch both ignored the remembered tab and wrote
        // People over it. A tab preference could never survive being opened by hand.
        let (shell, store) = try shell()
        defer { Task { await store.close() } }

        shell.open(pane: .portrait)
        shell.collapse()

        // What the face does, from the collapsed band.
        shell.open(pane: shell.pane)
        #expect(shell.pane == .portrait, "opening by hand threw away the remembered tab")
    }

    @Test("Home is the first tab")
    func homeIsTheFirstTab() {
        #expect(ShellModel.PaneID.home == ShellModel.PaneID.bandTabs[0])
        #expect(ShellModel.PaneID.home == .calendar)
    }

    @Test("The tabs read Calendar, Ask, People")
    func tabsAreInOrder() {
        // Journal is not among them. Writing happens on the day you are reading, in the
        // Calendar, which is what lets you write about a day that has already happened.
        #expect(ShellModel.PaneID.bandTabs.map(\.title) == ["Calendar", "Ask", "People"])
        #expect(!ShellModel.PaneID.journal.inBand)
    }

    @Test("Every tab in the band is a band pane, and every band pane is a tab")
    func tabsCoverTheBand() {
        // The order is written out by hand, so nothing derives it from `allCases` any more.
        // This is what stops a new band pane being added and silently never getting a tab.
        let listed = Set(ShellModel.PaneID.bandTabs)
        let inBand = Set(ShellModel.PaneID.allCases.filter(\.inBand))
        #expect(listed == inBand)
        #expect(ShellModel.PaneID.bandTabs.count == inBand.count, "a tab is listed twice")
    }
}
