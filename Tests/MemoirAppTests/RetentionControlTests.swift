import Foundation
import Testing
import MemoirKit
@testable import MemoirApp

// The retention control and the number zero.
//
// Zero is how the config spells "keep everything", and it is the shipping default. The
// settings audit found the control pretending otherwise twice over: the stepper rendered
// the default as "Keep raw captures for 0 days" next to a projection sentence saying
// everything is kept, and because the stepper's floor is 1, anyone who touched it could
// never get back to zero through the UI. The fix routes keep-everything through
// `SettingsModel.setKeepsEverything`, and these tests pin that path down.

@Suite("keep-everything is a reachable state of the retention control")
@MainActor
struct RetentionControlTests {

    /// Builds a settings model against a throwaway store and support directory.
    ///
    /// The override has to wrap the whole body: `setKeepsEverything` calls `apply()`, which
    /// saves the config, and without the override that write lands in the real
    /// `~/Library/Application Support/Memoir/config.json` of whoever runs the suite.
    private func withModel(_ body: (SettingsModel, _ applied: () -> Int) throws -> Void) throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try Paths.$supportDirectoryOverride.withValue(temp) {
            let store = try Store(path: temp.appendingPathComponent("memoir.sqlite"), mayMigrate: true)
            defer { Task { await store.close() } }
            var applied = 0
            let model = SettingsModel(
                config: AppConfig(),
                store: store,
                router: BrainRouter(preferred: .appleOnDevice, store: store, config: BrainConfig()),
                restraint: RestraintEngine(config: .default),
                memory: MemoryService(store: store, extractors: []),
                onConfigChanged: { _ in applied += 1 }
            )
            try body(model) { applied }
        }
    }

    @Test("the shipping default reads as keep-everything, not as a zero-day window")
    func defaultIsKeepEverything() throws {
        try withModel { model, _ in
            #expect(model.config.retentionDays == 0)
            #expect(model.keepsEverything, "the default must render the toggle, never '0 days'")
        }
    }

    @Test("switching deletion on lands on a real window, and the app is told")
    func switchingOffKeepEverythingGivesAWindow() throws {
        try withModel { model, applied in
            model.setKeepsEverything(false)
            #expect(model.config.retentionDays > 0,
                    "a stepper floored at 1 day must never be handed a zero")
            #expect(!model.keepsEverything)
            #expect(applied() == 1, "the change was not applied, so it would not survive a relaunch")
        }
    }

    @Test("zero is reachable again from any window the stepper can produce")
    func keepEverythingIsReachableFromAWindow() throws {
        // The reported bug: once the stepper (floor 1) had been touched, no path through
        // the UI led back to keeping everything.
        try withModel { model, applied in
            model.config.retentionDays = 365
            model.setKeepsEverything(true)
            #expect(model.config.retentionDays == 0)
            #expect(model.keepsEverything)
            #expect(applied() == 1)
        }
    }

    @Test("the window you chose survives a round trip through keep-everything")
    func chosenWindowSurvivesTheRoundTrip() throws {
        try withModel { model, _ in
            model.config.retentionDays = 30   // what the stepper writes
            model.setKeepsEverything(true)
            model.setKeepsEverything(false)
            #expect(model.config.retentionDays == 30,
                    "flipping the toggle twice ate the number the user picked")
        }
    }

    /// A unit test on the model cannot notice a toggle that was never wired to it, and that
    /// is this codebase's signature failure: code written, tested, and called from nowhere.
    /// So this reads the settings source and asserts the view actually calls the setter.
    /// Comments are stripped first, because the doc comment on `keepsEverything` names the
    /// bug and would otherwise keep this green with the wiring deleted.
    @Test("the settings pane actually drives keep-everything through the model")
    func keepEverythingIsWiredIntoTheView() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MemoirAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/MemoirApp/UI/SettingsView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let code = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        #expect(code.contains("model.setKeepsEverything("),
                "no control in SettingsView calls setKeepsEverything: keep-everything is unreachable again")
        #expect(code.contains("!model.keepsEverything"),
                "nothing in SettingsView is conditioned on keepsEverything, so the '0 days' stepper is back on screen")
    }
}
