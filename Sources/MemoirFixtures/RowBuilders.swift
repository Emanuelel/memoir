//
//  RowBuilders.swift
//  Clock-free, UUID-free builders for the three row types that default to both.
//

import Foundation
import MemoirKit

// MARK: - Clock-free row builders

// `Entity`, `Provenance` and `Session` all default `id` to `UUID()` and their timestamps to
// `Date()`. Calling those initialisers directly silently breaks two of this module's rules at
// once. Use these builders instead: every id is derived, every date is injected.

/// An `Entity` with a derived id and injected timestamps.
///
/// - Parameters:
///   - id: explicit id, or nil to derive one from `kind` + `title`. Deriving means the same
///     logical entity built in two tests has the same id, which is usually what you want.
///   - at: used for both `createdAt` and `updatedAt` unless `updatedAt` is given.
///   - completedAt: when a commitment was ticked done. Nil leaves it open.
///   - source: `.inferred` by default, because most fixtures are extraction output. Pass
///     `.authored` for anything the fixture is pretending the user wrote.
///   - aliases: alternate names, as vault frontmatter would supply them.
public func makeEntity(
    id: ID? = nil,
    kind: EntityKind,
    title: String,
    detail: String? = nil,
    dueAt: Date? = nil,
    confidence: Double = 0.5,
    pinned: Bool = false,
    corrected: Bool = false,
    deleted: Bool = false,
    completedAt: Date? = nil,
    source: EntitySource = .inferred,
    aliases: [String] = [],
    provisional: Bool = false,
    at: Date = TestClock.reference,
    updatedAt: Date? = nil
) -> Entity {
    Entity(
        id: id ?? TestID.stable("entity", kind.rawValue, title),
        kind: kind,
        title: title,
        detail: detail,
        dueAt: dueAt,
        confidence: confidence,
        pinned: pinned,
        corrected: corrected,
        deleted: deleted,
        completedAt: completedAt,
        source: source,
        aliases: aliases,
        provisional: provisional,
        createdAt: at,
        updatedAt: updatedAt ?? at
    )
}

/// A `Provenance` row with a derived id and an injected timestamp.
///
/// The entity must already exist in the store when this is written: `entity_id` is a real
/// foreign key.
public func makeProvenance(
    id: ID? = nil,
    entityID: ID,
    captureID: ID,
    field: String = "title",
    snippet: String,
    at: Date = TestClock.reference
) -> Provenance {
    Provenance(
        id: id ?? TestID.stable("prov", entityID, captureID, field, snippet),
        entityID: entityID,
        captureID: captureID,
        field: field,
        snippet: snippet,
        ts: at
    )
}

/// A `Session` with a derived id and injected bounds.
public func makeSession(
    id: ID? = nil,
    appName: String,
    bundleID: String,
    from start: Date,
    to end: Date,
    idle: Bool = false
) -> Session {
    Session(
        id: id ?? TestID.stable("session", bundleID, String(start.timeIntervalSince1970)),
        appBundleID: bundleID,
        appName: appName,
        startedAt: start,
        endedAt: end,
        idle: idle
    )
}

// MARK: - Bulk seeding

/// Writes a prepared world into a real store, in foreign-key-safe order.
///
/// Entities are written before provenance, because `provenance.entity_id` is a real foreign
/// key and an orphan row throws.
///
/// - Parameters:
///   - store: the store to write into.
///   - captures: capture rows.
///   - entities: entity rows.
///   - provenance: provenance rows. Every `entityID` must appear in `entities` or already
///     be in the store.
///   - sessions: session rows.
public func seed(
    store: Store,
    captures: [CaptureEvent] = [],
    entities: [Entity] = [],
    provenance: [Provenance] = [],
    sessions: [Session] = []
) async throws {
    for capture in captures { try await store.insert(capture: capture) }
    for entity in entities { try await store.upsert(entity: entity) }
    for row in provenance { try await store.add(provenance: row) }
    for session in sessions { try await store.upsert(session: session) }
}

/// Deterministic filler captures for the volume flows (CF-19, CF-20).
///
/// Timestamps are spread evenly over `[from, from + spanningDays)`, oldest first:
/// capture *i* lands at `from + i * (spanningDays * 86_400 / count)`. So
/// `makeCaptures(count: 240, spanningDays: 120, from: TestClock.days(-120))` produces 240
/// captures whose oldest is 120 days before the reference and whose newest is half a day
/// before it.
///
/// The text is deliberately inert (lowercase, no names, no dates, no commitment phrasing),
/// so a volume test measures budget and retention rather than accidentally measuring
/// extraction. Each row's text is unique, so nothing dedupes.
///
/// - Parameters:
///   - count: how many captures. Must be positive.
///   - spanningDays: how many days the run covers.
///   - from: timestamp of the oldest capture.
///   - appName: display name stamped on every row.
///   - bundleID: bundle identifier stamped on every row.
public func makeCaptures(
    count: Int,
    spanningDays: Int,
    from: Date = TestClock.reference,
    appName: String = "Filler",
    bundleID: String = "sh.memoir.tests.filler"
) -> [CaptureEvent] {
    guard count > 0 else { return [] }
    let step = Double(spanningDays) * 86_400 / Double(count)
    return (0..<count).map { i in
        let text = "row \(String(format: "%06d", i)) sample screen text for volume testing, pane \(i % 7)"
        return CaptureEvent(
            id: TestID.stable("filler-capture", String(i)),
            ts: from.addingTimeInterval(Double(i) * step),
            appBundleID: bundleID,
            appName: appName,
            windowTitle: "pane \(i % 7)",
            text: text,
            textHash: AccessibilityCapture.textHash(text)
        )
    }
}

/// Deterministic filler entities for the volume flows (CF-19).
///
/// Kinds cycle through `EntityKind.allCases` so the packet builder sees a realistic mix.
/// Commitments (every fourth row) get a `dueAt` spread over the two weeks after `from`,
/// which is what makes "due soon" selection testable. Nothing is pinned unless you ask.
///
/// - Parameters:
///   - count: how many entities.
///   - from: the `createdAt` / `updatedAt` stamp, and the anchor for due dates.
///   - pinnedEvery: pin every n-th entity, or 0 to pin none.
public func makeEntities(count: Int, from: Date = TestClock.reference, pinnedEvery: Int = 0) -> [Entity] {
    guard count > 0 else { return [] }
    let kinds = EntityKind.allCases
    return (0..<count).map { i in
        let kind = kinds[i % kinds.count]
        let due: Date? = kind == .commitment ? from.addingTimeInterval(Double(i % 14) * 86_400) : nil
        return Entity(
            id: TestID.stable("filler-entity", String(i)),
            kind: kind,
            title: "\(kind.rawValue) fixture \(String(format: "%04d", i))",
            detail: "seeded row \(i) for volume testing",
            dueAt: due,
            confidence: 0.4 + Double(i % 5) / 10.0,
            pinned: pinnedEvery > 0 && i % pinnedEvery == 0,
            corrected: false,
            deleted: false,
            createdAt: from,
            updatedAt: from
        )
    }
}
