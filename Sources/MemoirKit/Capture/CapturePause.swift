import Foundation

/// How long capture is off for.
///
/// Pause used to be a boolean with no expiry, which made it the same failure as a revoked
/// permission wearing a friendlier hat: somebody switches it off to read something private,
/// gets on with their day, and the memory quietly stops for a fortnight. The switch was doing
/// exactly what it was told; nothing ever asked whether it was still meant to.
///
/// So a pause now carries an end. Choosing one is choosing how long, and the default is an
/// hour rather than forever.
public enum CapturePause: String, Sendable, CaseIterable, Codable, Equatable {
    case fifteenMinutes
    case oneHour
    case fourHours
    /// Off until the user says otherwise. Still available (somebody screen-sharing for three
    /// days has a real reason), but chosen deliberately, never arrived at by default.
    case indefinitely

    /// The default a bare "Pause capture" means.
    ///
    /// An hour: long enough to cover the thing somebody paused for, short enough that
    /// forgetting costs an hour rather than a fortnight.
    public static let `default`: CapturePause = .oneHour

    public var seconds: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 3_600
        case .fourHours: return 4 * 3_600
        case .indefinitely: return nil
        }
    }

    /// The menu's words.
    public var menuTitle: String {
        switch self {
        case .fifteenMinutes: return "For 15 minutes"
        case .oneHour: return "For an hour"
        case .fourHours: return "For 4 hours"
        case .indefinitely: return "Until I turn it back on"
        }
    }

    /// When a pause started now would end. Nil for an indefinite one.
    public func expiry(from now: Date) -> Date? {
        seconds.map { now.addingTimeInterval($0) }
    }
}

/// The pause as it is stored and asked about.
///
/// A value type with an injectable `now`, because "has this expired" is the one question in
/// this feature that must be right and the one that is miserable to test through a clock.
public struct CapturePauseState: Sendable, Equatable {

    /// Whether the user switched capture off at all.
    public var isPaused: Bool
    /// When it comes back by itself. Nil while running, and nil for an indefinite pause.
    public var expiresAt: Date?

    public init(isPaused: Bool = false, expiresAt: Date? = nil) {
        self.isPaused = isPaused
        self.expiresAt = expiresAt
    }

    /// Capture running.
    public static let running = CapturePauseState()

    /// A pause of the given length, starting now.
    public static func paused(_ pause: CapturePause, from now: Date) -> CapturePauseState {
        CapturePauseState(isPaused: true, expiresAt: pause.expiry(from: now))
    }

    /// Whether capture should actually be off at this instant.
    ///
    /// The expiry is *evaluated*, never merely scheduled. A timer would not survive the app
    /// being quit, and somebody who pauses for an hour and reboots must not come back to a Mac
    /// that is still paused, which is exactly the version of this bug that would have been
    /// hardest to notice.
    public func isPaused(at now: Date) -> Bool {
        guard isPaused else { return false }
        guard let expiresAt else { return true }
        return now < expiresAt
    }

    /// The state after any expiry has been honoured. Feeds straight back into the config.
    public func settled(at now: Date) -> CapturePauseState {
        isPaused(at: now) ? self : .running
    }

    /// What the notch says while paused: "Paused · 42m", or just "Paused" when it is off for good.
    ///
    /// Short because it shares a 230-point wing with the mark, and because the number is the
    /// reassurance: a pause that shows its own end is a pause nobody has to remember.
    public func label(at now: Date) -> String? {
        guard isPaused(at: now) else { return nil }
        guard let expiresAt else { return "Paused" }
        let remaining = max(0, expiresAt.timeIntervalSince(now))
        if remaining >= 3_600 {
            let hours = Int((remaining / 3_600).rounded(.up))
            return "Paused · \(hours)h"
        }
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        return "Paused · \(minutes)m"
    }
}
