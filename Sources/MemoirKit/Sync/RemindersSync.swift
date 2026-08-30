//
//  RemindersSync.swift
//  Authored commitments, pushed out to Apple Reminders.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  A deadline you set at the desk should reach you when you are away from it.
//  Memoir has no notification story of its own and is never going to grow one: it is
//  a Mac app that only exists while you are sitting in front of the Mac, which is
//  exactly when a reminder is least useful. Reminders already solves the hard half
//  (a phone in a pocket, a watch on a wrist), so the whole feature is a one-way
//  hand-off into it.
//
//  This does not breach "nothing leaves the machine" (CF-2). EventKit writes to a
//  local database on this Mac. Whether those rows travel is decided by the user's
//  own iCloud account and carried by Apple's own daemon, under credentials Memoir
//  never sees and cannot use. Memoir itself opens no socket, so CF-2's counting
//  URLProtocol stays silent and the test that guards it needs no exception added.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Settings

/// The one thing a user can turn on, persisted in `config.json` alongside everything else.
///
/// A struct rather than a bare `Bool` on `AppConfig` so the default lives next to the code
/// that honours it: `syncToReminders` is false here, false in `RemindersSync.push`, and false
/// in a `config.json` written before this shipped. Three independent places have to agree,
/// and putting the toggle in the same file as the sync is how they stay agreeing.
public struct RemindersConfig: Sendable, Codable, Equatable {

    /// Whether accepted pushes are mirrored into Apple Reminders.
    ///
    /// **Off, and it stays off.** Writing into somebody's task list is not a capability an
    /// app should acquire by being updated, so nothing here flips except a person ticking
    /// the box in Settings.
    public var syncToReminders: Bool = false

    public init(syncToReminders: Bool = false) {
        self.syncToReminders = syncToReminders
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case syncToReminders
    }

    /// Decodes tolerantly, exactly like `VoiceConfig`: a `config.json` written before this
    /// setting existed has no key here, and it must load as off rather than failing the whole
    /// decode and taking the user's exclusion list and hotkey down with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        syncToReminders = try c.decodeIfPresent(Bool.self, forKey: .syncToReminders)
            ?? RemindersConfig().syncToReminders
    }
}

// MARK: - The sink

/// Somewhere a reminder can be written. Implemented for real by ``EventKitSink``.
///
/// The protocol exists so the sync rules can be tested without EventKit, without a
/// reminders permission prompt and without touching the machine's real Reminders
/// database. That is not a testing nicety: the rules below are the part that can hurt
/// a user (a guess showing up in their task list, a duplicate arriving every poll),
/// and rules that can only be exercised behind a TCC prompt do not get exercised.
///
/// Both calls are keyed on `externalID` rather than on whatever identifier the sink
/// hands back, so a caller that has forgotten everything (a relaunch, a new process)
/// can still address a reminder it wrote yesterday.
public protocol ReminderSink: Sendable {

    /// Creates the reminder for `externalID`, or updates it if it already exists.
    ///
    /// - Returns: the sink's own identifier for the row, for diagnostics. Callers must
    ///   not need it to find the reminder again: `externalID` is the durable key.
    func upsert(title: String, dueAt: Date?, externalID: String) async throws -> String

    /// Ticks off the reminder for `externalID`. A no-op when there is no such reminder,
    /// because completing something that was never synced is not an error.
    func complete(externalID: String) async throws

    /// Gets whatever permission writing needs, without writing anything.
    ///
    /// Exists so Settings can walk into the permission wall at the moment the user ticks the
    /// box, which is the one moment they are looking at the thing they would have to go and
    /// fix. Discovering it later, from a todo that quietly never arrived on the phone, is the
    /// failure this whole feature would be judged by.
    func prepareForWriting() async throws
}

extension ReminderSink {
    /// Nothing to ask for. The default, because every sink except the real one is a fake.
    public func prepareForWriting() async throws {}
}

// MARK: - Outcomes

/// What one call to ``RemindersSync/push(_:enabled:)-(Entity,_)`` actually did.
///
/// Every case is a normal return, including the failures. Sync is a courtesy on top of
/// the memory, never a precondition for it, so nothing here is worth throwing over.
public enum ReminderSyncOutcome: Sendable, Equatable {

    /// Written to the sink. Carries the sink's identifier for the row.
    case synced(reminderID: String)

    /// The entity is done and the reminder was ticked off to match.
    case completed

    /// Already in the sink with exactly this title and due date, so nothing was written.
    case unchanged

    /// Deliberately not synced. The reason is the interesting part.
    case skipped(ReminderSkipReason)

    /// The sink refused. The local entity is untouched and a later retry will run again.
    case failed(String)
}

extension ReminderSyncOutcome {

    /// The sentence to put in front of the user, or nil when there is nothing worth saying.
    ///
    /// Every failure message opens by saying the todo is still here. Somebody who reads
    /// "could not reach Reminders" and nothing else has no way to tell whether the thing they
    /// just typed survived, and the answer is always yes: the entity is the product and the
    /// reminder is a copy of it. Getting that order wrong would have a sync problem read as
    /// data loss.
    public var userMessage: String? {
        switch self {
        case .synced:
            return "Added to Reminders."
        case .completed:
            return "Ticked off in Reminders."
        // Nothing happened and nothing needed to. Saying so on every pass would train the
        // user to stop reading this line, which costs the failure case its only channel.
        case .unchanged, .skipped:
            return nil
        case .failed(let reason):
            return "Saved here in Memoir, but not added to Reminders. \(reason)"
        }
    }
}

/// Why an entity was not synced. All of these are correct behaviour, not errors.
public enum ReminderSkipReason: String, Sendable, Equatable, CaseIterable {

    /// The caller did not opt in. This is the default and stays the default.
    case syncDisabled

    /// Memoir inferred this one. Inferences are guesses, and a guess in somebody's task
    /// list is worse than no sync at all: they cannot tell it apart from work they
    /// actually agreed to do, and deleting it is on them.
    case notAuthored

    /// A note or a person is not a task. Only commitments belong in Reminders.
    case notACommitment

    /// Nothing left to title the reminder with.
    case emptyTitle
}

// MARK: - Errors

/// Why a sink could not write. Surfaced through ``ReminderSyncOutcome/failed(_:)``.
///
/// These are user-facing strings: they name the thing to go and fix, because "sync
/// failed" tells somebody nothing they can act on.
public enum ReminderSyncError: Error, Sendable, Equatable {

    /// The user was asked and said no, or has switched Memoir off again since.
    case accessDenied(String)

    /// macOS never asked. Distinct from ``accessDenied(_:)`` on purpose: see
    /// ``RemindersPermissions/failure(granted:status:)`` for why the difference is the whole
    /// difference between an actionable message and a wrong one.
    case notPrompted(String)

    /// EventKit is present but unusable, e.g. there is no list to write into.
    case unavailable(String)

    /// The write itself failed.
    case writeFailed(String)
}

extension ReminderSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accessDenied(let m): return m
        case .notPrompted(let m): return m
        case .unavailable(let m): return m
        case .writeFailed(let m): return "Could not save the reminder: \(m)"
        }
    }
}

// MARK: - Permission

/// Turns the answer macOS gives about Reminders access into the right sentence.
///
/// Deliberately free of every EventKit type, the same way ``VoicePermissions`` is free of
/// `Speech` and `AVFoundation`: the decision below cannot be reproduced in a test that has to
/// go through a real TCC prompt, so the decision is separated from the framework call and the
/// decision is what gets tested.
public enum RemindersPermissions {

    /// One authorization answer, in framework-independent terms.
    public enum Grant: Sendable, Equatable, CaseIterable {
        case granted
        case denied
        case restricted
        /// macOS has no recorded answer for this app. Nobody has said no.
        case notDetermined
    }

    /// Which System Settings pane grants Reminders. Named in every message below, because
    /// "permission denied" without the pane is a dead end.
    public static let pane = "System Settings > Privacy & Security > Reminders"

    /// What to say when macOS returned a refusal it never actually asked about.
    public static let notPromptedMessage =
        "macOS did not ask for Reminders access, so there is nothing yet for you to allow. "
        + "Open \(pane) and switch Memoir on."

    /// What to say when the user was asked and declined.
    public static let deniedMessage =
        "Memoir does not have permission to use Reminders. Turn it on in \(pane)."

    /// What to say when the machine forbids it outright.
    public static let restrictedMessage =
        "Reminders access is blocked on this Mac, so Memoir cannot add anything to it. "
        + "That is usually a Screen Time or device management restriction, not a Memoir setting."

    /// Which error a permission request actually produced, or nil when access was granted.
    ///
    /// **The trap this exists for.** On macOS `requestFullAccessToReminders` can call back
    /// with `granted == false` and `error == nil` having shown the user no prompt at all,
    /// which happens when TCC declines to ask (a rebuilt ad-hoc signature it does not
    /// recognise, a bundle it has no record of). Reading that as "the user said no" produces
    /// the one message guaranteed to waste their time: it tells them to go and un-deny
    /// something they were never offered, and the Reminders pane they open does not even list
    /// Memoir. The authorization status is the tiebreaker, and `.notDetermined` after a refusal
    /// means nobody was ever asked.
    ///
    /// - Parameters:
    ///   - granted: exactly what the request callback handed back.
    ///   - status: the authorization status read *after* the request returned.
    public static func failure(granted: Bool, status: Grant) -> ReminderSyncError? {
        if granted { return nil }
        switch status {
        case .granted:
            // TCC says yes and the callback said no. Not the trap, and not worth a special
            // sentence: the next write retries and will succeed or fail on its own merits.
            return .accessDenied(deniedMessage)
        case .notDetermined:
            return .notPrompted(notPromptedMessage)
        case .restricted:
            return .accessDenied(restrictedMessage)
        case .denied:
            return .accessDenied(deniedMessage)
        }
    }

    /// Opens the Reminders privacy pane, for the button next to the message that names it.
    public static func openPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        else { return }
        #if canImport(AppKit)
        if Thread.isMainThread {
            MainActor.assumeIsolated { _ = NSWorkspace.shared.open(url) }
        } else {
            Task { @MainActor in _ = NSWorkspace.shared.open(url) }
        }
        #endif
    }
}

// MARK: - The sync

/// Pushes authored commitments into a ``ReminderSink``.
///
/// Four rules, in the order they are checked:
///
/// 1. **Off unless asked.** `enabled` defaults to false on every call, so a caller that
///    has not thought about it syncs nothing. Writing into somebody's task list is not
///    a default anyone should acquire by upgrading.
/// 2. **Authored only.** `source == .authored` is the entire admission test. Everything
///    Memoir inferred stays inside Memoir, where it is labelled as a guess and correctable.
/// 3. **Idempotent.** The external id is derived from the entity id, so the same
///    commitment addresses the same reminder forever, across relaunches and across a
///    fresh `RemindersSync`. Nothing here needs to remember anything to be correct.
/// 4. **Failure degrades.** A denied permission, a missing framework or a failed write
///    returns ``ReminderSyncOutcome/failed(_:)``. It never throws into the caller, and
///    it never touches the local entity, because the local memory is the product and
///    the reminder is a copy of it.
public actor RemindersSync {

    private let sink: any ReminderSink

    /// What was last successfully written for an entity, so an unchanged commitment is
    /// not rewritten on every pass.
    ///
    /// Purely an optimisation, and deliberately not persisted: a relaunch forgets and
    /// re-writes once, which is harmless because the sink upserts on a stable key. Only
    /// *successful* writes are recorded, so a failure is always retried rather than
    /// remembered as done.
    private var written: [ID: String] = [:]

    public init(sink: any ReminderSink) {
        self.sink = sink
    }

    /// Syncs one entity.
    ///
    /// - Parameters:
    ///   - entity: the entity to mirror. Only authored commitments are eligible.
    ///   - enabled: the opt-in. False by default, and false does nothing at all.
    /// - Returns: what happened, including the failures.
    ///
    /// Declared `throws` to match the module contract and to leave room for a sink that
    /// one day needs to report cancellation. It does not throw today: every failure the
    /// sink can raise is caught and returned, because a sync error propagating into the
    /// caller's write path is exactly how a user loses a commitment they typed.
    @discardableResult
    public func push(_ entity: Entity, enabled: Bool = false) async throws -> ReminderSyncOutcome {
        guard enabled else { return .skipped(.syncDisabled) }
        guard entity.source == .authored else { return .skipped(.notAuthored) }
        guard entity.kind == .commitment else { return .skipped(.notACommitment) }

        let title = entity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .skipped(.emptyTitle) }

        let externalID = Self.externalID(for: entity)

        // "I did it" is `completed_at` since schema v5 (`MemoryService.completePush`),
        // and a soft delete still counts too: a forgotten todo should not have the
        // phone keep asking about it either. CF-56 makes completion permanent locally;
        // this mirrors it outward.
        if entity.deleted || entity.completedAt != nil {
            do {
                try await sink.complete(externalID: externalID)
                written[entity.id] = Self.fingerprint(of: entity, title: title)
                return .completed
            } catch {
                written[entity.id] = nil
                Log.shared.warn("reminders sync could not complete '\(title)': \(error.localizedDescription)")
                return .failed(error.localizedDescription)
            }
        }

        let fingerprint = Self.fingerprint(of: entity, title: title)
        if written[entity.id] == fingerprint { return .unchanged }

        do {
            let reminderID = try await sink.upsert(title: title, dueAt: entity.dueAt, externalID: externalID)
            written[entity.id] = fingerprint
            return .synced(reminderID: reminderID)
        } catch {
            // Not recorded, so the next pass tries again. A cached failure would look
            // exactly like a successful sync from here on, which is the quiet version of
            // losing the reminder.
            written[entity.id] = nil
            Log.shared.warn("reminders sync could not write '\(title)': \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Syncs a list, one entity at a time, in order.
    ///
    /// One entity's failure never stops the rest: a single malformed row must not cost
    /// the user every other deadline in the batch.
    @discardableResult
    public func push(_ entities: [Entity], enabled: Bool = false) async throws -> [ReminderSyncOutcome] {
        var out: [ReminderSyncOutcome] = []
        out.reserveCapacity(entities.count)
        for entity in entities {
            out.append(try await push(entity, enabled: enabled))
        }
        return out
    }

    /// Asks the sink for whatever permission it needs, ahead of any write.
    ///
    /// - Returns: nil when Memoir can write, or the sentence naming what to go and fix.
    ///
    /// Called from Settings the moment the toggle goes on, so the permission wall is met
    /// while the user is looking at the switch they just flipped. Never throws: a permission
    /// that cannot be got is a state to display, not an error to handle.
    public func prepare() async -> String? {
        do {
            try await sink.prepareForWriting()
            return nil
        } catch {
            Log.shared.warn("reminders access unavailable: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Forgets what was last written for an entity, forcing the next push to write.
    ///
    /// For the case where the reminder changed underneath us: the user deleted it on
    /// their phone, and Memoir's cache still says it is up to date.
    public func forget(_ entityID: ID) {
        written[entityID] = nil
    }

    // MARK: - Keys

    /// Prefix that marks a reminder as one Memoir wrote. Deliberately readable: it ends up
    /// in the notes field of a real reminder, where a person will read it.
    public static let externalIDPrefix = "memoir:"

    /// The durable key for an entity's reminder.
    ///
    /// Derived from the entity id and nothing else, so it survives a retitle and a
    /// rescheduled due date. Keying on the title instead would make every edit create a
    /// second reminder and leave the first one nagging forever.
    public static func externalID(for entity: Entity) -> String {
        externalIDPrefix + entity.id
    }

    /// Everything about an entity a reminder actually shows. Two entities with the same
    /// fingerprint would produce byte-identical reminders.
    private static func fingerprint(of entity: Entity, title: String) -> String {
        let due = entity.dueAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return "\(entity.deleted ? "done" : "open")|\(due)|\(title)"
    }
}

// MARK: - EventKit

#if canImport(EventKit)

import EventKit

extension RemindersSync {
    /// A sync wired to the real Apple Reminders on this Mac.
    ///
    /// Constructing it asks for nothing: `EKEventStore()` touches no permission, and the
    /// prompt only appears on the first ``prepare()`` or the first write. That matters
    /// because the app builds one of these at launch whether or not the user has ever turned
    /// sync on, and a TCC prompt at startup for a feature nobody asked for is how an app gets
    /// dragged to the trash.
    public static func system() -> RemindersSync {
        RemindersSync(sink: EventKitSink())
    }
}

/// The real sink: Apple Reminders, through EventKit.
///
/// Access is requested on first write, never at launch. Memoir is a companion that most
/// people will never turn this on for, and a permission prompt at startup for a feature
/// nobody asked for is how an app gets deleted.
///
/// `@unchecked Sendable` with a lock rather than an `actor`, because `EKEventStore` and
/// `EKReminder` are not `Sendable` and an actor cannot hand them across its own
/// boundaries without the compiler being lied to anyway. The lock covers the one piece
/// of mutable state (whether access has been granted); every EventKit object stays
/// inside the call that made it.
public final class EventKitSink: ReminderSink, @unchecked Sendable {

    private let store = EKEventStore()
    private let lock = NSLock()
    private var hasAccess = false

    public init() {}

    // MARK: ReminderSink

    public func upsert(title: String, dueAt: Date?, externalID: String) async throws -> String {
        try await ensureAccess()

        let reminder: EKReminder
        if let existing = await find(externalID) {
            reminder = existing
        } else {
            let fresh = EKReminder(eventStore: store)
            guard let list = store.defaultCalendarForNewReminders() else {
                throw ReminderSyncError.unavailable(
                    "There is no Reminders list to write to. Open Reminders and create one, then try again."
                )
            }
            fresh.calendar = list
            reminder = fresh
        }

        reminder.title = title

        // Appended, never assigned: the user may have typed their own notes on this
        // reminder from their phone, and overwriting them would be Memoir editing something
        // it did not write.
        let marker = Self.marker(externalID)
        let notes = reminder.notes ?? ""
        if !notes.contains(marker) {
            reminder.notes = notes.isEmpty ? marker : notes + "\n" + marker
        }

        if let dueAt {
            reminder.dueDateComponents = Self.calendar.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueAt
            )
            // A due date on its own does not notify anybody: Reminders only alerts on an
            // alarm. The whole point of this feature is the alert, so one is attached,
            // and only when there is none already, so a user who moved it keeps their
            // version.
            if reminder.alarms?.isEmpty ?? true {
                reminder.addAlarm(EKAlarm(absoluteDate: dueAt))
            }
        } else {
            reminder.dueDateComponents = nil
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ReminderSyncError.writeFailed(error.localizedDescription)
        }
        return reminder.calendarItemIdentifier
    }

    public func complete(externalID: String) async throws {
        try await ensureAccess()
        // Nothing to tick off is a normal outcome, not a failure: the user may have
        // deleted the reminder themselves, or sync may have been off when it was made.
        guard let reminder = await find(externalID), !reminder.isCompleted else { return }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ReminderSyncError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Access

    public func prepareForWriting() async throws {
        try await ensureAccess()
    }

    /// Asks for Reminders access once, and turns every refusal into a sentence naming
    /// the pane the user has to open.
    private func ensureAccess() async throws {
        if lock.withLock({ hasAccess }) { return }

        let granted: Bool
        do {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestFullAccessToReminders { ok, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ok)
                    }
                }
            }
        } catch {
            throw ReminderSyncError.accessDenied(
                "Memoir could not ask for Reminders access: \(error.localizedDescription)"
            )
        }

        // Never `granted ? ok : denied`. macOS answers false with no error and no prompt when
        // TCC declines to ask at all, and calling that a denial sends the user to a pane that
        // does not list Memoir. The status read *after* the request is what tells the two apart.
        if let failure = RemindersPermissions.failure(
            granted: granted,
            status: Self.grant(EKEventStore.authorizationStatus(for: .reminder))
        ) {
            throw failure
        }
        lock.withLock { hasAccess = true }
    }

    /// EventKit's status, in the framework-free terms ``RemindersPermissions`` decides on.
    static func grant(_ status: EKAuthorizationStatus) -> RemindersPermissions.Grant {
        switch status {
        case .fullAccess: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        // Write-only cannot read Memoir's own markers back out of the notes field, and reading
        // them back is the whole of idempotence here: without it every pass would create a
        // second copy of the same todo. Treated as no access rather than as partial access.
        case .writeOnly: return .denied
        @unknown default: return .denied
        }
    }

    // MARK: Lookup

    /// The reminder carrying `externalID` in its notes, or nil.
    ///
    /// EventKit has no field for a caller's own identifier, so the marker lives in the
    /// notes. That is why the marker is written in readable English: it is visible in
    /// the Reminders app and a person will eventually read it.
    ///
    /// Completed reminders are included in the predicate on purpose. Excluding them
    /// would make a re-push of a ticked-off commitment create a second, fresh copy of
    /// something the user already finished.
    private func find(_ externalID: String) async -> EKReminder? {
        let marker = Self.marker(externalID)
        let predicate = store.predicateForReminders(in: nil)

        // Only the identifier crosses back out of the callback. `EKReminder` is not
        // `Sendable`, and the object is re-fetched here rather than captured, which is
        // both what the compiler requires and what EventKit prefers.
        let identifier: String? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let hit = reminders?.first { ($0.notes ?? "").contains(marker) }
                continuation.resume(returning: hit?.calendarItemIdentifier)
            }
        }

        guard let identifier else { return nil }
        return store.calendarItem(withIdentifier: identifier) as? EKReminder
    }

    /// The line Memoir writes into a reminder's notes to recognise it again.
    private static func marker(_ externalID: String) -> String {
        "Kept in sync by Memoir (\(externalID))"
    }

    /// Due dates are resolved in the machine's own timezone, the same frame
    /// `MemoryDateResolver` produced them in. A UTC calendar here would move every
    /// deadline by the user's offset.
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale.current
        c.timeZone = TimeZone.current
        return c
    }
}

#endif
