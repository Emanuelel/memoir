import Foundation

// MARK: - Contract notes
//
// The contract in ARCHITECTURE.md specifies:
//
//     public func propose(_ nudge: Nudge, now: Date) async -> Nudge?
//     public func setFocusMode(_ on: Bool) async
//     public func recordDismissal(_ nudge: Nudge, now: Date) async
//     public func debugState() async -> String
//
// All four are implemented exactly as written. Two notes for the integrator:
//
// 1. `debugState()` takes no clock, but the module rule is that decision code
//    never calls `Date()` itself. It is therefore implemented as a thin wrapper
//    over `debugState(now:)`, which is the real, injectable, testable version.
//    `debugState()` reads the wall clock once and does nothing else with it. No
//    other method in this file ever reads the clock.
// 2. Everything else in this file is additive, never a replacement:
//    `evaluate(_:now:)` (a side effect free dry run of the same rules),
//    `updateConfig(_:)`, `configuration()`, `isFocusMode()`, `reset()` and the
//    `calendar:` parameter on `init`, which defaults so that
//    `RestraintEngine(config:)` still compiles unchanged.

/// The gate between the companion's opinions and the user's attention.
///
/// Every nudge in the app funnels through ``propose(_:now:)``. Nothing else may
/// speak. The engine holds a nudge back when any of these is true, checked in
/// this order:
///
/// 1. it is a distraction that has not run long enough yet
/// 2. the moment falls inside quiet hours
/// 3. Focus mode is on and `suppressDuringFocus` is set
/// 4. this exact nudge was dismissed recently and is still in backoff
/// 5. the daily ceiling has been reached
/// 6. another nudge was delivered inside the cooldown window
///
/// Dismissal backoff escalates within a local day: one hour of silence after the
/// first dismissal, four hours after the second, and silence for the rest of the
/// day from the third onward. The mute deadline is an absolute instant, so it
/// survives a midnight crossing correctly, while the dismissal *count* resets at
/// the local day boundary along with the daily nudge counter.
///
/// State is entirely in memory. Nothing here is persisted, so a relaunch starts
/// from a clean slate on purpose: a crash must never leave the companion
/// permanently muted, and a restart must never let a burst of nudges through
/// (the cooldown is re-armed by the first delivery after launch).
public actor RestraintEngine {

    // MARK: - Stored state

    private var config: RestraintConfig
    private let calendar: Calendar

    /// Whether macOS Focus is currently on, as reported by the app layer.
    private var focusMode: Bool = false

    /// When the last nudge was delivered, or the last dismissal was recorded.
    private var lastNudgeAt: Date?

    /// Local midnight of the day ``deliveredToday`` is counted against.
    private var countedDay: Date?

    /// Nudges delivered during ``countedDay``.
    private var deliveredToday: Int = 0

    /// Backoff records keyed by ``Nudge/dedupeKey``.
    private var mutes: [String: MuteRecord] = [:]

    /// The most recent call to ``propose(_:now:)``, for diagnostics.
    private var lastProposal: ProposalRecord?

    /// Lifetime counters since launch, for diagnostics.
    private var totalProposed: Int = 0
    private var totalDelivered: Int = 0

    // MARK: - Nested state types

    private struct MuteRecord: Sendable {
        /// Dismissals recorded during ``dismissalDay``.
        var dismissals: Int
        /// Local midnight of the day ``dismissals`` is counted against.
        var dismissalDay: Date
        /// When the most recent dismissal happened.
        var lastDismissedAt: Date
        /// Absolute instant before which this nudge stays silent.
        var mutedUntil: Date
    }

    private struct ProposalRecord: Sendable {
        let nudge: Nudge
        let decision: RestraintDecision
        let at: Date
    }

    // MARK: - Tuning constants

    /// Silence after the first dismissal of a nudge, in seconds.
    private static let firstDismissalBackoff: TimeInterval = 60 * 60

    /// Silence after the second dismissal of a nudge, in seconds.
    private static let secondDismissalBackoff: TimeInterval = 4 * 60 * 60

    /// Longest a mute may ever run. Guards against a mute deadline that was
    /// written while the system clock was wrong.
    private static let maxMuteHorizon: TimeInterval = 26 * 60 * 60

    // MARK: - Init

    /// Creates an engine.
    /// - Parameters:
    ///   - config: The restraint rules to apply. Can be swapped later with ``updateConfig(_:)``.
    ///   - calendar: Calendar used for local hour and day boundaries. Defaults to the
    ///     user's live calendar; inject a fixed time zone calendar in tests.
    public init(config: RestraintConfig, calendar: Calendar = .autoupdatingCurrent) {
        self.config = config
        self.calendar = calendar
    }

    // MARK: - The only path to the user

    /// Decides whether a nudge may reach the user, and books it if so.
    ///
    /// This is the only way a nudge is ever delivered. When it returns nil the
    /// companion stays quiet and nothing is booked, so the caller may propose
    /// again later at no cost.
    ///
    /// - Parameters:
    ///   - nudge: What the companion wants to say.
    ///   - now: The current instant, always supplied by the caller.
    /// - Returns: The same nudge when it may be delivered, otherwise nil.
    public func propose(_ nudge: Nudge, now: Date) async -> Nudge? {
        // No `await` anywhere in this method: the check and the booking must not
        // be separated by a suspension point, or two concurrent proposals could
        // both slip past the daily cap.
        normalize(now: now)

        let decision = decide(nudge, now: now)
        totalProposed += 1
        lastProposal = ProposalRecord(nudge: nudge, decision: decision, at: now)

        guard decision.isAllowed else {
            let reason = decision.reason?.rawValue ?? "unknown"
            Log.shared.debug("restraint: held back \(nudge.summary) [\(reason)]")
            return nil
        }

        rollDayIfNeeded(now: now)
        deliveredToday += 1
        totalDelivered += 1
        lastNudgeAt = now
        Log.shared.info("restraint: delivered \(nudge.summary) (\(deliveredToday)/\(config.effectiveMaxNudgesPerDay) today)")
        return nudge
    }

    /// Runs the same rules as ``propose(_:now:)`` without booking anything.
    ///
    /// Nothing is mutated, so this is safe to call from a settings screen or a
    /// test to ask "what would happen right now, and why".
    /// - Parameters:
    ///   - nudge: The candidate nudge.
    ///   - now: The instant to evaluate against.
    /// - Returns: Allowed, or the first rule that would hold it back.
    public func evaluate(_ nudge: Nudge, now: Date) async -> RestraintDecision {
        decide(nudge, now: now)
    }

    /// Records that macOS Focus turned on or off.
    /// - Parameter on: True when Focus is active.
    public func setFocusMode(_ on: Bool) async {
        guard on != focusMode else { return }
        focusMode = on
        Log.shared.debug("restraint: focus mode \(on ? "on" : "off")")
    }

    /// Records that the user dismissed a nudge, escalating its backoff.
    ///
    /// One dismissal buys an hour of silence for that exact nudge, a second buys
    /// four hours, a third and any beyond silence it for the rest of the local
    /// day. An existing mute is never shortened.
    ///
    /// A dismissal also re-arms the global cooldown: the user was just
    /// interrupted, and that counts whether or not the interruption landed well.
    ///
    /// - Parameters:
    ///   - nudge: The nudge that was dismissed.
    ///   - now: The instant of the dismissal, always supplied by the caller.
    public func recordDismissal(_ nudge: Nudge, now: Date) async {
        normalize(now: now)

        let key = nudge.dedupeKey
        let today = calendar.startOfDay(for: now)
        let existing = mutes[key]

        var record = existing ?? MuteRecord(
            dismissals: 0,
            dismissalDay: today,
            lastDismissedAt: now,
            mutedUntil: now
        )
        if record.dismissalDay != today { record.dismissals = 0 }
        record.dismissalDay = today
        record.dismissals += 1
        record.lastDismissedAt = now

        let proposed: Date
        switch record.dismissals {
        case 1: proposed = now.addingTimeInterval(Self.firstDismissalBackoff)
        case 2: proposed = now.addingTimeInterval(Self.secondDismissalBackoff)
        default: proposed = startOfNextDay(after: now)
        }
        record.mutedUntil = max(proposed, existing?.mutedUntil ?? proposed)

        mutes[key] = record
        if lastNudgeAt == nil || lastNudgeAt! < now { lastNudgeAt = now }

        Log.shared.debug("restraint: dismissed \(nudge.summary), dismissal \(record.dismissals) today, quiet until \(record.mutedUntil)")
    }

    // MARK: - Configuration

    /// Replaces the active configuration, keeping counters and backoff intact.
    ///
    /// The settings screen calls this when the user edits quiet hours, the
    /// cooldown or the daily cap. Tightening a limit takes effect immediately;
    /// loosening one does not retroactively release nudges already held back.
    /// - Parameter newConfig: The configuration to apply from now on.
    public func updateConfig(_ newConfig: RestraintConfig) async {
        config = newConfig
        Log.shared.info("restraint: config updated (quiet \(newConfig.quietHours.displayRange), cap \(newConfig.effectiveMaxNudgesPerDay), cooldown \(Int(newConfig.effectiveCooldownSeconds))s)")
    }

    /// The active configuration.
    public func configuration() async -> RestraintConfig { config }

    /// Whether the engine currently believes macOS Focus is on.
    public func isFocusMode() async -> Bool { focusMode }

    /// How many nudges have been delivered on the local day containing `now`.
    /// - Parameter now: The instant whose local day should be counted.
    public func deliveredCount(now: Date) async -> Int { effectiveDeliveredCount(now: now) }

    /// Clears every counter, backoff record and timestamp.
    ///
    /// Exposed for tests and for a "forget that I dismissed things" control.
    /// Focus mode and the configuration are left alone.
    public func reset() async {
        lastNudgeAt = nil
        countedDay = nil
        deliveredToday = 0
        mutes.removeAll()
        lastProposal = nil
        totalProposed = 0
        totalDelivered = 0
        Log.shared.debug("restraint: state reset")
    }

    // MARK: - Diagnostics

    /// A plain language dump of why the companion is or is not speaking.
    ///
    /// This is the one place that reads the wall clock, purely so the settings
    /// screen can call it without threading a date through the UI. It makes no
    /// decision and mutates nothing. See the contract notes at the top of the
    /// file.
    public func debugState() async -> String {
        await debugState(now: Date())
    }

    /// A plain language dump of why the companion is or is not speaking, at a
    /// given instant. Mutates nothing.
    /// - Parameter now: The instant to describe.
    public func debugState(now: Date) async -> String {
        var lines: [String] = []
        lines.append("Memoir restraint")
        lines.append("")

        // Headline: would a generic nudge get through right now.
        if let blocker = globalGate(now: now) {
            lines.append("Right now: quiet, because \(blocker.explanation).")
        } else {
            lines.append("Right now: free to speak.")
        }
        lines.append("")

        // Quiet hours.
        let qh = config.quietHours
        if !qh.enabled {
            lines.append("Quiet hours: off.")
        } else if qh.coversWholeDay {
            lines.append("Quiet hours: \(qh.displayRange), which covers the whole day. Memoir can never speak with this setting.")
        } else {
            let active = qh.contains(now, calendar: calendar)
            let wrap = qh.wrapsMidnight ? ", crosses midnight" : ""
            lines.append("Quiet hours: \(qh.displayRange)\(wrap). Currently \(active ? "active" : "inactive").")
        }

        // Focus.
        if config.suppressDuringFocus {
            lines.append("Focus mode: \(focusMode ? "on, so everything is held back" : "off").")
        } else {
            lines.append("Focus mode: \(focusMode ? "on" : "off"), but Memoir is set to speak during Focus anyway.")
        }

        // Daily cap.
        let used = effectiveDeliveredCount(now: now)
        let cap = config.effectiveMaxNudgesPerDay
        if cap == 0 {
            lines.append("Today: nudge limit is 0, so nothing is ever delivered.")
        } else {
            lines.append("Today: \(used) of \(cap) nudges used. The count resets at midnight.")
        }

        // Cooldown.
        let cooldown = config.effectiveCooldownSeconds
        if cooldown <= 0 {
            lines.append("Cooldown: none.")
        } else if let last = lastNudgeAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < 0 {
                lines.append("Cooldown: \(Self.duration(cooldown)). Last nudge is stamped in the future, so Memoir is waiting it out.")
            } else if elapsed < cooldown {
                lines.append("Cooldown: \(Self.duration(cooldown)). Last nudge \(Self.duration(elapsed)) ago, \(Self.duration(cooldown - elapsed)) to go.")
            } else {
                lines.append("Cooldown: \(Self.duration(cooldown)). Last nudge \(Self.duration(elapsed)) ago, clear.")
            }
        } else {
            lines.append("Cooldown: \(Self.duration(cooldown)). Nothing delivered yet this run.")
        }

        // Distraction threshold.
        lines.append("Distraction threshold: \(config.effectiveDistractionThresholdMinutes) min in one app before Memoir mentions it.")

        // Backoff records.
        let live = mutes
            .filter { now < muteDeadline($0.value, now: now) }
            .sorted { $0.key < $1.key }
        if live.isEmpty {
            lines.append("Muted nudges: none.")
        } else {
            lines.append("Muted nudges (\(live.count)):")
            for (key, record) in live {
                let remaining = muteDeadline(record, now: now).timeIntervalSince(now)
                let dismissals = record.dismissalDay == calendar.startOfDay(for: now) ? record.dismissals : 0
                let times = dismissals == 1 ? "1 dismissal" : "\(dismissals) dismissals"
                lines.append("  \(key): \(times) today, quiet for another \(Self.duration(remaining)).")
            }
        }

        // Last proposal.
        if let p = lastProposal {
            let when = clockLabel(p.at)
            switch p.decision {
            case .allowed:
                lines.append("Last proposal at \(when): \(p.nudge.summary). Delivered.")
            case .suppressed(let reason):
                lines.append("Last proposal at \(when): \(p.nudge.summary). Held back, \(reason.explanation).")
            }
        } else {
            lines.append("Last proposal: none yet.")
        }

        lines.append("Since launch: \(totalProposed) proposed, \(totalDelivered) delivered.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Rule evaluation

    /// The rules, in order, with no side effects. Synchronous on purpose so that
    /// ``propose(_:now:)`` can check and book without a suspension point.
    private func decide(_ nudge: Nudge, now: Date) -> RestraintDecision {
        // 1. Per nudge eligibility.
        if case .distraction(_, let minutes) = nudge,
           minutes < config.effectiveDistractionThresholdMinutes {
            return .suppressed(.belowDistractionThreshold)
        }

        // 2. Quiet hours.
        if config.quietHours.contains(now, calendar: calendar) {
            return .suppressed(.quietHours)
        }

        // 3. Focus.
        if focusMode && config.suppressDuringFocus {
            return .suppressed(.focusMode)
        }

        // 4. Dismissal backoff for this exact nudge.
        if let record = mutes[nudge.dedupeKey], now < muteDeadline(record, now: now) {
            return .suppressed(.dismissedRecently)
        }

        // 5. Daily ceiling.
        if effectiveDeliveredCount(now: now) >= config.effectiveMaxNudgesPerDay {
            return .suppressed(.dailyCap)
        }

        // 6. Global cooldown. A last nudge stamped in the future means the clock
        //    moved backwards; that resolves to silence.
        if let last = lastNudgeAt, now.timeIntervalSince(last) < config.effectiveCooldownSeconds {
            return .suppressed(.cooldown)
        }

        return .allowed
    }

    /// The generic gate: everything except per nudge eligibility and per nudge
    /// backoff. Used for the headline in ``debugState(now:)``.
    private func globalGate(now: Date) -> SuppressionReason? {
        if config.quietHours.contains(now, calendar: calendar) { return .quietHours }
        if focusMode && config.suppressDuringFocus { return .focusMode }
        if effectiveDeliveredCount(now: now) >= config.effectiveMaxNudgesPerDay { return .dailyCap }
        if let last = lastNudgeAt, now.timeIntervalSince(last) < config.effectiveCooldownSeconds { return .cooldown }
        return nil
    }

    // MARK: - Day boundaries and clock sanity

    /// Nudges already delivered on the local day containing `now`. Pure: the
    /// stored counter is simply ignored when it belongs to another day.
    private func effectiveDeliveredCount(now: Date) -> Int {
        guard let day = countedDay, day == calendar.startOfDay(for: now) else { return 0 }
        return deliveredToday
    }

    /// A mute deadline, clamped so a bad clock cannot mute a nudge for months.
    private func muteDeadline(_ record: MuteRecord, now: Date) -> Date {
        min(record.mutedUntil, now.addingTimeInterval(Self.maxMuteHorizon))
    }

    /// Local midnight at the start of the day after the one containing `date`.
    private func startOfNextDay(after date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
    }

    /// Commits the daily rollover of the delivered counter.
    ///
    /// Dismissal counts are *not* rewritten here. They are read lazily against
    /// the day they were recorded on, which keeps the mute deadline (an absolute
    /// instant) independent of the counter: a nudge dismissed three times at
    /// 23:50 is still quiet at 00:10, and a fresh dismissal on the new day
    /// starts the escalation over at one hour.
    private func rollDayIfNeeded(now: Date) {
        let today = calendar.startOfDay(for: now)
        guard countedDay != today else { return }
        countedDay = today
        deliveredToday = 0
    }

    /// Housekeeping run at the top of every mutating entry point: day rollover,
    /// plus recovery from a system clock that jumped backwards. Without the
    /// second half, one bad clock reading could mute the companion for as long
    /// as the jump lasted.
    private func normalize(now: Date) {
        rollDayIfNeeded(now: now)

        if let last = lastNudgeAt, last > now {
            lastNudgeAt = now
        }

        let horizon = now.addingTimeInterval(Self.maxMuteHorizon)
        let today = calendar.startOfDay(for: now)
        var kept: [String: MuteRecord] = [:]
        kept.reserveCapacity(mutes.count)
        for (key, record) in mutes {
            var r = record
            if r.mutedUntil > horizon { r.mutedUntil = horizon }
            // Keep a record while it is still muting, and also while today's
            // dismissal count still matters for escalation. Anything expired and
            // left over from an earlier day is dropped, so the dictionary cannot
            // grow without bound over a long uptime.
            if now < r.mutedUntil || r.dismissalDay == today {
                kept[key] = r
            }
        }
        mutes = kept
    }

    // MARK: - Formatting

    /// Renders a wall clock time in the engine's own calendar, so diagnostics
    /// agree with the day and hour boundaries the rules actually used.
    private func clockLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? Locale.autoupdatingCurrent
        return f.string(from: date)
    }

    /// Renders a duration for the settings screen: "45 sec", "12 min", "2 hr 5 min".
    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total) sec" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}
