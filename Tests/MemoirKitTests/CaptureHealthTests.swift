import Testing
import Foundation
@testable import MemoirKit

/// The rules that decide whether Memoir tells somebody their memory has stopped.
///
/// These matter more than most: a verdict that is wrong in one direction lets a user lose
/// weeks of their life without being told, and wrong in the other direction trains them to
/// ignore the one indicator that would have said so.
@Suite("Capture health")
struct CaptureHealthTests {

    /// A healthy sample: permission granted, loop alive, user working in an ordinary app.
    private func working(captures: Int, app: String = "com.apple.Safari") -> CaptureHealthSample {
        CaptureHealthSample(
            paused: false, accessibilityGranted: true, loopRunning: true,
            capturesWritten: captures, userActive: true, eligibleBundleID: app
        )
    }

    private let tick: TimeInterval = 15

    @Test("Nothing is claimed before anything has happened")
    func startsUndecided() {
        var judge = CaptureHealthJudge()
        #expect(judge.health == .starting)
        #expect(judge.observe(working(captures: 0), elapsed: tick) == .starting)
    }

    @Test("A capture landing is the only proof of health")
    func capturesProveHealth() {
        var judge = CaptureHealthJudge()
        _ = judge.observe(working(captures: 0), elapsed: tick)
        #expect(judge.observe(working(captures: 1), elapsed: tick) == .capturing)
    }

    @Test("A revoked permission is reported at once, with no waiting")
    func revokedPermissionIsImmediate() {
        var judge = CaptureHealthJudge()
        _ = judge.observe(working(captures: 1), elapsed: tick)
        _ = judge.observe(working(captures: 2), elapsed: tick)
        #expect(judge.health == .capturing)

        let revoked = CaptureHealthSample(
            paused: false, accessibilityGranted: false, loopRunning: true,
            capturesWritten: 2, userActive: true, eligibleBundleID: "com.apple.Safari"
        )
        #expect(judge.observe(revoked, elapsed: tick) == .blocked(.accessibility))
    }

    @Test("A pause is a choice, and never reported as a fault")
    func pauseIsNotAFault() {
        var judge = CaptureHealthJudge()
        let paused = CaptureHealthSample(
            paused: true, accessibilityGranted: true, loopRunning: true,
            capturesWritten: 3, userActive: true, eligibleBundleID: "com.apple.Safari"
        )
        #expect(judge.observe(paused, elapsed: tick) == .paused)
        #expect(judge.health.isFault == false)
        #expect(judge.health.isHealthy == false)
    }

    @Test("Un-pausing does not leave the paused verdict standing")
    func resumingClearsThePausedVerdict() {
        var judge = CaptureHealthJudge()
        let paused = CaptureHealthSample(
            paused: true, accessibilityGranted: true, loopRunning: true,
            capturesWritten: 3, userActive: true, eligibleBundleID: "com.apple.Safari"
        )
        _ = judge.observe(paused, elapsed: tick)
        // Resumed, but nothing has landed yet: the honest answer is "starting", not "paused".
        #expect(judge.observe(working(captures: 3), elapsed: tick) == .starting)
        #expect(judge.observe(working(captures: 4), elapsed: tick) == .capturing)
    }

    @Test("A whole working hour with nothing captured is a stall")
    func silenceWhileWorkingIsAStall() {
        var judge = CaptureHealthJudge()
        _ = judge.observe(working(captures: 5), elapsed: tick)
        _ = judge.observe(working(captures: 6), elapsed: tick)
        #expect(judge.health == .capturing)

        // Twenty ticks of five minutes' work across two apps, and the counter never moves.
        for i in 0..<20 {
            _ = judge.observe(working(captures: 6, app: i.isMultiple(of: 2) ? "a" : "b"), elapsed: tick)
        }
        #expect(judge.health == .stalled)
    }

    @Test("One opaque app is a coverage problem, not a broken pipeline")
    func oneSilentAppDoesNotCryWolf() {
        var judge = CaptureHealthJudge()
        _ = judge.observe(working(captures: 5), elapsed: tick)
        _ = judge.observe(working(captures: 6), elapsed: tick)

        // An hour in a game or a canvas app that publishes no accessibility text. Memoir is
        // working exactly as designed and must not say otherwise.
        for _ in 0..<240 {
            _ = judge.observe(working(captures: 6, app: "com.unity.game"), elapsed: tick)
        }
        #expect(judge.health == .capturing)
    }

    @Test("Time at a password manager cannot count against capture")
    func excludedTimeIsNotHeldAgainstIt() {
        var judge = CaptureHealthJudge()
        _ = judge.observe(working(captures: 5), elapsed: tick)
        _ = judge.observe(working(captures: 6), elapsed: tick)

        let excluded = CaptureHealthSample(
            paused: false, accessibilityGranted: true, loopRunning: true,
            capturesWritten: 6, userActive: true, eligibleBundleID: nil
        )
        for _ in 0..<240 { _ = judge.observe(excluded, elapsed: tick) }
        #expect(judge.health == .capturing)
    }

    @Test("A night at an idle Mac is not a stall")
    func idleTimeIsNotAStall() {
        var judge = CaptureHealthJudge()
        _ = judge.observe(working(captures: 5), elapsed: tick)
        _ = judge.observe(working(captures: 6), elapsed: tick)

        let away = CaptureHealthSample(
            paused: false, accessibilityGranted: true, loopRunning: true,
            capturesWritten: 6, userActive: false, eligibleBundleID: "com.apple.Safari"
        )
        for _ in 0..<2000 { _ = judge.observe(away, elapsed: tick) }
        #expect(judge.health == .capturing)
    }

    @Test("A loop that is starting up gets a grace period, and then does not")
    func loopStartHasAGracePeriod() {
        var judge = CaptureHealthJudge()
        let stopped = CaptureHealthSample(
            paused: false, accessibilityGranted: true, loopRunning: false,
            capturesWritten: 0, userActive: true, eligibleBundleID: "com.apple.Safari"
        )
        #expect(judge.observe(stopped, elapsed: tick) == .starting)
        #expect(judge.observe(stopped, elapsed: tick) == .blocked(.loopStopped))
    }

    @Test("Recovering from a stall takes one capture")
    func recoveryIsImmediate() {
        var judge = CaptureHealthJudge()
        _ = judge.observe(working(captures: 1), elapsed: tick)
        for i in 0..<20 {
            _ = judge.observe(working(captures: 1, app: i.isMultiple(of: 2) ? "a" : "b"), elapsed: tick)
        }
        #expect(judge.health == .stalled)
        #expect(judge.observe(working(captures: 2), elapsed: tick) == .capturing)
    }

    @Test("Every unhealthy state has a sentence, and every healthy one has none")
    func copyExistsExactlyWhereItShould() {
        let broken: [CaptureHealth] = [.paused, .blocked(.accessibility), .blocked(.loopStopped), .stalled]
        for state in broken {
            #expect(state.announcement != nil, "\(state) must be able to say what is wrong")
            #expect(state.detail != nil, "\(state) must be able to explain itself in Settings")
            #expect(state.isHealthy == false)
            // The band's wing truncates past roughly thirty characters, and a warning that
            // ends in an ellipsis is a warning that failed. Asserted rather than eyeballed,
            // because copy drifts and nobody re-measures it.
            #expect(state.announcement!.count <= 30, "too long for the notch: \(state.announcement!)")
        }
        #expect(CaptureHealth.capturing.announcement == nil)
        #expect(CaptureHealth.starting.announcement == nil)
        #expect(CaptureHealth.capturing.detail == nil)
    }
}
