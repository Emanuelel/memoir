import Foundation
import SQLite3

/// The two numbers the shell shows. Computed against an injected `now`, never the wall
/// clock, so the strip's overdue count is testable at midnight in any timezone.
public struct CommitmentCounts: Sendable, Equatable {
    /// Open commitments whose due date has passed, **that the user actually made**.
    ///
    /// Authored or corrected only. A browser shows you other people's first-person sentences
    /// all day — a marketing email, a reply on a social network, a line in your own draft — and
    /// by text alone none of them is distinguishable from a promise you made. Measured on a
    /// real vault: 39 dated open commitments were counted as overdue and **not one of them was
    /// authored**. The three loudest were a marketing email about a workshop and two sentences
    /// lifted out of the user's own essay, given a due date and shown back as a debt.
    ///
    /// `provisional` was supposed to catch this and only reaches 7 of the 39: it marks the
    /// rows Memoir can see are somebody else's, not the rows it cannot show are yours. Source
    /// is the honest test, and it is the same law the rest of the product runs on.
    public let overdue: Int
    /// Open commitments due later today (not yet overdue). Same authorship rule.
    public let dueToday: Int
    /// Dated, open, inferred commitments — things Memoir found that MIGHT be yours.
    ///
    /// Deliberately a separate number rather than folded into the two above. A guess and a
    /// fact must not wear the same colour, and the fix for a badge full of guesses is to stop
    /// calling them debts, not to hide them: they are still worth a glance and one of them may
    /// be real.
    public let toCheck: Int

    public init(overdue: Int, dueToday: Int, toCheck: Int = 0) {
        self.overdue = overdue
        self.dueToday = dueToday
        self.toCheck = toCheck
    }

    public static let zero = CommitmentCounts(overdue: 0, dueToday: 0, toCheck: 0)
}

/// Todo queries over commitment entities.
///
/// "Open" always means `deleted = 0 AND completed_at IS NULL`. A completed commitment
/// is done permanently: it drops out of every open list and every count, and only
/// ``Store/setCompleted(entityID:at:)`` with nil may bring it back.
extension Store {

    /// Overdue and due-today counts for open commitments.
    ///
    /// - Parameters:
    ///   - now: the instant "overdue" is measured against. Always injected.
    ///   - calendar: decides where "today" ends. Defaults to the user's calendar.
    public func commitmentCounts(now: Date, calendar: Calendar = .current) throws -> CommitmentCounts {
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let mine = "(source = 'authored' OR corrected = 1)"
        let sql = """
        SELECT
            COUNT(CASE WHEN due_at < ?1 AND \(mine) THEN 1 END),
            COUNT(CASE WHEN due_at >= ?1 AND due_at < ?2 AND \(mine) THEN 1 END),
            COUNT(CASE WHEN NOT \(mine) THEN 1 END)
        FROM entities
        WHERE kind = 'commitment' AND deleted = 0 AND completed_at IS NULL AND due_at IS NOT NULL
          AND provisional = 0
        """
        return try withStatement(sql) { stmt in
            try bindDate(stmt, 1, now)
            try bindDate(stmt, 2, endOfDay)
            let rows = try sqlCollect(stmt, sql: sql) { stmt in
                CommitmentCounts(
                    overdue: columnInt(stmt, 0),
                    dueToday: columnInt(stmt, 1),
                    toCheck: columnInt(stmt, 2)
                )
            }
            return rows.first ?? .zero
        }
    }

    /// Every open commitment: overdue first, then soonest due, then dateless by recency.
    ///
    /// This is the Todos pane's read, and it mirrors the ordering `MemoryService.context`
    /// already uses for its "Open commitments" section. The two surfaces must agree.
    public func openCommitments(now: Date) throws -> [Entity] {
        let sql = """
        SELECT \(Schema.entityColumns) FROM entities
        WHERE kind = 'commitment' AND deleted = 0 AND completed_at IS NULL
          AND provisional = 0
        ORDER BY
            CASE WHEN due_at IS NOT NULL AND due_at < ?1 THEN 0
                 WHEN due_at IS NOT NULL THEN 1
                 ELSE 2 END,
            due_at ASC,
            updated_at DESC
        """
        return try withStatement(sql) { stmt in
            try bindDate(stmt, 1, now)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeEntity)
        }
    }

    /// Commitments completed on the local day containing `now`, most recent first.
    /// The Todos pane shows these struck through under the open list.
    public func completedToday(now: Date, calendar: Calendar = .current) throws -> [Entity] {
        let dayStart = calendar.startOfDay(for: now)
        let sql = """
        SELECT \(Schema.entityColumns) FROM entities
        WHERE kind = 'commitment' AND deleted = 0
          AND completed_at IS NOT NULL AND completed_at >= ? AND completed_at < ?
        ORDER BY completed_at DESC
        """
        return try withStatement(sql) { stmt in
            try bindDate(stmt, 1, dayStart)
            try bindDate(stmt, 2, dayStart.addingTimeInterval(86_400))
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeEntity)
        }
    }

    /// Marks an entity done at `at`, or reopens it with nil. Bumps `updated_at`.
    ///
    /// Deliberately a targeted UPDATE rather than an upsert: completion must not
    /// rewrite any other field, so a stale in-memory copy can never clobber a title.
    /// A missing id is a no-op, not an error.
    public func setCompleted(entityID: ID, at: Date?) throws {
        try ensureWritable()
        let sql = "UPDATE entities SET completed_at = ?, updated_at = ? WHERE id = ?"
        try withStatement(sql) { stmt in
            try bindOptionalDate(stmt, 1, at)
            try bindDate(stmt, 2, at ?? Date())
            try bindText(stmt, 3, entityID)
            try sqlStep(stmt, sql: sql)
        }
    }
}
