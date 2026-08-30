import Foundation

/// Whether the memory is actually being written, as opposed to whether the app thinks it is.
///
/// The worst thing this product can do is look fine while recording nothing. A user who
/// discovers two weeks later that Accessibility was revoked by a system update has lost two
/// weeks, and every answer Memoir gave in the meantime quietly described the wrong days.
/// Nothing in the app measured that: ``CaptureLoop`` swallows every failure by design (losing
/// capture because one read failed would be worse than any bug it could report) and
/// `hasAccessibility` was read once at launch and never again.
///
/// So health is not inferred from "did we call `start()`". It is measured from captures
/// actually landing while the user was demonstrably at the machine.
public enum CaptureHealth: Sendable, Equatable {

    /// Nothing has landed yet and nothing has gone wrong yet. The launch grace state.
    case starting
    /// Captures are landing. The state that should be true almost always.
    case capturing
    /// The user switched it off themselves. A choice, not a fault. But still visible.
    case paused
    /// Capture cannot run at all.
    case blocked(Reason)
    /// Capture is running, the user is working, and nothing is being written.
    case stalled

    public enum Reason: String, Sendable, Equatable {
        /// Accessibility permission is gone. Re-signing the app, a system update, or the user
        /// revoking it all land here, and all of them are silent today.
        case accessibility
        /// The polling task is not alive and the user did not pause it.
        case loopStopped
    }

    /// Whether the memory is being written right now.
    public var isHealthy: Bool {
        switch self {
        case .capturing, .starting: return true
        case .paused, .blocked, .stalled: return false
        }
    }

    /// Whether this is a fault rather than a choice. Faults alarm; a pause does not.
    public var isFault: Bool {
        switch self {
        case .blocked, .stalled: return true
        case .capturing, .starting, .paused: return false
        }
    }

    /// The strip's words. Short enough for a 19pt notch wing.
    public var shortLabel: String {
        switch self {
        case .starting, .capturing: return "Logging"
        case .paused: return "Paused"
        case .blocked: return "Not logging"
        case .stalled: return "Not logging"
        }
    }

    /// What the band says when it widens. Nil when there is nothing wrong.
    ///
    /// Kept under thirty characters on purpose. The collapsed band's wing is 230 points wide
    /// and the mark takes the first twenty of it, so a longer sentence does not get a smaller
    /// font: it gets an ellipsis, and a warning that ends in "…" is a warning that failed.
    /// ``detail`` is where the full explanation lives, on a surface with room for it.
    public var announcement: String? {
        switch self {
        case .starting, .capturing: return nil
        case .paused: return "Paused: nothing is logged"
        case .blocked(.accessibility): return "Permission lost: not logging"
        case .blocked(.loopStopped): return "Capture stopped: not logging"
        case .stalled: return "Not logging anything"
        }
    }

    /// The same news at length, for Settings. Names the cause and the fix.
    public var detail: String? {
        switch self {
        case .starting, .capturing:
            return nil
        case .paused:
            return "You paused capture. Nothing is being recorded until you resume it."
        case .blocked(.accessibility):
            return "Memoir no longer has Accessibility permission, so it can read nothing at all. Re-grant it in System Settings → Privacy & Security → Accessibility. A rebuilt or re-signed app loses this grant silently."
        case .blocked(.loopStopped):
            return "The capture loop is not running and you have not paused it. Quitting and reopening Memoir restarts it."
        case .stalled:
            return "Memoir has been running while you worked and has written nothing. Check that the apps you use are not on the excluded list, and that Accessibility is still granted."
        }
    }
}

/// One poll's worth of the world, so the verdict below can be tested without a screen.
public struct CaptureHealthSample: Sendable, Equatable {
    /// The user's own pause switch.
    public var paused: Bool
    /// Whether the process is still trusted for Accessibility.
    public var accessibilityGranted: Bool
    /// Whether the polling task is alive.
    public var loopRunning: Bool
    /// The loop's lifetime capture count. Only its movement matters.
    public var capturesWritten: Int
    /// Whether the user was at the machine.
    public var userActive: Bool
    /// The frontmost app, or nil. Excluded apps must be passed as nil: an hour in a
    /// password manager is an hour Memoir is *supposed* to record nothing.
    public var eligibleBundleID: String?

    public init(
        paused: Bool,
        accessibilityGranted: Bool,
        loopRunning: Bool,
        capturesWritten: Int,
        userActive: Bool,
        eligibleBundleID: String?
    ) {
        self.paused = paused
        self.accessibilityGranted = accessibilityGranted
        self.loopRunning = loopRunning
        self.capturesWritten = capturesWritten
        self.userActive = userActive
        self.eligibleBundleID = eligibleBundleID
    }
}

/// Turns a stream of samples into a verdict.
///
/// A value type with no timers and no environment, so every rule below is a unit test rather
/// than a thing somebody has to reproduce by revoking a permission and waiting five minutes.
public struct CaptureHealthJudge: Sendable {

    /// Seconds of eligible, active, capture-free work before the verdict turns to `.stalled`.
    ///
    /// Four minutes. `CaptureConfig.idleCaptureIntervalSeconds` is 30, so a working pipeline
    /// writes something every half minute even when the screen is still; eight consecutive
    /// misses is not noise.
    public static let stallSeconds: TimeInterval = 240

    /// How many *different* apps must have gone unrecorded before a stall is declared.
    ///
    /// The guard against crying wolf. One app that yields no accessibility text (a game, a
    /// canvas app, a video) is a coverage problem, and `AppCaptureQuality` already reports
    /// those honestly per app. A pipeline that is genuinely broken fails in every app at once,
    /// so requiring two distinct apps separates "this app is opaque" from "Memoir is dead".
    public static let stallDistinctApps = 2

    /// Seconds a stopped loop is given to start before that counts as a fault.
    ///
    /// Resuming capture hands the work to an actor, so there is always a moment where the
    /// user has un-paused and the task is not alive yet. Alarming during it would train
    /// people to ignore the alarm, which is the only way this indicator can fail.
    public static let loopStartGraceSeconds: TimeInterval = 20

    /// Eligible active seconds since the last capture landed.
    private var unproductiveSeconds: TimeInterval = 0
    /// Distinct non-excluded apps seen since the last capture landed.
    private var unproductiveApps: Set<String> = []
    /// Seconds the loop has been un-paused but not running.
    private var notRunningSeconds: TimeInterval = 0
    /// The last capture count observed, to spot movement.
    private var lastCount: Int?
    /// The verdict as it stands.
    private(set) public var health: CaptureHealth = .starting

    public init() {}

    /// Folds one sample in and returns the verdict.
    ///
    /// - Parameter elapsed: seconds since the previous sample. The caller owns the cadence.
    @discardableResult
    public mutating func observe(_ sample: CaptureHealthSample, elapsed: TimeInterval) -> CaptureHealth {
        // A pause is the user's own answer to this question. It clears the accrual so that
        // resuming does not immediately report a stall for time capture was never meant to run.
        guard !sample.paused else {
            resetAccrual(from: sample)
            health = .paused
            return health
        }

        // Definitive faults, in order of how badly they break things. Neither needs the
        // stall timer: there is nothing to wait for.
        guard sample.accessibilityGranted else {
            resetAccrual(from: sample)
            health = .blocked(.accessibility)
            return health
        }
        guard sample.loopRunning else {
            notRunningSeconds += elapsed
            resetAccrual(from: sample)
            if notRunningSeconds >= Self.loopStartGraceSeconds {
                health = .blocked(.loopStopped)
            } else if health.isFault || health == .paused {
                health = .starting
            }
            return health
        }
        notRunningSeconds = 0

        // A fault that has cleared must not leave its own verdict standing. Un-pausing, or
        // re-granting the permission, returns to the grace state and earns `.capturing` back
        // the same way a fresh launch does, by actually writing something.
        if health == .paused || health == .blocked(.accessibility) || health == .blocked(.loopStopped) {
            resetAccrual(from: sample)
            health = .starting
        }

        // Movement in the counter is proof, and the only proof there is.
        if let last = lastCount, sample.capturesWritten > last {
            resetAccrual(from: sample)
            health = .capturing
            return health
        }
        lastCount = sample.capturesWritten

        // Time the loop was never expected to record cannot count against it.
        guard sample.userActive, let bundle = sample.eligibleBundleID else { return health }

        unproductiveSeconds += elapsed
        unproductiveApps.insert(bundle)

        if unproductiveSeconds >= Self.stallSeconds,
           unproductiveApps.count >= Self.stallDistinctApps {
            health = .stalled
        }
        return health
    }

    private mutating func resetAccrual(from sample: CaptureHealthSample) {
        lastCount = sample.capturesWritten
        unproductiveSeconds = 0
        unproductiveApps.removeAll()
    }
}

/// Reads the machine for one ``CaptureHealthSample``.
///
/// It lives here rather than in the app because everything it needs (the frontmost app, the
/// HID idle counter, the exclusion list) is internal to this module, and because a probe that
/// reads the environment is exactly the thing a judge must not do if the judge is to be tested.
public enum CaptureHealthProbe {

    /// Samples everything the app cannot see for itself.
    ///
    /// Nothing here reads the screen or costs a tree walk: a trust check, a HID query, and the
    /// frontmost bundle identifier.
    ///
    /// - Parameters:
    ///   - paused: the user's own pause switch.
    ///   - loopRunning: whether ``CaptureLoop`` reports a live task.
    ///   - capturesWritten: the loop's lifetime counter.
    ///   - config: the live capture configuration, for the idle threshold and the exclusions.
    public static func sample(
        paused: Bool,
        loopRunning: Bool,
        capturesWritten: Int,
        config: CaptureConfig
    ) -> CaptureHealthSample {
        let front = FrontmostApp.current()
        // An excluded app is passed as nil, not as its bundle ID. Time spent in a password
        // manager is time Memoir is *supposed* to record nothing, and counting it towards a
        // stall would raise the alarm for the app working exactly as designed.
        let eligible = front.flatMap { config.isExcluded($0.bundleID) ? nil : $0.bundleID }
        return CaptureHealthSample(
            paused: paused,
            accessibilityGranted: Permissions.hasAccessibility(),
            loopRunning: loopRunning,
            capturesWritten: capturesWritten,
            userActive: IdleMonitor.idleSeconds() < config.effectiveIdleThreshold,
            eligibleBundleID: eligible
        )
    }
}
