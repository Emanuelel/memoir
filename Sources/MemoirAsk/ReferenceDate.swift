import Foundation

// MARK: - Reference date

/// What "now" means for this run, in order of precedence:
///
/// 1. `--now <instant>` on the command line
/// 2. the `MEMOIR_NOW` environment variable
/// 3. nil: the wall clock, which is what a person at a terminal wants
///
/// Both forms for the same reason `--db` has both: the flag for a single question by hand,
/// the variable because `Scripts/eval.sh` drives this binary as a subprocess seventy-eight
/// times and would otherwise thread a flag through every one of them.
///
/// ## Why a fixture run cannot do without this
///
/// A fixture database is a fixed day. Retrieval was already datable (`MemoryService.context`
/// has taken a `now:` since it was written), but the floor underneath it renders "today",
/// "overdue" and "due tomorrow" from `Date()`. Point only retrieval at the fixture and the
/// answer is assembled from March captures and described in August words: *"nothing today"*
/// about a day that is full, *"3 overdue"* about commitments that are not yet due.
///
/// The output still looks deterministic. It passes. It changes on its own the next time a
/// date rolls over, and by then the change that broke it is a week old. That is the failure
/// this exists to prevent, and it is why the reference date reaches `BrainRouter` and
/// `QueryRewriter` as well as `MemoryService`, rather than just the one that took a parameter.
///
/// ## Accepted forms
///
/// - ISO-8601 with a time and a zone: `2026-03-16T12:00:00Z`, `2026-03-16T13:00:00+01:00`
/// - a local wall-clock instant: `2026-03-16 12:00` or `2026-03-16 12:00:00`
///
/// A bare `2026-03-16` is refused on purpose. It would mean local midnight, and midnight is
/// the one instant where every "today" question is honestly empty: a whole eval run of
/// confident, correct, useless zeroes, which is a worse thing to debug than an error message.
func resolveReferenceDate() -> Date? {
    let args = CommandLine.arguments
    var raw = ""
    if let flag = args.firstIndex(of: "--now"), flag + 1 < args.count {
        raw = args[flag + 1]
    } else {
        raw = ProcessInfo.processInfo.environment["MEMOIR_NOW"] ?? ""
    }
    raw = raw.trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }

    if let parsed = parseReferenceDate(raw) { return parsed }

    // Refusing rather than falling back to the wall clock, for the same reason a mistyped
    // `--db` is refused rather than creating an empty database: a run that silently ignored
    // the date it was given would produce exactly the drifting output this flag prevents,
    // and would look like it worked.
    stderrLine("""
    cannot read \(raw) as an instant

    Give a date AND a time:
      --now 2026-03-16T12:00:00Z      ISO-8601, any offset
      --now "2026-03-16 12:00"        local wall clock

    A bare date is refused deliberately: it means local midnight, and at midnight every
    question about "today" is honestly empty, which is a whole run of correct nonsense.
    """)
    exit(1)
}

/// Parses the accepted forms. Nil when the string is none of them.
///
/// Separate from ``resolveReferenceDate()`` so it can be exercised without a process exit.
func parseReferenceDate(_ raw: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: raw) { return date }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: raw) { return date }

    for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) { return date }
    }
    return nil
}
