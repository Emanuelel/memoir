import Foundation

/// A repeating daily window during which the companion must never speak.
///
/// The window is expressed in whole local hours and is allowed to wrap across
/// midnight: `start = 22, end = 7` means "quiet from 22:00 until 07:00 the next
/// morning". The window is half open, `[start, end)`, so with `22...7` the hour
/// 22 is quiet and the hour 7 is not.
///
/// Degenerate configurations resolve toward silence, which is the standing bias
/// of the whole Rules module:
///
/// * hours outside `0...23` are wrapped into range (`25` becomes `1`, `-1` becomes `23`)
/// * `start == end` covers the **entire** day rather than none of it
///
/// `debugState()` on ``RestraintEngine`` surfaces both cases in plain language so
/// a user who has silenced the companion by accident can see why.
public struct QuietHours: Sendable, Codable, Equatable, Hashable {

    /// First hour of the quiet window, `0...23` local time. Inclusive.
    public var start: Int

    /// Hour at which the quiet window ends, `0...23` local time. Exclusive.
    public var end: Int

    /// When false the window is ignored entirely and ``contains(_:calendar:)`` is always false.
    public var enabled: Bool

    /// Creates a quiet window.
    /// - Parameters:
    ///   - start: First quiet hour, inclusive. Defaults to 22.
    ///   - end: First hour that is no longer quiet, exclusive. Defaults to 7.
    ///   - enabled: Whether the window applies at all. Defaults to true.
    public init(start: Int = 22, end: Int = 7, enabled: Bool = true) {
        self.start = start
        self.end = end
        self.enabled = enabled
    }

    /// The shipping default: quiet from 22:00 to 07:00.
    public static let `default` = QuietHours()

    /// A window that is switched off. The companion may speak at any hour.
    public static let off = QuietHours(start: 22, end: 7, enabled: false)

    /// A window that silences the companion around the clock.
    public static let allDay = QuietHours(start: 0, end: 0, enabled: true)

    // MARK: - Derived values

    /// ``start`` wrapped into `0...23`.
    public var normalizedStart: Int { Self.normalizeHour(start) }

    /// ``end`` wrapped into `0...23`.
    public var normalizedEnd: Int { Self.normalizeHour(end) }

    /// True when the window runs past midnight, e.g. 22:00 to 07:00.
    public var wrapsMidnight: Bool { normalizedStart > normalizedEnd }

    /// True when the configuration silences every hour of the day.
    ///
    /// This happens when the window is enabled and start and end are the same hour.
    public var coversWholeDay: Bool { enabled && normalizedStart == normalizedEnd }

    /// Number of whole hours the window covers, `0...24`.
    public var lengthInHours: Int {
        guard enabled else { return 0 }
        if normalizedStart == normalizedEnd { return 24 }
        if normalizedStart < normalizedEnd { return normalizedEnd - normalizedStart }
        return 24 - normalizedStart + normalizedEnd
    }

    // MARK: - Membership

    /// Whether the given local hour falls inside the window, ignoring ``enabled``.
    ///
    /// Use this for display and diagnostics. Decision code should call
    /// ``contains(_:calendar:)`` which also honours ``enabled``.
    /// - Parameter hour: An hour of the day. Values outside `0...23` are wrapped.
    /// - Returns: True when the hour is inside the half open window `[start, end)`.
    public func covers(hour: Int) -> Bool {
        let h = Self.normalizeHour(hour)
        let s = normalizedStart
        let e = normalizedEnd
        if s == e { return true }              // degenerate: resolve toward silence
        if s < e { return h >= s && h < e }    // same day window
        return h >= s || h < e                 // window wraps past midnight
    }

    /// Whether the given instant falls inside an enabled quiet window.
    /// - Parameters:
    ///   - date: The instant to test. Always supplied by the caller so the rules stay testable.
    ///   - calendar: Calendar used to resolve the local hour. Defaults to the user's live calendar.
    /// - Returns: True when the companion must stay silent at that instant.
    public func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard enabled else { return false }
        return covers(hour: calendar.component(.hour, from: date))
    }

    // MARK: - Display

    /// The window rendered for the settings screen, for example `"22:00 to 07:00"`.
    public var displayRange: String {
        "\(Self.hourLabel(normalizedStart)) to \(Self.hourLabel(normalizedEnd))"
    }

    /// Formats an hour as a zero padded 24 hour label, for example `"07:00"`.
    public static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", normalizeHour(hour))
    }

    /// Wraps any integer into `0...23`.
    public static func normalizeHour(_ hour: Int) -> Int {
        let m = hour % 24
        return m < 0 ? m + 24 : m
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case start, end, enabled
    }

    /// Lenient decoding: a `config.json` written by an older build may be missing
    /// keys, and a missing key must never crash the app or accidentally unmute it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = QuietHours.default
        self.start = try c.decodeIfPresent(Int.self, forKey: .start) ?? fallback.start
        self.end = try c.decodeIfPresent(Int.self, forKey: .end) ?? fallback.end
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
    }
}
