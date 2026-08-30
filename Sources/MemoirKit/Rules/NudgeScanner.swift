import Foundation

/// Computes nudge candidates from the store and funnels each through the restraint
/// engine. This is the trigger source the engine has been waiting for; the band's
/// transient moment is the delivery surface.
///
/// The scanner decides *what is true* (one app has held the foreground a long time). The
/// engine decides *whether to say it*: thresholds, quiet hours, focus suppression, backoff
/// and caps all stay inside `RestraintEngine`, so the scanner deliberately proposes
/// candidates the engine may well refuse.
public actor NudgeScanner {

    // Commitments used to be scanned here too, and a due one widened the band to say so.
    // That whole channel is gone: Memoir never brings up a commitment on its own. They are
    // still kept, and still listed on the pane that is about them.

    private let store: Store
    private let restraint: RestraintEngine

    public init(store: Store, restraint: RestraintEngine) {
        self.store = store
        self.restraint = restraint
    }

    /// One pass: gather candidates, propose each in turn, return the first
    /// the engine allows through. Returns nil when there is nothing to say, which is
    /// the common case, and the correct one.
    ///
    /// - Parameter now: the instant to evaluate against. Always injected.
    public func scan(now: Date) async -> Nudge? {
        for nudge in await candidates(now: now) {
            if let delivered = await restraint.propose(nudge, now: now) {
                return delivered
            }
        }
        return nil
    }

    /// The candidates a pass would propose. Exposed for tests.
    public func candidates(now: Date) async -> [Nudge] {
        var out: [Nudge] = []

        // A long uninterrupted stretch in one app. The threshold itself lives in the
        // engine (`distractionThresholdMinutes`); the scanner reports the fact and
        // lets rule 1 do the gating, so a threshold change needs no scanner change.
        if let stretch = await currentStretch(now: now) {
            out.append(.distraction(appName: stretch.appName, minutes: stretch.minutes))
        }

        return out
    }

    /// The current contiguous non-idle stretch in the frontmost app, measured from the
    /// session rows: walk back from the most recent session while the app stays the
    /// same and the gaps stay small. Focus sessions are Memoir's own rows, not activity.
    private func currentStretch(now: Date) async -> (appName: String, minutes: Int)? {
        let lookback = now.addingTimeInterval(-4 * 3_600)
        guard let sessions = try? await store.sessions(from: lookback, to: now) else { return nil }

        let usable = sessions
            .filter { !$0.idle && !FocusSession.isFocusRow($0) }
            .sorted { $0.startedAt < $1.startedAt }
        guard let last = usable.last else { return nil }

        // The stretch must still be live: a session that ended a while ago is history.
        guard now.timeIntervalSince(last.endedAt) < 3 * 60 else { return nil }

        var start = last.startedAt
        var cursor = last
        for session in usable.dropLast().reversed() {
            guard session.appBundleID == cursor.appBundleID,
                  cursor.startedAt.timeIntervalSince(session.endedAt) < 2 * 60 else { break }
            start = session.startedAt
            cursor = session
        }

        let minutes = Int(now.timeIntervalSince(start) / 60)
        guard minutes >= 1 else { return nil }
        return (last.appName, minutes)
    }
}
