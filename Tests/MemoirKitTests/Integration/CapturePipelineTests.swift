//
//  CapturePipelineTests.swift
//  CF-10, CF-11, CF-12, CF-13: the capture pipeline.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  What is real here and what is faked, and why.
//
//  The accessibility API is a process boundary: `AXUIElementCopyAttributeValue` talks to
//  another application through the window server, needs a granted Accessibility permission,
//  and returns `kAXErrorAPIDisabled` in a test process. It is therefore the *only* thing
//  these tests fake.
//
//  Everything downstream of it is production code running for real:
//
//    on-screen text ──▶ AccessibilityCapture.admit  ──▶ CaptureLoop.tick ──▶ Store (real SQLite)
//                       trim / truncate / hash /         sessions,
//                       dedupe / build the row           capture writes
//
//  and the bounded tree walk *upstream* of it is production code too: `BoundedTextWalk` is
//  generic over its node type precisely so its four ceilings can be driven by a synthetic
//  tree instead of a live one.
//
//  Time is injected everywhere: `CaptureLoop.tick(now:)`, `CaptureLoop.stop(now:)` and
//  `AccessibilityCapture.admit(..., now:)` all take their instant from `TestClock`. Nothing
//  in this file sleeps, and nothing reads the wall clock.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

// MARK: - The apps in the script

/// Stable stand-ins for the frontmost application. The pids are arbitrary and never used:
/// nothing in these tests reaches the accessibility API, which is the only consumer of a pid.
enum TestApps {
    static let slack = FrontmostApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", pid: 5_001)
    static let chrome = FrontmostApp(bundleID: "com.google.Chrome", name: "Google Chrome", pid: 5_002)
    static let mail = FrontmostApp(bundleID: "com.apple.mail", name: "Mail", pid: 5_003)
    static let onePassword = FrontmostApp(bundleID: "com.1password.1password", name: "1Password", pid: 5_004)
}

/// A capture configuration with an empty exclusion list, so a test app is only ever excluded
/// when a test says so.
func captureConfig(
    idleThreshold: Double = 120,
    excluding excluded: Set<String> = [],
    windowTitles: Bool = true,
    maxTextLength: Int = 20_000
) -> CaptureConfig {
    CaptureConfig(
        idleThresholdSeconds: idleThreshold,
        excludedBundleIDs: excluded,
        captureWindowTitles: windowTitles,
        maxTextLength: maxTextLength
    )
}

// MARK: - The fake at the accessibility boundary

/// What one poll of the accessibility tree came back with.
struct ScreenFrame: Sendable {
    let app: FrontmostApp
    let text: String
    let windowTitle: String?
}

/// A `CaptureSource` that replays scripted accessibility reads through the **real**
/// `AccessibilityCapture`.
///
/// The only thing this replaces is the tree walk. Trimming, truncation, hashing, the dedupe
/// gate and the construction of the `CaptureEvent` are all `AccessibilityCapture.admit`,
/// which is exactly what `snapshot()` calls in production.
actor ScriptedScreen: CaptureSource {

    private let capture: AccessibilityCapture
    private var frame: ScreenFrame?
    private var now: Date

    /// How many times the loop actually asked for a snapshot. Distinguishes "the loop skipped
    /// the read" from "the read was deduped away".
    private(set) var snapshotCalls = 0

    init(config: CaptureConfig, startingAt now: Date = TestClock.reference) {
        self.capture = AccessibilityCapture(config: config)
        self.now = now
    }

    /// Sets what the next `snapshot()` will see, and when it sees it.
    func present(_ frame: ScreenFrame?, at now: Date) {
        self.frame = frame
        self.now = now
    }

    func snapshot() async throws -> CaptureEvent? {
        snapshotCalls += 1
        guard let frame else { return nil }
        let title = frame.windowTitle
        return await capture.admit(rawText: frame.text, app: frame.app, now: now) { title }
    }

    /// Forgets the dedupe hash, exactly as the settings UI does when capture is resumed.
    func resetDedupe() async {
        await capture.resetDedupe()
    }
}

/// The two environment reads `CaptureLoop` makes on every tick, under the test's control.
final class ScriptedEnvironment: @unchecked Sendable {

    private let lock = NSLock()
    private var front: FrontmostApp?
    private var idle: TimeInterval = 0

    func set(front: FrontmostApp?, idleSeconds: TimeInterval) {
        lock.withLock {
            self.front = front
            self.idle = idleSeconds
        }
    }

    var frontmostProvider: @Sendable () -> FrontmostApp? {
        { self.lock.withLock { self.front } }
    }

    var idleProvider: @Sendable () -> TimeInterval {
        { self.lock.withLock { self.idle } }
    }
}

/// A whole capture pipeline wired to one real store: real `CaptureLoop`, real
/// `AccessibilityCapture` gate, real SQLite, scripted screen and scripted environment.
struct CaptureHarness: Sendable {

    let store: Store
    let screen: ScriptedScreen
    let environment: ScriptedEnvironment
    let loop: CaptureLoop

    init(store: Store, config: CaptureConfig = captureConfig()) {
        let environment = ScriptedEnvironment()
        let screen = ScriptedScreen(config: config)
        self.store = store
        self.screen = screen
        self.environment = environment
        self.loop = CaptureLoop(
            source: screen,
            store: store,
            config: config,
            frontmostApp: environment.frontmostProvider,
            idleSeconds: environment.idleProvider
        )
    }

    /// One polling tick: put `app` in front showing `text`, then run the real
    /// `CaptureLoop.tick` at the injected instant.
    ///
    /// - Parameters:
    ///   - app: the frontmost application, or nil for "no frontmost app".
    ///   - text: what the accessibility walk came back with. `""` means an empty read.
    ///   - windowTitle: the focused window title the walk found.
    ///   - idleSeconds: seconds since the last HID event.
    ///   - now: the instant of this tick.
    func poll(
        _ app: FrontmostApp?,
        showing text: String = "",
        windowTitle: String? = nil,
        idleSeconds: TimeInterval = 0,
        at now: Date
    ) async {
        environment.set(front: app, idleSeconds: idleSeconds)
        let frame = app.map { ScreenFrame(app: $0, text: text, windowTitle: windowTitle) }
        await screen.present(frame, at: now)
        await loop.tick(now: now)
    }

    /// Every capture in the database, oldest first.
    func allCaptures() async throws -> [CaptureEvent] {
        try await store.captures(since: TestClock.days(-3_650), limit: 0).sorted { $0.ts < $1.ts }
    }

    /// Every session in the database, oldest first.
    func allSessions() async throws -> [Session] {
        try await store.sessions(from: TestClock.days(-3_650), to: TestClock.days(3_650))
    }
}

// MARK: - A synthetic accessibility tree

/// A node in a fake accessibility tree.
///
/// The real tree cannot be built in a test process, so this stands in for it when the thing
/// under test is the *walk* rather than the accessibility reads. `BoundedTextWalk` is generic
/// over its node type for exactly this reason.
final class FakeAXNode {
    let texts: [String]
    let secure: Bool
    /// Stands in for the element's frame intersecting the viewport.
    let onScreen: Bool
    var children: [FakeAXNode]

    init(
        texts: [String] = [],
        secure: Bool = false,
        onScreen: Bool = false,
        children: [FakeAXNode] = []
    ) {
        self.texts = texts
        self.secure = secure
        self.onScreen = onScreen
        self.children = children
    }
}

/// Runs the production walk over a synthetic tree.
func walkSynthetic(_ root: FakeAXNode, limits: TextWalkLimits) -> BoundedTextWalk.Outcome {
    BoundedTextWalk.run(
        roots: [root],
        limits: limits,
        isSecure: { $0.secure },
        texts: { $0.texts },
        children: { $0.children },
        isOnScreen: { $0.onScreen }
    )
}

/// Limits with no time pressure, for the tests that are about the other three ceilings.
func untimedLimits(maxDepth: Int, maxNodes: Int, maxCharacters: Int) -> TextWalkLimits {
    TextWalkLimits(
        maxDepth: maxDepth,
        maxNodes: maxNodes,
        maxCharacters: maxCharacters,
        isOutOfTime: { false }
    )
}

/// The production limits with no time pressure.
func standardUntimedLimits(maxCharacters: Int = CaptureLimits.maxCharacters) -> TextWalkLimits {
    TextWalkLimits.standard(maxCharacters: maxCharacters, isOutOfTime: { false })
}

/// A single unbranched chain `depth` links long below the root. The root is depth 0, so the
/// deepest node is at depth `depth`. Every node carries one unique string.
func chainTree(depth: Int, label: String = "level") -> FakeAXNode {
    var node = FakeAXNode(texts: ["\(label) \(depth)"])
    var level = depth - 1
    while level >= 0 {
        node = FakeAXNode(texts: ["\(label) \(level)"], children: [node])
        level -= 1
    }
    return node
}

/// A root with `breadth` leaf children, each carrying one unique short string.
func fanOutTree(breadth: Int) -> FakeAXNode {
    FakeAXNode(
        texts: ["root"],
        children: (0..<breadth).map { FakeAXNode(texts: ["leaf \($0)"]) }
    )
}

/// A root with `breadth` text-free leaf children, the shape of an accessibility tree that
/// is mostly structural. Used where the node ceiling is under test and the character ceiling
/// must not fire first.
func silentFanOutTree(breadth: Int) -> FakeAXNode {
    FakeAXNode(children: (0..<breadth).map { _ in FakeAXNode() })
}

/// A tree shaped like a Chromium accessibility hierarchy.
///
/// Browser chrome (the tab title, the toolbar, the status text) sits within two levels of
/// the root and is *identical between pages*. The page content itself is buried under
/// `pageDepth` nested generic groups, which is what a real web view looks like. This is the
/// shape that broke the shipped depth-12 walk: it collected the chrome, missed the page, and
/// so read the same near-empty text on every poll.
func chromiumTree(chrome: [String], page: [String], pageDepth: Int) -> FakeAXNode {
    var content = FakeAXNode(texts: page)
    for _ in 0..<pageDepth {
        content = FakeAXNode(texts: [], children: [content])
    }
    let toolbar = FakeAXNode(texts: chrome)
    return FakeAXNode(texts: ["Google Chrome"], children: [toolbar, content])
}

/// The browser chrome every page in these tests shares. Deliberately the only thing a
/// too-shallow walk can see.
let sharedBrowserChrome = [
    "New Tab",
    "Reload this page",
    "acme-corp/platform",
    "Bookmarks",
]

// MARK: - CF-10 · Capture lands correctly

@Suite("CF-10 capture lands correctly")
struct CaptureLandsTests {

    @Test("CF-10 a snapshot with real text becomes a row that round-trips unchanged")
    func roundTrip() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let capture = AccessibilityCapture(config: captureConfig())

            // Leading and trailing whitespace is what a real walk hands over.
            let raw = "\n   \(Fixtures.slackThreadText)  \n"
            let event = try #require(
                await capture.admit(
                    rawText: raw,
                    app: TestApps.slack,
                    now: TestClock.reference,
                    windowTitle: { "#eng-platform - Acme" }
                ),
                "Real on-screen text must produce a capture."
            )

            #expect(event.text == Fixtures.slackThreadText)
            #expect(event.appBundleID == "com.tinyspeck.slackmacgap")
            #expect(event.appName == "Slack")
            #expect(event.windowTitle == "#eng-platform - Acme")
            #expect(event.ts == TestClock.reference)
            #expect(event.textHash == AccessibilityCapture.textHash(Fixtures.slackThreadText))

            try await store.insert(capture: event)

            let readBack = try #require(await store.capture(id: event.id))
            #expect(
                readBack == event,
                """
                The capture changed on its way through SQLite.
                stored: \(event)
                read:   \(readBack)
                """
            )
            #expect(readBack.ts.timeIntervalSince1970 == TestClock.reference.timeIntervalSince1970)

            // And it is reachable the way the rest of the product reads captures.
            let recent = try await store.captures(since: TestClock.days(-1), limit: 100)
            #expect(recent.map(\.id) == [event.id])
        }
    }

    @Test("CF-10 the loop writes exactly what the source produced, and opens a session for it")
    func loopWritesThrough() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())

            await harness.poll(
                TestApps.mail,
                showing: Fixtures.emailText,
                windowTitle: "Q2 platform review agenda",
                at: TestClock.reference
            )

            let captures = try await harness.allCaptures()
            #expect(captures.count == 1)
            let row = try #require(captures.first)
            #expect(row.text == Fixtures.emailText)
            #expect(row.appBundleID == "com.apple.mail")
            #expect(row.appName == "Mail")
            #expect(row.windowTitle == "Q2 platform review agenda")
            #expect(row.ts == TestClock.reference)
            #expect(row.textHash == AccessibilityCapture.textHash(Fixtures.emailText))
            #expect(await harness.loop.capturesWritten == 1)

            let sessions = try await harness.allSessions()
            #expect(sessions.count == 1)
            #expect(sessions.first?.appBundleID == "com.apple.mail")
        }
    }

    @Test("CF-10 the hash is of the normalised text, so it survives reformatting")
    func hashIsNormalised() async throws {
        // Documented behaviour: SHA-256 of the lowercased, whitespace-collapsed text.
        #expect(
            AccessibilityCapture.textHash("Deploy   the\n\n fix") == AccessibilityCapture.textHash("deploy the fix")
        )
        #expect(
            AccessibilityCapture.textHash("deploy the fix") != AccessibilityCapture.textHash("deploy the fix!")
        )
        #expect(AccessibilityCapture.textHash("").count == 64)

        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let capture = AccessibilityCapture(config: captureConfig())
            let event = try #require(
                await capture.admit(
                    rawText: "Rate limiter   rollout\n\n\n  paused",
                    app: TestApps.slack,
                    now: TestClock.reference,
                    windowTitle: { nil }
                )
            )
            // The stored hash must be the hash of the stored text, or dedupe compares one
            // thing and the database holds another.
            #expect(event.textHash == AccessibilityCapture.textHash(event.text))
            try await store.insert(capture: event)
            let readBack = try #require(await store.capture(id: event.id))
            #expect(readBack.textHash == AccessibilityCapture.textHash(readBack.text))
        }
    }

    @Test("CF-10 text is truncated to the ceiling and the hash follows the truncated text")
    func truncationIsHashed() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let capture = AccessibilityCapture(config: captureConfig(maxTextLength: 500))
            let long = String(repeating: "commitment ", count: 400)   // 4400 characters

            let event = try #require(
                await capture.admit(
                    rawText: long,
                    app: TestApps.chrome,
                    now: TestClock.reference,
                    windowTitle: { nil }
                )
            )
            #expect(event.text.count == 500)
            #expect(
                event.textHash == AccessibilityCapture.textHash(event.text),
                """
                The hash must cover the text that was actually stored. Hashing the
                pre-truncation string would make two screens that differ only past the
                ceiling look different, and two that differ only before it look the same.
                """
            )

            try await store.insert(capture: event)
            let readBack = try #require(await store.capture(id: event.id))
            #expect(readBack.text.count == 500)
        }
    }

    @Test("CF-10 an empty read is not a capture")
    func emptyReadIsNotACapture() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())

            await harness.poll(TestApps.chrome, showing: "", at: TestClock.reference)
            await harness.poll(TestApps.chrome, showing: "   \n\t  ", at: TestClock.seconds(6))

            #expect(try await harness.allCaptures().isEmpty)
            #expect(await harness.loop.capturesWritten == 0)
            // The screen was still read: the loop did not skip the poll, the text was empty.
            #expect(await harness.screen.snapshotCalls == 2)
            // A session is still opened: the user was in Chrome, we just read nothing.
            #expect(try await harness.allSessions().count == 1)
        }
    }

    @Test("CF-10 a missing window title stays null, and non-ASCII text survives byte for byte")
    func titlesAndUnicode() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let text = "Résumé della riunione\n会議のメモ\nStatus: bloccato su ACME-418\tpriorità alta"

            // captureWindowTitles off means no title is even asked for.
            let quiet = AccessibilityCapture(config: captureConfig(windowTitles: false))
            let untitled = try #require(
                await quiet.admit(
                    rawText: text,
                    app: TestApps.mail,
                    now: TestClock.reference,
                    windowTitle: { "this must never be read" }
                )
            )
            #expect(untitled.windowTitle == nil)

            try await store.insert(capture: untitled)
            let readBack = try #require(await store.capture(id: untitled.id))
            #expect(readBack.windowTitle == nil, "A missing window title must round-trip as NULL, not \"\".")
            #expect(readBack.text == text)
            #expect(readBack.textHash == untitled.textHash)
        }
    }
}

// MARK: - CF-11 · Identical screens dedupe
//
// This is a regression guard for a bug that shipped.
//
// The accessibility walk was depth-limited to 12. That is deep enough for a native AppKit
// window and nowhere near deep enough for a Chromium or Electron one, where the page content
// sits twenty-plus levels below the root. The walk came back with the browser chrome and
// nothing else. That near-empty text was *identical on every poll*, so the dedupe gate,
// working exactly as designed, threw away roughly 98% of captures. The capture count froze
// at 30 and stayed there.
//
// So dedupe has to be guarded in both directions at once: it must collapse a genuinely
// unchanged screen (below), and it must not collapse a changed one (CF-12). Neither half is
// safe on its own, and the limits that feed it are guarded here too.

@Suite("CF-11 identical screens dedupe")
struct IdenticalScreensDedupeTests {

    @Test("CF-11 the same screen twice in a row produces exactly one row")
    func identicalScreensCollapse() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())

            await harness.poll(TestApps.slack, showing: Fixtures.slackThreadText, at: TestClock.reference)
            await harness.poll(TestApps.slack, showing: Fixtures.slackThreadText, at: TestClock.seconds(6))
            await harness.poll(TestApps.slack, showing: Fixtures.slackThreadText, at: TestClock.seconds(12))

            let captures = try await harness.allCaptures()
            #expect(
                captures.count == 1,
                """
                Three polls of an unchanged screen must leave exactly one row; got \(captures.count).
                The dedupe gate is AccessibilityCapture.admit comparing textHash against the
                previous capture's. If this fails, the same screen is being written once per
                poll and the database grows by ~10 identical rows a minute.
                """
            )
            #expect(await harness.loop.capturesWritten == 1)
            #expect(await harness.screen.snapshotCalls == 3, "All three polls must actually read the screen.")
        }
    }

    @Test("CF-11 a near-empty screen dedupes without freezing the count once real text appears")
    func nearEmptyDoesNotFreezeTheCount() async throws {
        // The shipped failure mode, end to end: poll after poll of the same near-empty read,
        // then a real one. The near-empty polls must collapse to one row, and the real text
        // must still get through.
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())
            let nearEmpty = "New Tab"

            for i in 0..<12 {
                await harness.poll(
                    TestApps.chrome,
                    showing: nearEmpty,
                    at: TestClock.seconds(Double(i) * 6)
                )
            }
            #expect(try await harness.allCaptures().count == 1)

            await harness.poll(
                TestApps.chrome,
                showing: Fixtures.codeReviewText,
                at: TestClock.seconds(72)
            )

            let captures = try await harness.allCaptures()
            #expect(
                captures.count == 2,
                """
                Twelve identical near-empty reads then one real screen must leave two rows; \
                got \(captures.count). If this is 1, the dedupe gate is comparing against \
                something other than the immediately previous capture and the count is frozen: \
                the exact bug that stuck the capture count at 30.
                """
            )
            #expect(captures.last?.text == Fixtures.codeReviewText)
        }
    }

    @Test("CF-11 dedupe compares against the previous capture only, never against all history")
    func dedupeIsAgainstThePreviousCaptureOnly() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())
            let a = "Standup notes\n- Rate limiter shipped behind a flag."
            let b = "Standup notes\n- Migration script in review."

            await harness.poll(TestApps.mail, showing: a, at: TestClock.reference)
            await harness.poll(TestApps.mail, showing: a, at: TestClock.seconds(6))
            await harness.poll(TestApps.mail, showing: b, at: TestClock.seconds(12))
            await harness.poll(TestApps.mail, showing: a, at: TestClock.seconds(18))

            let captures = try await harness.allCaptures()
            #expect(
                captures.map(\.text) == [a, b, a],
                """
                A, A, B, A must leave three rows in that order; got \(captures.count).
                Returning to a screen you saw earlier in the day is a new observation with a
                new timestamp, and the timeline needs it. Do not "fix" dedupe by remembering
                every hash ever seen: that is the frozen-count bug with a longer memory.
                """
            )
        }
    }

    @Test("CF-11 resetDedupe re-admits the screen that is still on display")
    func resetDedupeReadmits() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())

            await harness.poll(TestApps.slack, showing: Fixtures.slackThreadText, at: TestClock.reference)
            await harness.poll(TestApps.slack, showing: Fixtures.slackThreadText, at: TestClock.seconds(6))
            #expect(try await harness.allCaptures().count == 1)

            // What Settings does on resume: the screen has not changed, but the timeline has
            // a hole in it and the next poll should fill it.
            await harness.screen.resetDedupe()
            await harness.poll(TestApps.slack, showing: Fixtures.slackThreadText, at: TestClock.seconds(12))

            let captures = try await harness.allCaptures()
            #expect(captures.count == 2)
            #expect(captures.map(\.ts) == [TestClock.reference, TestClock.seconds(12)])
        }
    }

    @Test("CF-11 the Store never dedupes: identical text at different times is two rows")
    func storeItselfDoesNotDedupe() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let morning = Fixtures.standupNotes(at: TestClock.reference)
            let afternoon = Fixtures.standupNotes(at: TestClock.hours(5))

            #expect(morning.textHash == afternoon.textHash)
            #expect(morning.id != afternoon.id)

            try await seed(store: store, captures: [morning, afternoon])

            let stats = try await store.stats()
            #expect(
                stats.captureCount == 2,
                """
                Dedupe belongs to the capture source, which compares one poll to the next.
                The Store must keep both rows: a UNIQUE(text_hash) constraint or a
                hash-based INSERT OR IGNORE here would silently drop every re-visit to the
                same screen for the rest of the database's life.
                """
            )
        }
    }
}

// MARK: - CF-11 · The limits that feed dedupe
//
// The dedupe gate is only as good as the text handed to it. The bug was not in the gate, it
// was in the walk that starved it. These tests guard the walk.
//
// **Known gap, stated plainly:** these drive `BoundedTextWalk` (the real traversal and the
// real ceilings) over a synthetic tree, not over `AXUIElement`s. The accessibility-specific
// closures `AXScraper` supplies (`AXSubrole` reads, `AXValue`/`AXTitle`/`AXDescription`
// reads, `AXChildren` reads) are *not* covered here and cannot be: they require a granted
// Accessibility permission and a live window server, neither of which exists in a test
// process. What is covered is every decision the walk makes about when to stop, which is
// where the shipped bug lived.

@Suite("CF-11 the walk limits that feed dedupe")
struct CaptureLimitsTests {

    @Test("CF-11 the limits are deep enough for a Chromium accessibility tree")
    func limitsArePlausible() {
        #expect(
            CaptureLimits.maxDepth >= 30,
            """
            maxDepth is \(CaptureLimits.maxDepth). A Chromium or Electron accessibility tree
            puts page content twenty-plus levels below the window. At depth 12 the walk
            collected browser chrome and nothing else, that chrome was identical on every
            poll, dedupe discarded ~98% of captures and the count froze at 30. Anything below
            30 reopens that bug.
            """
        )
        #expect(
            CaptureLimits.maxNodes >= 2_000,
            "maxNodes is \(CaptureLimits.maxNodes); a single web page routinely exposes thousands of elements."
        )
        #expect(CaptureLimits.maxCharacters >= 8_000)
        #expect(CaptureLimits.deadlineSeconds > 0)
        #expect(CaptureLimits.watchdogSeconds > CaptureLimits.deadlineSeconds)

        // And the walk really is built from those constants, not from its own copies.
        let limits = standardUntimedLimits(maxCharacters: 1_234)
        #expect(limits.maxDepth == CaptureLimits.maxDepth)
        #expect(limits.maxNodes == CaptureLimits.maxNodes)
        #expect(limits.maxCharacters == 1_234)
    }

    @Test("CF-11 the depth limit stops the walk, and the production depth reaches page content")
    func depthLimitIsEnforced() {
        let deep = chainTree(depth: 3 * CaptureLimits.maxDepth)

        let outcome = walkSynthetic(deep, limits: standardUntimedLimits())
        #expect(outcome.deepestVisited == CaptureLimits.maxDepth)
        #expect(outcome.nodesVisited == CaptureLimits.maxDepth + 1)
        #expect(outcome.pieces.count == CaptureLimits.maxDepth + 1)
        #expect(outcome.hitLimit)

        // A shallower configuration stops earlier, which is what proves the limit is read
        // from `limits` rather than hardcoded somewhere in the traversal.
        let shallow = walkSynthetic(deep, limits: untimedLimits(maxDepth: 5, maxNodes: 10_000, maxCharacters: 20_000))
        #expect(shallow.deepestVisited == 5)
        #expect(shallow.nodesVisited == 6)

        // A tree that fits is walked whole, with no limit flagged.
        let shallowEnough = chainTree(depth: 4)
        let complete = walkSynthetic(shallowEnough, limits: standardUntimedLimits())
        #expect(complete.pieces.count == 5)
        #expect(!complete.hitLimit)
    }

    @Test("CF-11 the node limit stops the walk")
    func nodeLimitIsEnforced() {
        let wide = fanOutTree(breadth: 5_000)

        let capped = walkSynthetic(wide, limits: untimedLimits(maxDepth: 40, maxNodes: 50, maxCharacters: 20_000))
        #expect(capped.nodesVisited == 50)
        #expect(capped.pieces.count == 50)
        #expect(capped.hitLimit)

        // Structural elements only, so the character ceiling cannot fire first and the node
        // ceiling is the only thing being measured.
        let structural = walkSynthetic(silentFanOutTree(breadth: 5_000), limits: standardUntimedLimits())
        #expect(
            structural.nodesVisited == 5_001,
            "5 001 elements is under the \(CaptureLimits.maxNodes) node ceiling, so all of them must be visited."
        )
        #expect(!structural.hitLimit)
    }

    @Test("CF-11 the character limit stops the walk at exactly the ceiling")
    func characterLimitIsEnforced() {
        // 400 leaves of 100 characters each: 40 000 characters available.
        let root = FakeAXNode(
            texts: [],
            children: (0..<400).map { i in
                FakeAXNode(texts: [String(format: "%04d", i) + String(repeating: "x", count: 96)])
            }
        )

        for ceiling in [1_000, 1_050, 20_000] {
            let outcome = walkSynthetic(
                root,
                limits: untimedLimits(maxDepth: 40, maxNodes: 100_000, maxCharacters: ceiling)
            )
            // Measured on the joined text, which is what a capture stores, and not on the
            // sum of the piece lengths, which is what the budget used to count.
            //
            // Those differ by one newline per piece, and the difference was not academic: at
            // ceiling 20 000 the pieces summed to the ceiling exactly while the text they
            // joined into was 198 characters over it, and the overshoot was then cut off the
            // end downstream. A capture whose text is silently truncated after the walk has
            // already decided it was within budget is how the on-screen slice came to hold
            // lines the text itself no longer had.
            #expect(
                outcome.text.count == ceiling,
                "Ceiling \(ceiling) produced \(outcome.text.count) characters of text."
            )
            #expect(outcome.hitLimit)
        }
    }

    @Test("CF-11 the time limit stops the walk without the walk reading a clock")
    func timeLimitIsEnforced() {
        let wide = fanOutTree(breadth: 1_000)
        var polls = 0
        let limits = TextWalkLimits(
            maxDepth: 40,
            maxNodes: 100_000,
            maxCharacters: 20_000,
            isOutOfTime: {
                polls += 1
                return polls > 25
            }
        )

        let outcome = walkSynthetic(wide, limits: limits)
        #expect(outcome.nodesVisited == 25)
        #expect(outcome.hitLimit)
    }

    @Test("CF-11 the shipped bug, reproduced: a depth-12 walk reads two pages as one screen")
    func shallowWalkReproducesTheFrozenCount() async throws {
        // Two different pages behind identical browser chrome, the everyday case that broke.
        let pageOne = chromiumTree(
            chrome: sharedBrowserChrome,
            page: ["priya-r: I'll move the budget into Redis and push an update tomorrow."],
            pageDepth: 24
        )
        let pageTwo = chromiumTree(
            chrome: sharedBrowserChrome,
            page: ["marco-b: Approving once the shared budget lands."],
            pageDepth: 24
        )

        func read(_ tree: FakeAXNode, with limits: TextWalkLimits) -> String {
            walkSynthetic(tree, limits: limits).pieces.joined(separator: "\n")
        }

        // The old limits: the walk never reaches the page.
        let old = untimedLimits(maxDepth: 12, maxNodes: 2_000, maxCharacters: 20_000)
        let shallowOne = read(pageOne, with: old)
        let shallowTwo = read(pageTwo, with: old)
        #expect(!shallowOne.contains("Redis"), "Depth 12 must not reach page content in this fixture.")
        #expect(
            AccessibilityCapture.textHash(shallowOne) == AccessibilityCapture.textHash(shallowTwo),
            "The premise of this test is that a shallow walk makes two different pages hash alike."
        )

        // The production limits: the page is read, and the two screens are different.
        let deepOne = read(pageOne, with: standardUntimedLimits())
        let deepTwo = read(pageTwo, with: standardUntimedLimits())
        #expect(deepOne.contains("Redis"))
        #expect(deepTwo.contains("shared budget lands"))
        #expect(AccessibilityCapture.textHash(deepOne) != AccessibilityCapture.textHash(deepTwo))

        // Now the consequence, through the real dedupe gate and a real database.
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            let shallowHarness = CaptureHarness(store: store)
            await shallowHarness.poll(TestApps.chrome, showing: shallowOne, at: TestClock.reference)
            await shallowHarness.poll(TestApps.chrome, showing: shallowTwo, at: TestClock.seconds(6))
            #expect(
                try await shallowHarness.allCaptures().count == 1,
                """
                This is the bug, and it is expected to reproduce here: a too-shallow walk
                makes two different pages indistinguishable, so the second is deduped away.
                Nothing is wrong with dedupe: it is being starved.
                """
            )
        }

        try await TestWorkspace.with { ws in
            let deepHarness = CaptureHarness(store: try await ws.store())
            await deepHarness.poll(TestApps.chrome, showing: deepOne, at: TestClock.reference)
            await deepHarness.poll(TestApps.chrome, showing: deepTwo, at: TestClock.seconds(6))

            let captures = try await deepHarness.allCaptures()
            #expect(
                captures.count == 2,
                """
                With CaptureLimits.maxDepth = \(CaptureLimits.maxDepth) the walk reaches page
                content, the two screens differ, and both are captured. If this drops to 1,
                the depth limit has been lowered and the capture count is frozen again.
                """
            )
        }
    }
}

@Suite("The on-screen slice of a capture")
struct VisibleTextTests {

    /// A feed as the tree returns one: mounted posts above and below the viewport, one of
    /// them actually in front of the user. `post` is long enough to be worth locating.
    private func post(_ body: String, onScreen: Bool) -> FakeAXNode {
        FakeAXNode(
            texts: [body + String(repeating: " and more of the same", count: 4)],
            onScreen: onScreen
        )
    }

    @Test("only substantial blocks that were in frame are recorded as visible")
    func visibleIsTheSubstantialOnScreenText() {
        let tree = FakeAXNode(children: [
            // Navigation: in frame, but nothing here is long enough to be worth a round trip.
            FakeAXNode(texts: ["Home"], onScreen: true),
            FakeAXNode(texts: ["My Network"], onScreen: true),
            post("a post scrolled past above", onScreen: false),
            post("the post being read right now", onScreen: true),
            post("a post below the fold", onScreen: false),
        ])

        let outcome = walkSynthetic(tree, limits: standardUntimedLimits())

        #expect(outcome.text.contains("scrolled past above"), "text keeps the whole tree")
        #expect(outcome.text.contains("below the fold"), "text keeps the whole tree")

        #expect(outcome.visibleText.contains("the post being read right now"))
        #expect(
            !outcome.visibleText.contains("scrolled past above"),
            "a mounted but off-screen post is not what was on screen"
        )
        #expect(!outcome.visibleText.contains("below the fold"))
        #expect(
            !outcome.visibleText.contains("Home"),
            "short labels are below the length gate that keeps the geometry affordable"
        )
    }

    @Test("the visible slice is only ever a subset of the text")
    func visibleIsAlwaysASubsetOfText() {
        let tree = FakeAXNode(children: [
            post("first", onScreen: true),
            post("second", onScreen: false),
            post("third", onScreen: true),
        ])
        let outcome = walkSynthetic(tree, limits: standardUntimedLimits())

        for piece in outcome.visiblePieces {
            #expect(
                outcome.pieces.contains(piece),
                "the visible slice invented text that is not in the capture: \(piece)"
            )
        }
    }

    @Test("a walk with no geometry records nothing visible rather than guessing")
    func noGeometryRecordsNothing() {
        let tree = FakeAXNode(children: [
            post("something long enough to qualify on length alone", onScreen: false),
        ])
        let outcome = walkSynthetic(tree, limits: standardUntimedLimits())

        #expect(!outcome.text.isEmpty)
        #expect(outcome.visiblePieces.isEmpty, "no frame means no claim about the screen")
    }

    @Test("the joined text lands on the character ceiling, not past it")
    func joinedTextRespectsTheCeiling() {
        // Many pieces, so the newlines between them are worth more than a rounding error.
        let many = FakeAXNode(children: (0..<400).map { index in
            FakeAXNode(texts: ["piece \(index) " + String(repeating: "x", count: 60)])
        })
        let limits = untimedLimits(maxDepth: 40, maxNodes: 12_000, maxCharacters: 5_000)
        let outcome = walkSynthetic(many, limits: limits)

        #expect(
            outcome.text.count <= 5_000,
            """
            The walk budgets by summing piece lengths, but `text` is those pieces joined with \
            a newline. Counting the separators is what stops the join landing past the ceiling \
            and being truncated downstream, which is what let the visible slice keep text the \
            full capture had lost. Got \(outcome.text.count).
            """
        )
    }

    @Test("text the truncation cut is not left behind in the visible slice")
    func truncationNeverStrandsVisibleText() async throws {
        // The real shape, made deterministic: a tree over the ceiling, and a viewport that
        // includes the part about to be cut. Observed on a live capture: text exactly 20,000
        // characters, visible_text 16,306, and two of its 63 lines absent from the text.
        let limit = 2_000
        let capture = AccessibilityCapture(
            config: CaptureConfig(captureWindowTitles: false, maxTextLength: limit)
        )

        let kept = String(repeating: "a line that is safely inside the ceiling. ", count: 80)
        let cut = "the tail that truncation removes from the text but not from the viewport"
        let whole = kept + "\n" + cut
        #expect(whole.count > limit, "the fixture must exceed the ceiling to truncate at all")

        let event = try #require(
            await capture.admit(
                rawText: whole,
                rawVisibleText: cut,
                app: TestApps.chrome,
                now: TestClock.reference,
                windowTitle: { nil }
            )
        )

        #expect(!event.text.contains(cut), "the fixture did not actually truncate the tail away")
        #expect(
            event.visibleText?.contains(cut) != true,
            """
            The visible slice kept a line the truncation cut from the text. Only `text` is \
            indexed, so this is provenance pointing at words the capture does not contain: \
            \(event.visibleText ?? "nil")
            """
        )
    }

    @Test("a capture truncated at the ceiling keeps the visible slice a subset")
    func visibleStaysASubsetAtTheCeiling() async throws {
        // Reproduces a real capture: 20,000 characters of tree, most of it on screen, so the
        // truncation and the viewport overlap. Before the separators were counted, the tail
        // survived in visible_text while being cut from text.
        let onScreen = (0..<400).map { index in
            post("visible block \(index) with enough words in it to clear the length gate", onScreen: true)
        }
        let tree = FakeAXNode(children: onScreen)
        let outcome = walkSynthetic(tree, limits: standardUntimedLimits())
        #expect(
            outcome.hitLimit,
            "this fixture is only meaningful if it reaches the ceiling and forces a truncation"
        )

        let capture = AccessibilityCapture(config: CaptureConfig(captureWindowTitles: false))
        let event = try #require(
            await capture.admit(
                rawText: outcome.text,
                rawVisibleText: outcome.visibleText,
                app: TestApps.chrome,
                now: TestClock.reference,
                windowTitle: { nil }
            )
        )

        let visible = try #require(event.visibleText)
        for line in visible.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            #expect(
                event.text.contains(line),
                """
                The visible slice quotes text the capture does not contain. Only `text` is \
                indexed for search, so this is a citation to something unfindable: \(line.prefix(80))
                """
            )
        }
    }

    @Test("the geometry budget bounds the probes and says when it ran out")
    func geometryBudgetIsBoundedAndReported() {
        // Twice the budget, every block long enough to qualify and every one in frame: a long
        // document, where the length gate alone would let the viewport question cost hundreds
        // of blocking accessibility calls inside a 400ms deadline.
        let crowd = FakeAXNode(children: (0..<(BoundedTextWalk.maxGeometryProbes * 2)).map { index in
            post("block number \(index) of a very long document", onScreen: true)
        })
        let outcome = walkSynthetic(crowd, limits: standardUntimedLimits())

        #expect(
            outcome.visiblePieces.count <= BoundedTextWalk.maxGeometryProbes,
            "the walk made more geometry probes than its budget allows"
        )
        #expect(outcome.geometryExhausted, "spending the budget must be reported, not silent")
        #expect(!outcome.visiblePieces.isEmpty, "the blocks located before the cap are still valid")

        // Under the budget nothing is dropped and nothing is claimed to be.
        let few = FakeAXNode(children: (0..<5).map { post("block \($0)", onScreen: true) })
        let small = walkSynthetic(few, limits: standardUntimedLimits())
        #expect(small.visiblePieces.count == 5)
        #expect(!small.geometryExhausted)
    }

    @Test("a code on screen is redacted in the visible slice too")
    func secretsAreRedactedInTheVisibleSlice() async throws {
        try await TestWorkspace.with { ws in
            let capture = AccessibilityCapture(config: CaptureConfig(captureWindowTitles: false))

            // Long enough that the screen is not judged to BE the code, so it is kept and
            // redacted rather than dropped (the CF-101 path) and the same digits sit in
            // the part that was on screen.
            let onScreen = """
                Your verification code is 448216 and it expires in ten minutes. Do not share \
                this code with anyone, including somebody claiming to be from support.
                """
            let whole = onScreen + "\n" + String(repeating: "Other work on the same screen. ", count: 20)

            let event = try #require(
                await capture.admit(
                    rawText: whole,
                    rawVisibleText: onScreen,
                    app: TestApps.chrome,
                    now: TestClock.reference,
                    windowTitle: { nil }
                )
            )

            #expect(!event.text.contains("448216"), "the code must not survive in the text")
            let visible = try #require(event.visibleText)
            #expect(
                !visible.contains("448216"),
                "the code survived in the visible slice, which puts back what redaction removed"
            )
            #expect(visible.contains("[redacted]"))
            _ = ws
        }
    }

    @Test("visible_text round-trips through the store, and nil stays nil")
    func visibleTextRoundTrips() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let known = Fixtures.capture(
                text: "the whole tree\nthe part in frame",
                app: "Google Chrome",
                bundleID: "com.google.Chrome",
                windowTitle: "Feed | LinkedIn",
                at: TestClock.reference,
                name: "known",
                visibleText: "the part in frame"
            )
            let unknown = Fixtures.capture(
                text: "captured before the column existed",
                app: "Google Chrome",
                bundleID: "com.google.Chrome",
                windowTitle: nil,
                at: TestClock.seconds(30),
                name: "unknown"
            )
            try await seed(store: store, captures: [known, unknown])

            let read = try await store.captures(since: TestClock.reference.addingTimeInterval(-60), limit: 10)
            let readKnown = try #require(read.first { $0.id == known.id })
            let readUnknown = try #require(read.first { $0.id == unknown.id })

            #expect(readKnown.visibleText == "the part in frame")
            #expect(
                readUnknown.visibleText == nil,
                "nil means the geometry was never read, and must not read back as empty"
            )
        }
    }
}

// MARK: - CF-12 · Changed screens do not dedupe

@Suite("CF-12 changed screens do not dedupe")
struct ChangedScreensTests {

    @Test("CF-12 text that differs by one word produces two rows")
    func oneWordDifference() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())
            let before = Fixtures.slackThreadText
            let after = before.replacingOccurrences(of: "by Friday", with: "by Thursday")
            #expect(before != after)

            await harness.poll(TestApps.slack, showing: before, at: TestClock.reference)
            await harness.poll(TestApps.slack, showing: after, at: TestClock.seconds(6))

            let captures = try await harness.allCaptures()
            #expect(
                captures.count == 2,
                """
                One changed word must be a new capture; got \(captures.count) row(s). A screen
                whose only change is the sentence you care about is the whole point of the
                product.
                """
            )
            #expect(captures.map(\.text) == [before, after])
            #expect(captures[0].textHash != captures[1].textHash)
            #expect(await harness.loop.capturesWritten == 2)
        }
    }

    @Test("CF-12 a single character is enough of a difference")
    func oneCharacterDifference() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())

            await harness.poll(TestApps.mail, showing: "Headcount rollup: 11 open reqs", at: TestClock.reference)
            await harness.poll(TestApps.mail, showing: "Headcount rollup: 12 open reqs", at: TestClock.seconds(6))

            #expect(try await harness.allCaptures().count == 2)
        }
    }

    @Test("CF-12 a run of changing screens is captured once per poll, not once per run")
    func everyChangedPollLands() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())
            let polls = 40

            for i in 0..<polls {
                await harness.poll(
                    TestApps.chrome,
                    showing: "acme-corp/platform #482\nreviewing diff, line \(i) of 812",
                    at: TestClock.seconds(Double(i) * 6)
                )
            }

            let captures = try await harness.allCaptures()
            #expect(
                captures.count == polls,
                """
                \(polls) genuinely different screens produced \(captures.count) rows. This is
                the measurement that caught the original bug: the count stopped moving while
                the screen kept changing.
                """
            )
            #expect(Set(captures.map(\.textHash)).count == polls, "Every changed screen must hash differently.")
            #expect(captures.map(\.ts) == (0..<polls).map { TestClock.seconds(Double($0) * 6) })
        }
    }

    @Test("CF-12 reformatting alone is the same screen, by design")
    func normalisationIsDeliberate() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())
            let text = "Pricing page rollout paused, tracked in ACME-431."

            await harness.poll(TestApps.mail, showing: text, at: TestClock.reference)
            // Same words, different whitespace and different case. `textHash` lowercases and
            // collapses whitespace on purpose, so a re-layout or a hover highlight is not a
            // new observation.
            await harness.poll(
                TestApps.mail,
                showing: "Pricing   page rollout\n paused,\ttracked in ACME-431.",
                at: TestClock.seconds(6)
            )
            await harness.poll(TestApps.mail, showing: text.uppercased(), at: TestClock.seconds(12))
            // A real edit still gets through.
            await harness.poll(
                TestApps.mail,
                showing: "Pricing page rollout resumed, tracked in ACME-431.",
                at: TestClock.seconds(18)
            )

            let captures = try await harness.allCaptures()
            #expect(captures.count == 2)
            #expect(captures.first?.text == text)
            #expect(captures.last?.text.contains("resumed") == true)
        }
    }

    @Test("CF-12 the same screen in a different app is still the same screen")
    func dedupeIsGlobalAcrossApps() async throws {
        // Worth pinning because it is surprising: there is one dedupe hash per capture
        // source, not one per app. Switching apps does not re-admit identical text; changing
        // the text does.
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())
            let shared = "Q2 platform review agenda"

            await harness.poll(TestApps.mail, showing: shared, at: TestClock.reference)
            await harness.poll(TestApps.slack, showing: shared, at: TestClock.seconds(6))
            await harness.poll(TestApps.slack, showing: shared + " (updated)", at: TestClock.seconds(12))

            let captures = try await harness.allCaptures()
            #expect(captures.count == 2)
            #expect(captures.map(\.appBundleID) == ["com.apple.mail", "com.tinyspeck.slackmacgap"])
        }
    }
}

// MARK: - CF-13 · Sessions rotate on app switch

@Suite("CF-13 sessions rotate on app switch")
struct SessionRotationTests {

    @Test("CF-13 A -> B -> A gives three non-overlapping sessions with no lost time")
    func rotationAcrossApps() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())
            let t0 = TestClock.reference

            // Six second polls. Slack for three, Chrome for two, Slack again for two.
            let script: [(app: FrontmostApp, offset: Double)] = [
                (TestApps.slack, 0),
                (TestApps.slack, 6),
                (TestApps.slack, 12),
                (TestApps.chrome, 18),
                (TestApps.chrome, 24),
                (TestApps.slack, 30),
                (TestApps.slack, 36),
            ]
            for (index, step) in script.enumerated() {
                await harness.poll(
                    step.app,
                    showing: "\(step.app.name) screen \(index): distinct on-screen text",
                    at: TestClock.seconds(step.offset)
                )
            }
            await harness.loop.stop(now: TestClock.seconds(42))

            let sessions = try await harness.allSessions()
            #expect(sessions.count == 3, "Expected Slack, Chrome, Slack; got \(sessions.map(\.appName)).")
            let bundles = sessions.map(\.appBundleID)
            #expect(bundles == [
                TestApps.slack.bundleID,
                TestApps.chrome.bundleID,
                TestApps.slack.bundleID,
            ])

            // Durations.
            #expect(sessions[0].duration == 18)
            #expect(sessions[1].duration == 12)
            #expect(sessions[2].duration == 12)

            // Three distinct rows: returning to Slack must not reopen the first session, or
            // the timeline would show one 42 second Slack block swallowing the Chrome one.
            #expect(Set(sessions.map(\.id)).count == 3)

            // Non-overlapping and gapless: each session starts exactly where the last ended.
            for i in 1..<sessions.count {
                #expect(
                    sessions[i].startedAt == sessions[i - 1].endedAt,
                    """
                    Session \(i) starts at \(TestClock.iso(sessions[i].startedAt)) but the
                    previous one ends at \(TestClock.iso(sessions[i - 1].endedAt)). Overlap
                    double-counts the day; a gap loses time that was actually observed.
                    """
                )
            }
            #expect(sessions[0].startedAt == t0)
            #expect(sessions[2].endedAt == TestClock.seconds(42))
            let claimed = sessions.reduce(0.0) { $0 + $1.duration }
            #expect(claimed == 42, "The observed window is 42s; the sessions claim \(claimed)s.")
            #expect(sessions.allSatisfy { !$0.idle })

            // Every capture falls inside the session for the app it came from.
            let captures = try await harness.allCaptures()
            #expect(captures.count == script.count)
            for capture in captures {
                let owning = sessions.first {
                    $0.appBundleID == capture.appBundleID
                        && $0.startedAt <= capture.ts
                        && capture.ts <= $0.endedAt
                }
                #expect(owning != nil, "Capture at \(TestClock.iso(capture.ts)) from \(capture.appName) has no session.")
            }
        }
    }

    @Test("CF-13 a gap longer than the tolerance splits the session and claims no unobserved time")
    func gapSplitsTheSession() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())

            // Two polls, then ten minutes of nothing (a sleep, or capture being paused).
            await harness.poll(TestApps.slack, showing: "before the gap", at: TestClock.reference)
            await harness.poll(TestApps.slack, showing: "still before the gap", at: TestClock.seconds(6))
            await harness.poll(TestApps.slack, showing: "after the gap", at: TestClock.seconds(606))
            await harness.poll(TestApps.slack, showing: "still after the gap", at: TestClock.seconds(612))
            await harness.loop.stop(now: TestClock.seconds(618))

            let sessions = try await harness.allSessions()
            #expect(sessions.count == 2, "The same app either side of a ten minute hole is two sessions.")
            #expect(sessions[0].startedAt == TestClock.reference)
            #expect(sessions[0].endedAt == TestClock.seconds(6))
            #expect(sessions[1].startedAt == TestClock.seconds(606))
            #expect(sessions[1].endedAt == TestClock.seconds(618))

            let claimed = sessions.reduce(0.0) { $0 + $1.duration }
            #expect(
                claimed == 18,
                """
                The sessions claim \(claimed)s of a 618s wall-clock span. Only 18s was
                observed; the 600s hole was not, and reporting it as time spent in Slack
                would be a lie told to the user every time the machine sleeps.
                """
            )
            #expect(sessions[1].startedAt > sessions[0].endedAt)
        }
    }

    /// The gap tolerance is a named constant, and it has to stay one.
    ///
    /// It used to be `max(intervalSeconds * 3, 30)`, which quietly made the interval stepper in
    /// Settings a session-rotation control: the only thing that knob still reached. Pinning both
    /// sides of the boundary to observable session rows is what stops it being derived from some
    /// other setting again without anybody noticing.
    @Test("CF-13 the session gap tolerance is the named constant, on both sides of it")
    func gapToleranceIsTheNamedConstant() async throws {
        let gap = CaptureConfig.sessionGapSeconds
        #expect(gap == 30, "The tolerance moved; the copy and the tests below both assume 30s.")

        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())

            // A hole one second inside the tolerance: still one session.
            await harness.poll(TestApps.slack, showing: "before", at: TestClock.reference)
            await harness.poll(TestApps.slack, showing: "just inside", at: TestClock.seconds(gap - 1))
            #expect(try await harness.allSessions().count == 1,
                    "A \(gap - 1)s hole is inside the \(gap)s tolerance and must not split.")

            // One second outside it: two.
            await harness.poll(TestApps.slack, showing: "just outside",
                               at: TestClock.seconds((gap - 1) + gap + 1))
            #expect(try await harness.allSessions().count == 2,
                    "A \(gap + 1)s hole is outside the \(gap)s tolerance and must split.")
        }
    }

    @Test("CF-13 going idle in the same app rotates into an idle session, and back out again")
    func idleRotatesWithoutLosingTime() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())

            await harness.poll(TestApps.slack, showing: "active one", idleSeconds: 0, at: TestClock.reference)
            await harness.poll(TestApps.slack, showing: "active two", idleSeconds: 5, at: TestClock.seconds(6))
            await harness.poll(TestApps.slack, showing: "unread", idleSeconds: 300, at: TestClock.seconds(12))
            await harness.poll(TestApps.slack, showing: "unread", idleSeconds: 480, at: TestClock.seconds(18))
            await harness.poll(TestApps.slack, showing: "active three", idleSeconds: 1, at: TestClock.seconds(24))
            await harness.loop.stop(now: TestClock.seconds(30))

            let sessions = try await harness.allSessions()
            #expect(sessions.count == 3)
            #expect(sessions.map(\.idle) == [false, true, false])
            #expect(sessions.map(\.duration) == [12, 12, 6])
            for i in 1..<sessions.count {
                #expect(sessions[i].startedAt == sessions[i - 1].endedAt)
            }
            #expect(sessions.allSatisfy { $0.appBundleID == TestApps.slack.bundleID })

            // No text is read while idle: the loop returns before it asks for a snapshot.
            #expect(await harness.screen.snapshotCalls == 3)
            let captures = try await harness.allCaptures()
            #expect(captures.map(\.text) == ["active one", "active two", "active three"])
        }
    }

    @Test("CF-13 an excluded app gets no session at all, not even an empty one")
    func excludedAppsGetNoSession() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(
                store: try await ws.store(),
                config: captureConfig(excluding: [TestApps.onePassword.bundleID])
            )

            await harness.poll(TestApps.slack, showing: "before", at: TestClock.reference)
            await harness.poll(TestApps.onePassword, showing: "Vault - personal - master password", at: TestClock.seconds(6))
            await harness.poll(TestApps.onePassword, showing: "Vault - work", at: TestClock.seconds(12))
            await harness.poll(TestApps.slack, showing: "after", at: TestClock.seconds(18))
            await harness.loop.stop(now: TestClock.seconds(24))

            let sessions = try await harness.allSessions()
            #expect(
                sessions.allSatisfy { $0.appBundleID != TestApps.onePassword.bundleID },
                """
                A session row for an excluded app leaks the fact that the user was in their
                password manager, and for how long. Exclusion means absent, not empty.
                """
            )
            #expect(sessions.count == 2)
            #expect(sessions[0].startedAt == TestClock.reference)
            #expect(sessions[0].endedAt == TestClock.seconds(6))
            #expect(sessions[1].startedAt == TestClock.seconds(18))
            #expect(sessions[1].endedAt == TestClock.seconds(24))

            // And no text either. The excluded polls never reach the capture source.
            #expect(await harness.screen.snapshotCalls == 2)
            let captures = try await harness.allCaptures()
            #expect(captures.map(\.text) == ["before", "after"])
        }
    }

    @Test("CF-13 no frontmost app closes the open session and opens nothing")
    func noFrontmostAppClosesTheSession() async throws {
        try await TestWorkspace.with { ws in
            let harness = CaptureHarness(store: try await ws.store())

            await harness.poll(TestApps.chrome, showing: "reviewing #482", at: TestClock.reference)
            await harness.poll(TestApps.chrome, showing: "reviewing #483", at: TestClock.seconds(6))
            // Screen locked, or the last window closed: NSWorkspace has no frontmost app.
            await harness.poll(nil, at: TestClock.seconds(12))
            await harness.poll(nil, at: TestClock.seconds(18))
            await harness.poll(TestApps.chrome, showing: "back to #483", at: TestClock.seconds(24))
            await harness.loop.stop(now: TestClock.seconds(30))

            let sessions = try await harness.allSessions()
            #expect(sessions.count == 2)
            #expect(sessions[0].endedAt == TestClock.seconds(12))
            #expect(sessions[1].startedAt == TestClock.seconds(24))
            #expect(sessions[1].startedAt > sessions[0].endedAt, "The locked window is not time spent in Chrome.")
            #expect(await harness.screen.snapshotCalls == 3)
        }
    }
}

// CF-101: a one-time code is removed; the screen it appeared on is not.
//
// The rule this protects is unchanged and absolute: a code never reaches the database.
// What changed is the blast radius. Enforcing it by discarding the whole capture was
// invisible while the walk returned almost nothing, and catastrophic the moment it
// returned real screens: on a developer's machine "code" sits within twenty characters
// of a four-digit number permanently, so 20,366-character captures of actual work were
// being thrown away entire.

@Suite("CF-101 a code is redacted, the screen survives")
struct SecretRedactionTests {

    /// A screen that is nothing but a code has nothing else worth keeping.
    @Test("CF-101 a screen that is only a verification code is still dropped")
    func codeScreensAreDropped() {
        for screen in [
            "Your verification code is 481920. Do not share this code with anyone.",
            "123456 is your Google verification code.",
            "Codice di verifica: 55213",
        ] {
            #expect(AccessibilityCapture.withoutSecrets(screen) == nil, "kept a code screen: \(screen)")
        }
    }

    /// A working screen that merely mentions a code keeps everything except the digits.
    @Test("CF-101 a working screen keeps its text and loses its digits")
    func workingScreensAreRedactedNotDropped() throws {
        // Long enough to be a screen rather than a banner, and shaped exactly like the
        // captures this was found on: prose about code, with numbers all through it.
        let working = """
            capture walk for pid 40558: 1485 nodes, depth 36, 20366 chars
            The code path in AccessibilityCapture drops the whole capture when it sees a
            code near a number, which on this machine is always. Session 4821 measured
            9264 characters before the change and 1135 after.
            """ + String(repeating: " and more of the same working text.", count: 12)

        let kept = try #require(
            AccessibilityCapture.withoutSecrets(working),
            "a whole screen of work was discarded because it discussed code"
        )
        #expect(kept.contains("AccessibilityCapture"), "the work text must survive")
        #expect(kept.contains("[redacted]"), "the digits must be removed")
        for digits in ["1485", "20366", "4821", "9264", "1135"] {
            #expect(!kept.contains(digits), "a code-shaped number survived: \(digits)")
        }
    }

    /// The overwhelming majority of screens never mention a code and must be untouched.
    @Test("CF-101 an ordinary screen is passed through unchanged")
    func ordinaryScreensAreUntouched() {
        let ordinary = "Invoice 4821 for Acme, due Friday. 1135 units shipped."
        #expect(AccessibilityCapture.withoutSecrets(ordinary) == ordinary,
                "a screen that never mentions a code must not be redacted")
    }
}

// CF-102: a capture is not made richer by walking the same screen twice.
//
// The walk is given several roots now (the window's web areas, richest first, then the
// window itself as a safety net), which means the same subtree is reachable by more than
// one path. The dedupe gate is what keeps that from doubling every capture.

@Suite("CF-102 overlapping roots do not duplicate text")
struct OverlappingRootTests {

    @Test("CF-102 a subtree reachable from two roots is collected once")
    func overlappingRootsCollectOnce() {
        // The shape the real fix produces: a web area, and the window that contains it.
        let document = FakeAXNode(texts: ["Sidebar"], children: [
            FakeAXNode(texts: ["Ombra daily report"]),
            FakeAXNode(texts: ["Testing memoir MCP"]),
        ])
        let window = FakeAXNode(texts: ["Claude"], children: [document])

        let outcome = BoundedTextWalk.run(
            roots: [document, window],
            limits: untimedLimits(maxDepth: 20, maxNodes: 500, maxCharacters: 5_000),
            isSecure: { $0.secure },
            texts: { $0.texts },
            children: { $0.children }
        )

        // Measured on the live app before this was pinned: 141 duplicated lines, 27% of a
        // capture that was already truncated at the character ceiling.
        #expect(outcome.pieces.count == Set(outcome.pieces).count,
                "the window root re-collected the web area: \(outcome.pieces)")
        #expect(outcome.pieces.contains("Testing memoir MCP"))
        #expect(outcome.pieces.contains("Claude"), "the window's own text is still reached")
    }
}

// CF-111: an application that leaves its title bar empty is still asked what it is showing.

@Suite("CF-111 the main pane names itself")
struct PaneSubjectTests {

    /// The real geometry, read off the Claude desktop app: the conversation and its project
    /// sit together at the top of the pane, and the composer's controls sit at the bottom.
    private static let claudeHeader: [(label: String, x: CGFloat, y: CGFloat)] = [
        ("Bypass permissions", 640, 880),      // composer, bottom of the pane
        ("Opus 5", 780, 880),
        ("Memoir privacy/security audit", 420, 120),   // the header
        ("memoir", 690, 120),                          // the project, same row
        ("Move", 900, 300),
    ]

    @Test("CF-111 the topmost named control is the subject, not the first one found")
    func topmostWins() throws {
        let subject = try #require(AccessibilityCapture.paneSubject(from: Self.claudeHeader))
        #expect(subject == "Memoir privacy/security audit (memoir)", "got \(subject)")
        // The failure this replaces: tree order put the composer first, and an hour of work
        // was labelled "Bypass permissions (Opus 5)".
        #expect(!subject.contains("Bypass permissions"))
        #expect(!subject.contains("Opus 5"))
    }

    @Test("CF-111 a control on another row is not part of the name")
    func onlyTheSameRowJoins() throws {
        let subject = try #require(AccessibilityCapture.paneSubject(from: [
            ("Local AI memory infrastructure", 420, 120),
            ("Move", 900, 300),
        ]))
        #expect(subject == "Local AI memory infrastructure", "a lower control was joined on: \(subject)")
    }

    @Test("CF-111 a pane with nothing named says nothing")
    func nothingNamedIsNil() {
        #expect(AccessibilityCapture.paneSubject(from: []) == nil)
    }
}
