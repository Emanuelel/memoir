import Foundation

/// One tool's answer in both registers: the markdown a reader gets, and the same
/// answer counted.
///
/// `ToolHandler.call` used to return a `String`, so every number a tool had just
/// computed (how many captures matched, how many apps the time went on, how old
/// the newest row was) was flattened into a sentence and dropped on the floor. A
/// client that wants to show `memoir:recall ✓ 1 capture · 28 days ago` could only
/// get there by parsing the prose back out, which makes the chip hostage to the
/// wording of an answer and breaks every time the wording improves (CF-93).
public struct ToolResult: Sendable {

    /// How the call went, for a client that has to render something other than a tick.
    ///
    /// Four outcomes rather than two, because at the protocol level they are
    /// indistinguishable: a scope refusal, an empty record and an unreadable
    /// database all come back as `isError: false` with prose in the block, and a
    /// chip that only knows "it returned text" ticks all three.
    public enum Status: String, Sendable {
        /// Answered from the record.
        case ok
        /// Looked, and the record carried nothing.
        case empty
        /// Refused before searching: out of scope, or an argument it could not use.
        case declined
        /// The memory itself could not be read.
        case unavailable
    }

    public let status: Status
    /// The markdown, unchanged. Still the whole answer for a text-only client.
    public let text: String
    /// One line, chip-sized: `2 apps · 47 captures`.
    public let summary: String
    /// What the answer is made of. Countables only: durations belong in `summary`.
    public let counts: [String: Int]
    /// Newest and oldest dated row the answer rests on, where it rests on any.
    public let newest: Date?
    /// See ``newest``.
    public let oldest: Date?

    public init(
        status: Status,
        text: String,
        summary: String,
        counts: [String: Int] = [:],
        newest: Date? = nil,
        oldest: Date? = nil
    ) {
        self.status = status
        self.text = text
        // A blank summary renders as a tick with no words next to it, which is
        // worse than no chip at all: the status is at least true.
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = trimmed.isEmpty ? status.rawValue : trimmed
        self.counts = counts
        self.newest = newest
        self.oldest = oldest
    }

    // MARK: - The four outcomes

    /// The record answered.
    public static func answered(
        _ text: String,
        summary: String,
        counts: [String: Int] = [:],
        newest: Date? = nil,
        oldest: Date? = nil
    ) -> ToolResult {
        ToolResult(status: .ok, text: text, summary: summary, counts: counts, newest: newest, oldest: oldest)
    }

    /// It looked and found nothing. Distinct from a refusal: the question was answerable.
    public static func nothing(_ text: String, summary: String) -> ToolResult {
        ToolResult(status: .empty, text: text, summary: summary)
    }

    /// It never searched: the ask is outside what a screen can know, or the
    /// arguments could not be used.
    public static func declined(_ text: String, summary: String) -> ToolResult {
        ToolResult(status: .declined, text: text, summary: summary)
    }

    /// The database could not be read at all.
    public static func unavailable(_ text: String) -> ToolResult {
        ToolResult(status: .unavailable, text: text, summary: "memory not available")
    }

    // MARK: - Rendering

    /// The `structuredContent` half of a `tools/call` result.
    ///
    /// Written to satisfy ``ToolCatalog``'s advertised `outputSchema` exactly: the
    /// spec makes validation a MUST, and a strict client rejects the whole answer
    /// rather than degrading to the text block. So `counts` carries integers and
    /// nothing else, and an unknown timestamp is an absent key, never a null.
    ///
    /// `text` is here, duplicated from the content block, because "structured content
    /// is additive and the markdown is never not there" (CF-94) turned out to be true
    /// of the wire and false of the reader. A client that supports this field renders
    /// it *instead of* the text block, not beside it, so an envelope describing an
    /// answer it does not contain is all the caller ever sees. `recall` came back as
    /// `15 captures · 3 entities` with no captures and no entities in it, and an agent
    /// reading that reports, in Memoir's name, that the record is empty when it is
    /// full. Counting an answer was never meant to cost the answer (CF-104).
    public func structuredContent(tool: String, now: Date = Date()) -> JSONValue {
        var payload: [String: JSONValue] = [
            "tool": .string(tool),
            "status": .string(status.rawValue),
            "summary": .string(summary),
            "text": .string(text),
            "counts": .object(counts.mapValues { .int(max(0, $0)) }),
        ]
        if let newest {
            payload["newest"] = .string(Fmt.iso(newest))
            payload["ageSeconds"] = .int(max(0, Int(now.timeIntervalSince(newest))))
        }
        if let oldest {
            payload["oldest"] = .string(Fmt.iso(oldest))
        }
        return .object(payload)
    }

    // MARK: - Building a summary

    /// `1 capture · 2 entities`, dropping anything that is zero.
    ///
    /// Plurals are supplied rather than derived from the singular: the obvious
    /// rule produces "entitys", and this string is the whole of what a chip shows.
    public static func tally(_ parts: [(count: Int, singular: String, plural: String)]) -> String {
        parts
            .filter { $0.count > 0 }
            .map { "\($0.count) \($0.count == 1 ? $0.singular : $0.plural)" }
            .joined(separator: " · ")
    }

    /// Newest and oldest of a set of timestamps, in the order the envelope names them.
    public static func span(_ dates: [Date]) -> (newest: Date?, oldest: Date?) {
        (dates.max(), dates.min())
    }
}
