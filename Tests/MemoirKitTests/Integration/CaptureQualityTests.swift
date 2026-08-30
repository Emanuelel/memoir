import Foundation
import Testing
import MemoirFixtures
@testable import MemoirKit

// CF-73: capture coverage is honest and visible. For a product whose pitch is
// provenance, silent partial coverage is the worst failure available: the user assumes
// the Slack thread was seen, and it wasn't. The grades must reflect what was actually
// read, and an app that yields nothing must say so rather than disappear.

@Suite("CF-73 capture quality")
struct CaptureQualityTests {

    @Test("CF-73 Memoir's own bookkeeping is not graded as an app it reads")
    func ownPseudoAppsAreNotGraded() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            // The focus timer records sessions and never captures, by design. Grading it
            // produced "2 of 16 apps read poorly or not at all: Memoir, Focus" in the doctor,
            // which is a problem report about nothing, and an instrument that cries wolf
            // about its own bookkeeping is one nobody reads twice.
            try await seed(
                store: store,
                captures: [Fixtures.capture(
                    text: "real screen text from a real app", app: "Notes",
                    bundleID: "com.apple.Notes", windowTitle: "Work",
                    at: TestClock.reference, name: "real"
                )],
                sessions: [
                    makeSession(appName: "Focus", bundleID: "sh.memoir.focus",
                                from: TestClock.reference, to: TestClock.minutes(25)),
                    makeSession(appName: "Notes", bundleID: "com.apple.Notes",
                                from: TestClock.reference, to: TestClock.minutes(10)),
                ]
            )
            let coverage = try await store.captureQuality(since: TestClock.days(-1))
            #expect(!coverage.contains { $0.bundleID.hasPrefix("sh.memoir.") || $0.bundleID.hasPrefix("sh.pip.") },
                    "graded its own bookkeeping: \(coverage.map(\.appName))")
            #expect(coverage.contains { $0.appName == "Notes" }, "a real app must still be graded")
        }
    }


    @Test("CF-73 rich, thin and silent apps grade apart")
    func gradesSeparate() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let hourAgo = TestClock.hours(-1)

            // Three apps, 30 active minutes each; only what they yield differs.
            let sessions = [
                makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                            from: hourAgo, to: TestClock.minutes(-30)),
                makeSession(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                            from: hourAgo, to: TestClock.minutes(-30)),
                makeSession(appName: "Figma", bundleID: "com.figma.Desktop",
                            from: hourAgo, to: TestClock.minutes(-30)),
            ]
            var captures: [CaptureEvent] = []
            // Xcode: a full buffer every few minutes, which is native-app volume.
            for i in 0..<10 {
                captures.append(Fixtures.capture(
                    text: String(repeating: "func compile\(i)() { } ", count: 80),
                    app: "Xcode", bundleID: "com.apple.dt.Xcode",
                    windowTitle: "Sources/Main.swift",
                    at: TestClock.minutes(Double(-58 + i * 3)), name: "xc-\(i)"
                ))
            }
            // Slack: a trickle of titles and fragments.
            for i in 0..<3 {
                captures.append(Fixtures.capture(
                    text: "thread reply \(i)",
                    app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                    windowTitle: "#general \u{2014} Slack",
                    at: TestClock.minutes(Double(-55 + i * 8)), name: "sl-\(i)"
                ))
            }
            // Figma: thirty minutes of use, zero captures.
            try await seed(store: store, captures: captures, sessions: sessions)

            let quality = try await store.captureQuality(since: TestClock.hours(-2))
            let byName = Dictionary(uniqueKeysWithValues: quality.map { ($0.appName, $0) })

            #expect(byName["Xcode"]?.grade == .good)
            #expect(byName["Slack"]?.grade == .poor || byName["Slack"]?.grade == .partial,
                    "a trickle must not be graded as good")
            #expect(byName["Figma"]?.grade == .nothing,
                    "real use with zero text is reported, not hidden")
            #expect(byName["Figma"]?.captureCount == 0)
        }
    }

    @Test("CF-73 brief use is unknown, not condemned")
    func briefUseIsUnknown() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            // Two minutes in an app, nothing captured: not enough evidence to grade.
            try await seed(store: store, sessions: [
                makeSession(appName: "Calculator", bundleID: "com.apple.calculator",
                            from: TestClock.minutes(-2), to: TestClock.reference)
            ])
            let quality = try await store.captureQuality(since: TestClock.hours(-1))
            #expect(quality.first?.grade == .unknown)
        }
    }

    @Test("CF-73 the window bounds the verdict")
    func windowBounds() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            // Heavy use last month, none this week.
            try await seed(
                store: store,
                captures: [Fixtures.capture(
                    text: "old work", app: "Xcode", bundleID: "com.apple.dt.Xcode",
                    windowTitle: "old", at: TestClock.days(-30), name: "old"
                )],
                sessions: [makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                                       from: TestClock.days(-30), to: TestClock.days(-29.9))]
            )
            let thisWeek = try await store.captureQuality(since: TestClock.days(-7))
            #expect(thisWeek.isEmpty, "last month's coverage is not this week's answer")
        }
    }
}
