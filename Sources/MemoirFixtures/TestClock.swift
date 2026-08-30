//
//  TestClock.swift
//  The one clock a seeded world is allowed to read.
//

import Foundation
import MemoirKit

// MARK: - Deterministic time

/// The only clock a seeded world is allowed to read.
///
/// Everything is anchored to ``reference``: **Monday 16 March 2026, 10:00:00 UTC**.
/// The day was chosen because it is a Monday, which makes weekday-relative parsing
/// unambiguous: a bare "Friday" is four days out, "next Monday" is seven, and no
/// expression in the fixtures straddles a week boundary by accident.
///
/// Two calendars are published:
///
/// - ``utcCalendar`` for building and asserting absolute instants. Use it whenever the
///   assertion must hold in every timezone.
/// - ``localCalendar`` for day arithmetic that mirrors what production code does.
///   `MemoryDateResolver`, `RestraintEngine` and `RulesOnlyBrain` all resolve days in
///   `TimeZone.current`, so an expectation about a *resolved* due date must be computed
///   with this calendar rather than hardcoded.
public enum TestClock {

    /// Monday 16 March 2026, 10:00:00 UTC. Epoch 1_773_655_200.
    public static let reference = Date(timeIntervalSince1970: 1_773_655_200)

    /// Gregorian calendar pinned to UTC and `en_US_POSIX`. Timezone independent.
    public static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// Gregorian calendar in the machine's own timezone: what production code uses.
    public static let localCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    // MARK: Offsets

    /// `n` days after ``reference`` (negative for before). Exact 86 400 second days.
    public static func days(_ n: Double, from base: Date = reference) -> Date {
        base.addingTimeInterval(n * 86_400)
    }

    /// `n` hours after ``reference`` (negative for before).
    public static func hours(_ n: Double, from base: Date = reference) -> Date {
        base.addingTimeInterval(n * 3_600)
    }

    /// `n` minutes after ``reference`` (negative for before).
    public static func minutes(_ n: Double, from base: Date = reference) -> Date {
        base.addingTimeInterval(n * 60)
    }

    /// `n` seconds after ``reference`` (negative for before).
    public static func seconds(_ n: Double, from base: Date = reference) -> Date {
        base.addingTimeInterval(n)
    }

    // MARK: Construction and rendering

    /// An absolute instant from UTC calendar components.
    ///
    /// `TestClock.utc(2026, 3, 20, 17, 0)` → 20 March 2026 17:00 UTC.
    public static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute; c.second = 0
        return utcCalendar.date(from: c) ?? reference
    }

    /// An absolute instant from **local** calendar components: the frame production code
    /// resolves relative dates in.
    public static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute; c.second = 0
        return localCalendar.date(from: c) ?? reference
    }

    /// ISO-8601 rendering in UTC, e.g. `"2026-03-16T10:00:00Z"`. For failure messages.
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// True when the two instants fall on the same local day. Use instead of comparing
    /// `Date`s directly when the assertion is about a *day*, not an instant.
    public static func sameLocalDay(_ a: Date, _ b: Date) -> Bool {
        localCalendar.isDate(a, inSameDayAs: b)
    }
}
