import Foundation

/// Everything that governs how often the companion is allowed to speak.
///
/// Persisted as part of `config.json`. Decoding is deliberately lenient: a file
/// written by an older build that is missing a key falls back to the default for
/// that key rather than failing, because a failed decode would drop the user's
/// quiet hours on the floor.
public struct RestraintConfig: Sendable, Codable, Equatable {

    /// Daily window in which nothing is ever delivered.
    public var quietHours: QuietHours

    /// Minimum gap between any two delivered nudges, in seconds. Default 15 minutes.
    public var cooldownSeconds: Double = 900

    /// Hard ceiling on delivered nudges per local calendar day. Default 8.
    public var maxNudgesPerDay: Int = 8

    /// When true, nothing is delivered while macOS Focus is on. Default true.
    public var suppressDuringFocus: Bool = true

    /// How long an uninterrupted stretch in one app must run before a
    /// ``Nudge/distraction(appName:minutes:)`` is eligible. Default 11 minutes.
    ///
    /// The comparison is "greater than or equal to": a stretch reported at exactly
    /// this many minutes has reached the mark and qualifies.
    public var distractionThresholdMinutes: Int = 11

    /// Creates a restraint configuration.
    /// - Parameters:
    ///   - quietHours: Daily silent window. Defaults to 22:00 to 07:00, enabled.
    ///   - cooldownSeconds: Minimum gap between nudges. Defaults to 900.
    ///   - maxNudgesPerDay: Daily ceiling. Defaults to 8.
    ///   - suppressDuringFocus: Whether Focus silences the companion. Defaults to true.
    ///   - distractionThresholdMinutes: Distraction eligibility threshold. Defaults to 11.
    public init(
        quietHours: QuietHours = .default,
        cooldownSeconds: Double = 900,
        maxNudgesPerDay: Int = 8,
        suppressDuringFocus: Bool = true,
        distractionThresholdMinutes: Int = 11
    ) {
        self.quietHours = quietHours
        self.cooldownSeconds = cooldownSeconds
        self.maxNudgesPerDay = maxNudgesPerDay
        self.suppressDuringFocus = suppressDuringFocus
        self.distractionThresholdMinutes = distractionThresholdMinutes
    }

    /// The shipping default.
    public static let `default` = RestraintConfig()

    /// A configuration under which the companion never speaks. Useful for a
    /// "mute Memoir" switch and for tests that need a guaranteed silent engine.
    public static let silent = RestraintConfig(
        quietHours: .allDay,
        cooldownSeconds: 900,
        maxNudgesPerDay: 0,
        suppressDuringFocus: true,
        distractionThresholdMinutes: 11
    )

    // MARK: - Sanitised accessors
    //
    // The stored properties are user editable and round trip through JSON, so the
    // engine never reads them raw. Nonsense values resolve toward silence.

    /// ``cooldownSeconds`` clamped to a finite, non negative value.
    public var effectiveCooldownSeconds: TimeInterval {
        guard cooldownSeconds.isFinite else { return RestraintConfig.default.cooldownSeconds }
        return max(0, cooldownSeconds)
    }

    /// ``maxNudgesPerDay`` clamped to a non negative value. Zero means never speak.
    public var effectiveMaxNudgesPerDay: Int { max(0, maxNudgesPerDay) }

    /// ``distractionThresholdMinutes`` clamped to a non negative value.
    public var effectiveDistractionThresholdMinutes: Int { max(0, distractionThresholdMinutes) }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case quietHours, cooldownSeconds, maxNudgesPerDay, suppressDuringFocus, distractionThresholdMinutes
    }

    /// Lenient decoding. Any missing key falls back to its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RestraintConfig.default
        self.quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? fallback.quietHours
        self.cooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .cooldownSeconds) ?? fallback.cooldownSeconds
        self.maxNudgesPerDay = try c.decodeIfPresent(Int.self, forKey: .maxNudgesPerDay) ?? fallback.maxNudgesPerDay
        self.suppressDuringFocus = try c.decodeIfPresent(Bool.self, forKey: .suppressDuringFocus) ?? fallback.suppressDuringFocus
        self.distractionThresholdMinutes = try c.decodeIfPresent(Int.self, forKey: .distractionThresholdMinutes)
            ?? fallback.distractionThresholdMinutes
    }
}

// MARK: - Decisions

/// Why a nudge was held back.
public enum SuppressionReason: String, Sendable, Codable, Equatable, CaseIterable {

    /// The instant falls inside the configured quiet hours.
    case quietHours

    /// macOS Focus is on and `suppressDuringFocus` is set.
    case focusMode

    /// The distraction has not run long enough yet.
    case belowDistractionThreshold

    /// This exact nudge was dismissed recently and is still in backoff.
    case dismissedRecently

    /// The daily ceiling has already been reached.
    case dailyCap

    /// Another nudge was delivered within the cooldown window.
    case cooldown

    /// Plain language explanation for the settings screen.
    public var explanation: String {
        switch self {
        case .quietHours: return "inside quiet hours"
        case .focusMode: return "Focus mode is on"
        case .belowDistractionThreshold: return "the distraction is too short to mention"
        case .dismissedRecently: return "this one was dismissed recently"
        case .dailyCap: return "the daily nudge limit is reached"
        case .cooldown: return "another nudge went out too recently"
        }
    }
}

/// The outcome of evaluating a nudge against the restraint rules.
public enum RestraintDecision: Sendable, Equatable {

    /// The nudge may be delivered.
    case allowed

    /// The nudge must be held back, with the first rule that stopped it.
    case suppressed(SuppressionReason)

    /// True when the nudge may be delivered.
    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    /// The blocking rule, or nil when the nudge is allowed.
    public var reason: SuppressionReason? {
        if case .suppressed(let r) = self { return r }
        return nil
    }
}
