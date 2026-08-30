//
//  WorkingDay.swift
//  One seeded working day, built by the real pipeline.
//

import Foundation
import MemoirKit

/// A day's worth of screen activity, written into a real store and consolidated by the real
/// extractor.
///
/// Anchored to the **local** day containing ``TestClock/reference``, not to a UTC instant.
/// `RulesOnlyBrain.renderToday` and `renderBrief` both cut "today" with
/// `Calendar.current.startOfDay(for:)`, so a UTC anchor would put the seeded captures on the
/// previous or next local day in some timezones and every answer would come back empty.
public enum WorkingDay {

    /// 09:00 on the local day that contains ``TestClock/reference``. Where the day's work starts.
    public static let morning: Date = TestClock.localCalendar.date(
        bySettingHour: 9, minute: 0, second: 0, of: TestClock.reference
    )!

    /// 12:00 on the same local day. Every question asked against this world is asked at this
    /// instant, and it is injected rather than read.
    public static let askedAt: Date = TestClock.localCalendar.date(
        bySettingHour: 12, minute: 0, second: 0, of: TestClock.reference
    )!

    /// Local midnight before ``morning``. The lower bound consolidation and "today" both use.
    public static var dayStart: Date { TestClock.localCalendar.startOfDay(for: askedAt) }

    /// `n` minutes after ``morning``.
    public static func afterMorning(_ minutes: Double) -> Date {
        morning.addingTimeInterval(minutes * 60)
    }

    /// A seeded working day: five real captures, four sessions, and whatever the real rule
    /// extractor made of them.
    public struct World {
        public let store: Store
        public let memory: MemoryService
        public let captures: [CaptureEvent]
        public let sessions: [Session]
        /// Entities the real extraction pipeline committed, read back from the store.
        public let entities: [Entity]

        public init(
            store: Store,
            memory: MemoryService,
            captures: [CaptureEvent],
            sessions: [Session],
            entities: [Entity]
        ) {
            self.store = store
            self.memory = memory
            self.captures = captures
            self.sessions = sessions
            self.entities = entities
        }
    }

    /// Writes one working day into a real store and runs the real consolidation over it.
    ///
    /// Deliberately not a fixture of hand-written entities: an answer test is only meaningful
    /// if the memory being answered from is the memory the product would actually have built.
    ///
    /// - Throws: ``FixtureError/seedProducedNothing(_:)`` when consolidation committed nothing,
    ///   which would leave everything asserted against this world vacuously true. The suite
    ///   used to check that with `#expect`; a throw says the same thing without dragging the
    ///   testing framework into a module the seeder also links.
    public static func seed(into store: Store) async throws -> World {
        let captures = Fixtures.all(startingAt: morning)
        let sessions = [
            makeSession(
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                from: morning, to: afterMorning(45)
            ),
            makeSession(
                appName: "Mail", bundleID: "com.apple.mail",
                from: afterMorning(45), to: afterMorning(70)
            ),
            makeSession(
                appName: "Google Chrome", bundleID: "com.google.Chrome",
                from: afterMorning(70), to: afterMorning(120)
            ),
            makeSession(
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                from: afterMorning(120), to: afterMorning(150), idle: true
            ),
        ]
        try await MemoirFixtures.seed(store: store, captures: captures, sessions: sessions)

        let memory = MemoryService(store: store, extractors: [RuleExtractor()])
        let touched = try await memory.consolidate(since: dayStart, now: askedAt)
        guard touched > 0 else { throw FixtureError.seedProducedNothing("entities") }

        let entities = try await store.entities(kind: nil, includeDeleted: false)
        return World(
            store: store, memory: memory,
            captures: captures, sessions: sessions, entities: entities)
    }
}
