import Foundation

/// Something the companion would like to say.
///
/// A `Nudge` is a *request*, never a delivery. It only reaches the user if
/// ``RestraintEngine/propose(_:now:)`` hands it back.
public enum Nudge: Sendable, Equatable, Hashable {

    /// The user has spent a long uninterrupted stretch in one app.
    /// - Parameters:
    ///   - appName: Human readable app name, used for identity and copy.
    ///   - minutes: How long the stretch has run. Checked against `distractionThresholdMinutes`.
    case distraction(appName: String, minutes: Int)

    /// The user has come back to the machine after being idle.
    case idleReturn

    /// The daily brief has finished consolidating and is ready to read.
    case dailySummaryReady

    /// Stable identity used for dismissal backoff.
    ///
    /// Two nudges are "the same nudge" when their keys match. Volatile payload is
    /// deliberately excluded: a distraction is keyed by app only, so that a
    /// dismissed Safari nudge stays dismissed as the minute count keeps climbing.
    public var dedupeKey: String {
        switch self {
        case .distraction(let appName, _):
            return "distraction:\(appName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        case .idleReturn:
            return "idleReturn"
        case .dailySummaryReady:
            return "dailySummaryReady"
        }
    }

    /// Short label for the kind of nudge, without any payload.
    public var kindLabel: String {
        switch self {
        case .distraction: return "distraction"
        case .idleReturn: return "idle return"
        case .dailySummaryReady: return "daily summary"
        }
    }

    /// One line description used in logs and in ``RestraintEngine/debugState()``.
    ///
    /// This is diagnostic copy, not the words the character speaks. Presentation
    /// copy belongs to the UI layer.
    public var summary: String {
        switch self {
        case .distraction(let appName, let minutes):
            return "distraction in \(appName), \(minutes) min"
        case .idleReturn:
            return "idle return"
        case .dailySummaryReady:
            return "daily summary ready"
        }
    }
}

extension Nudge: CustomStringConvertible {
    /// Same text as ``summary``.
    public var description: String { summary }
}
