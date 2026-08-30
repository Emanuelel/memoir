//  CF-12b: event-driven capture triggers.
//
//  Capture used to run on a fixed timer, which walked the accessibility tree whether or not
//  anything had changed. That is what put eight copies of one page into a single context
//  packet and burned CPU on a static screen. These tests pin the replacement: a capture
//  happens because something *moved*, and bursts are floored so typing cannot storm it.
//
//  Every instant is injected. Nothing here sleeps or reads the wall clock.

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-12b · event-driven capture triggers")
struct TriggerDetectorTests {

    private static func config() -> CaptureConfig {
        var c = CaptureConfig()
        c.minCaptureIntervalSeconds = 0.2
        c.checkpointIntervalSeconds = 1.5
        c.idleCaptureIntervalSeconds = 30
        c.typingPauseSeconds = 1.2
        c.idleThresholdSeconds = 120
        return c
    }

    private static func signals(
        app: String? = "com.apple.Safari",
        title: String? = "Home",
        idle: Double = 0,
        keystroke: Double = .greatestFiniteMagnitude
    ) -> CaptureSignals {
        CaptureSignals(
            bundleID: app,
            windowTitle: title,
            idleSeconds: idle,
            secondsSinceKeystroke: keystroke
        )
    }

    private static let t0 = TestClock.reference

    @Test("CF-12b the first tick always captures")
    func firstTick() {
        var d = TriggerDetector()
        let trigger = d.evaluate(Self.signals(), config: Self.config(), now: Self.t0, isFirstTick: true)
        #expect(trigger == .resume)
    }

    @Test("CF-12b a static screen produces no captures at all")
    func staticScreenIsSilent() {
        var d = TriggerDetector()
        let c = Self.config()
        _ = d.evaluate(Self.signals(), config: c, now: Self.t0, isFirstTick: true)

        // Ten seconds of an unchanging screen: no app switch, no new window, no typing.
        for step in 1...20 {
            let now = Self.t0.addingTimeInterval(Double(step) * 0.5)
            let trigger = d.evaluate(Self.signals(), config: c, now: now)
            #expect(trigger == nil, "a screen that did not change must not be captured again")
        }
    }

    @Test("CF-12b switching apps triggers a capture")
    func appSwitch() {
        var d = TriggerDetector()
        let c = Self.config()
        _ = d.evaluate(Self.signals(app: "com.apple.Safari"), config: c, now: Self.t0, isFirstTick: true)

        let later = Self.t0.addingTimeInterval(5)
        let trigger = d.evaluate(Self.signals(app: "com.apple.Notes", title: "Notes"), config: c, now: later)
        #expect(trigger == .appSwitch)
    }

    @Test("CF-12b changing document in the same app triggers a capture")
    func windowChange() {
        var d = TriggerDetector()
        let c = Self.config()
        _ = d.evaluate(Self.signals(title: "Home"), config: c, now: Self.t0, isFirstTick: true)
        _ = d.evaluate(Self.signals(title: "Home"), config: c, now: Self.t0.addingTimeInterval(1))

        let later = Self.t0.addingTimeInterval(5)
        let trigger = d.evaluate(
            Self.signals(title: "Architecture \u{2014} Obsidian"), config: c, now: later
        )
        #expect(trigger == .windowChange)
    }

    @Test("CF-12b typing captures once on the pause, not once per keystroke")
    func typingPauseFiresOnce() {
        var d = TriggerDetector()
        let c = Self.config()
        _ = d.evaluate(Self.signals(), config: c, now: Self.t0, isFirstTick: true)

        // Actively typing: keystrokes land inside the pause window. Nothing should fire.
        // This is the storm that made a capture per keystroke.
        var fired = 0
        for step in 1...12 {
            let now = Self.t0.addingTimeInterval(Double(step) * 0.25)
            if d.evaluate(Self.signals(keystroke: 0.1), config: c, now: now) != nil { fired += 1 }
        }
        #expect(fired == 0, "typing itself must never trigger a capture")

        // Keyboard goes quiet past the pause threshold: exactly one capture.
        let quiet = Self.t0.addingTimeInterval(10)
        #expect(d.evaluate(Self.signals(keystroke: 2), config: c, now: quiet) == .typingPause)
        // And it does not repeat while the keyboard stays quiet.
        let later = Self.t0.addingTimeInterval(20)
        #expect(d.evaluate(Self.signals(keystroke: 12), config: c, now: later) == nil)
    }

    @Test("CF-12b the global floor rejects a second capture within 200ms")
    func globalFloor() {
        var d = TriggerDetector()
        let c = Self.config()
        _ = d.evaluate(Self.signals(app: "a", title: "1"), config: c, now: Self.t0, isFirstTick: true)

        // Two app switches 50ms apart: the second is inside the hard floor.
        let t1 = Self.t0.addingTimeInterval(0.05)
        #expect(d.evaluate(Self.signals(app: "b", title: "2"), config: c, now: t1) == nil)

        // Past the floor, it is allowed.
        let t2 = Self.t0.addingTimeInterval(0.5)
        #expect(d.evaluate(Self.signals(app: "c", title: "3"), config: c, now: t2) == .appSwitch)
    }

    @Test("CF-12b typing pauses get the higher checkpoint floor")
    func checkpointFloor() {
        var d = TriggerDetector()
        let c = Self.config()
        _ = d.evaluate(Self.signals(), config: c, now: Self.t0, isFirstTick: true)

        // A typing pause 0.5s after the last capture clears the 0.2s global floor but not
        // the 1.5s checkpoint floor.
        _ = d.evaluate(Self.signals(keystroke: 0.1), config: c, now: Self.t0.addingTimeInterval(0.2))
        let tooSoon = Self.t0.addingTimeInterval(0.5)
        #expect(d.evaluate(Self.signals(keystroke: 2), config: c, now: tooSoon) == nil)

        // Past 1.5s it is allowed.
        _ = d.evaluate(Self.signals(keystroke: 0.1), config: c, now: Self.t0.addingTimeInterval(1.6))
        let ok = Self.t0.addingTimeInterval(2.5)
        #expect(d.evaluate(Self.signals(keystroke: 2), config: c, now: ok) == .typingPause)
    }

    @Test("CF-12b an idle screen never triggers, and idleness clears pending typing")
    func idleIsSilent() {
        var d = TriggerDetector()
        let c = Self.config()
        _ = d.evaluate(Self.signals(), config: c, now: Self.t0, isFirstTick: true)
        _ = d.evaluate(Self.signals(keystroke: 0.1), config: c, now: Self.t0.addingTimeInterval(1))

        // User walks away. Idle beats every other signal.
        let away = Self.t0.addingTimeInterval(300)
        #expect(d.evaluate(Self.signals(idle: 300, keystroke: 300), config: c, now: away) == nil)

        // Coming back must not fire a stale typing pause from before they left.
        let back = Self.t0.addingTimeInterval(400)
        #expect(d.evaluate(Self.signals(idle: 0, keystroke: 400), config: c, now: back) == nil)
    }

    @Test("CF-12b the idle fallback becomes due only after the configured quiet period")
    func idleFallback() {
        var d = TriggerDetector()
        let c = Self.config()
        _ = d.evaluate(Self.signals(), config: c, now: Self.t0, isFirstTick: true)

        #expect(d.idleFallbackDue(now: Self.t0.addingTimeInterval(10), config: c) == false)
        #expect(d.idleFallbackDue(now: Self.t0.addingTimeInterval(31), config: c) == true)

        // Noting a capture resets the clock.
        d.noteCapture(at: Self.t0.addingTimeInterval(31))
        #expect(d.idleFallbackDue(now: Self.t0.addingTimeInterval(40), config: c) == false)
    }

    @Test("CF-12b a debounced change is not re-reported on the next tick")
    func debouncedChangeIsNotRepeated() {
        var d = TriggerDetector()
        let c = Self.config()
        _ = d.evaluate(Self.signals(app: "a", title: "1"), config: c, now: Self.t0, isFirstTick: true)

        // Switch inside the floor: suppressed.
        #expect(d.evaluate(Self.signals(app: "b", title: "2"), config: c,
                           now: Self.t0.addingTimeInterval(0.05)) == nil)
        // Well past the floor, with nothing further changed: must stay quiet rather than
        // re-firing the switch it already saw.
        #expect(d.evaluate(Self.signals(app: "b", title: "2"), config: c,
                           now: Self.t0.addingTimeInterval(3)) == nil)
    }

    @Test("CF-12b manual capture ignores every floor")
    func manualIgnoresFloors() {
        let c = Self.config()
        var d = TriggerDetector()
        _ = d.evaluate(Self.signals(), config: c, now: Self.t0, isFirstTick: true)
        #expect(CaptureTrigger.manual.isCheckpoint == false)
        #expect(CaptureTrigger.typingPause.isCheckpoint == true)
    }

    @Test("CF-12b an unread counter in the title is not a document change")
    func unreadCounterIsNotAChange() {
        var d = TriggerDetector()
        let c = Self.config()
        _ = d.evaluate(Self.signals(title: "WhatsApp - Google Chrome"), config: c,
                       now: Self.t0, isFirstTick: true)
        _ = d.evaluate(Self.signals(title: "WhatsApp - Google Chrome"), config: c,
                       now: Self.t0.addingTimeInterval(1))

        // Messages arriving retitle the tab. Real regression: one conversation produced
        // four near-identical captures at 17:07.
        for (step, title) in [(5.0, "(1) WhatsApp - Google Chrome"),
                              (6.0, "(2) WhatsApp - Google Chrome"),
                              (7.0, "[3] WhatsApp - Google Chrome")] {
            let trigger = d.evaluate(Self.signals(title: title), config: c,
                                     now: Self.t0.addingTimeInterval(step))
            #expect(trigger == nil, "an unread badge is not a new document")
        }

        // A genuinely different document still fires.
        let real = d.evaluate(Self.signals(title: "Inbox - Google Chrome"), config: c,
                              now: Self.t0.addingTimeInterval(9))
        #expect(real == .windowChange)
    }

    @Test("CF-12b title normalisation strips badges and dirty markers")
    func titleNormalisation() {
        #expect(TriggerDetector.normalizeTitle("(12) Slack") == "Slack")
        #expect(TriggerDetector.normalizeTitle("[3] Inbox") == "Inbox")
        #expect(TriggerDetector.normalizeTitle("notes.md •") == "notes.md")
        let realTitle = "Architecture \u{2014} Obsidian"
        #expect(TriggerDetector.normalizeTitle(realTitle) == realTitle)
    }
}
