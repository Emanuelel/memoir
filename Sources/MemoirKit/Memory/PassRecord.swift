import Foundation

/// What one deep pass did, written down so that silence is not the only evidence.
///
/// A model pass that fails produces the same thing as a model pass that finds nothing: no new
/// rows. This file exists because that ambiguity has already cost months once: an extractor
/// overflowed its context window on every call and looked exactly like a quiet week. A nightly
/// job on a Mac mini that is asleep would do it again, forever, and nobody would ever see it.
///
/// So the pass reports. `--doctor` reads the last record and says out loud when the deep pass
/// stopped running, and the record carries enough to tell the two silences apart: whether a
/// real model answered at all, how many windows it was asked about, and how many of those it
/// failed. A run of 200 windows with 200 failures and a run of 200 windows finding nothing are
/// different facts, and only one of them is a problem.
public struct PassRecord: Sendable, Codable, Equatable {
    /// When the pass started and when it stopped.
    public let startedAt: Date
    public let finishedAt: Date
    /// How far back it looked.
    public let since: Date
    /// The brain that was asked for, e.g. `localNetwork`. What was *asked for*, not what
    /// answered. ``reachedModel`` is the one that says whether it did.
    public let brain: String
    /// Captures handed to the extractors.
    public let capturesRead: Int
    /// Entities created or materially changed.
    public let entitiesTouched: Int
    /// True when a real model answered at least once.
    ///
    /// False means the pass degraded to the rules, which still writes memories, so the entity
    /// count alone cannot tell you the model never ran. This is the field that catches a
    /// sleeping mini.
    public let reachedModel: Bool
    /// Windows the model pass tried.
    public let windowsAsked: Int
    /// Windows no model could answer. Equal to ``windowsAsked`` means nothing got through.
    public let windowsFailed: Int
    /// Anything worth saying in one line, e.g. why the pass was thin.
    public let note: String?

    public init(
        startedAt: Date,
        finishedAt: Date,
        since: Date,
        brain: String,
        capturesRead: Int,
        entitiesTouched: Int,
        reachedModel: Bool,
        windowsAsked: Int = 0,
        windowsFailed: Int = 0,
        note: String? = nil
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.since = since
        self.brain = brain
        self.capturesRead = capturesRead
        self.entitiesTouched = entitiesTouched
        self.reachedModel = reachedModel
        self.windowsAsked = windowsAsked
        self.windowsFailed = windowsFailed
        self.note = note
    }

    /// How long it took.
    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    /// One line for a human, in the app or in `--doctor`.
    public func summary(now: Date = Date()) -> String {
        let ago = RulesOnlyBrain.formatDuration(now.timeIntervalSince(finishedAt))
        let took = RulesOnlyBrain.formatDuration(duration)
        let model = reachedModel
            ? "\(brain), \(windowsAsked - windowsFailed)/\(windowsAsked) window(s) answered"
            : "\(brain) answered nothing, so rules only"
        return "\(ago) ago, \(capturesRead) capture(s) read, "
            + "\(entitiesTouched) memor\(entitiesTouched == 1 ? "y" : "ies") changed, "
            + "took \(took); \(model)"
    }
}

/// The last few deep passes, as JSON next to the database.
///
/// A file rather than a table, for the same reason proposals are a file: the MCP server holds
/// the database read-only, and a record the user can open in a text editor is the right level
/// of ceremony for something whose whole job is to be checked.
public enum PassRecordStore {

    /// Past this without a successful pass, `--doctor` calls it a problem.
    ///
    /// Two days rather than one. A nightly job that misses a single night because the mini was
    /// updating is not a fault worth alarming about; three nights is.
    public static let staleAfter: TimeInterval = 48 * 3_600

    /// How many runs are kept. Enough to see a pattern, small enough that the file stays a
    /// thing you can read.
    public static let maxKept = 30

    /// Where the log of passes lives: `passes.json` next to the given database file.
    public static func url(alongsideDatabase dbPath: URL) -> URL {
        dbPath.deletingLastPathComponent().appendingPathComponent("passes.json")
    }

    /// Every kept run, oldest first. A missing or unreadable file is no history.
    public static func load(at url: URL) -> [PassRecord] {
        guard let data = try? Data(contentsOf: url),
              let list = try? decoder().decode([PassRecord].self, from: data) else { return [] }
        return list
    }

    /// The most recent run, if there has ever been one.
    public static func latest(at url: URL) -> PassRecord? { load(at: url).last }

    /// The most recent run in which a model actually answered.
    ///
    /// Separate from ``latest(at:)`` because a job that runs every night and reaches nothing
    /// every night has a *fresh* last run and a broken pass, and the freshness would otherwise
    /// hide it.
    public static func latestReachingModel(at url: URL) -> PassRecord? {
        load(at: url).last { $0.reachedModel }
    }

    /// Appends a run, dropping the oldest beyond ``maxKept``.
    public static func append(_ record: PassRecord, at url: URL) throws {
        var list = load(at: url)
        list.append(record)
        if list.count > maxKept { list.removeFirst(list.count - maxKept) }
        try write(list, to: url)
    }

    /// Empties the history. Part of "Delete everything": the record says when the user was at
    /// their computer and how much was on screen, which is Memoir data like any other.
    public static func purge(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func write(_ list: [PassRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(list)
        try data.write(to: url, options: .atomic)
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
