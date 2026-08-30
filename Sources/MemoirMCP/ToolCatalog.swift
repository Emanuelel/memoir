import Foundation
import MemoirKit

/// One MCP tool: its name, its description and its JSON Schemas.
public struct ToolDefinition: Sendable {
    /// Tool name as called by `tools/call`.
    public let name: String
    /// Human/model readable description, shown in `tools/list`.
    public let description: String
    /// JSON Schema for the `arguments` object.
    public let inputSchema: JSONValue
    /// JSON Schema for the `structuredContent` the call returns (CF-93).
    public let outputSchema: JSONValue

    /// The `tools/list` representation.
    public var listEntry: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "outputSchema": outputSchema,
        ])
    }
}

/// The tools Memoir exposes over MCP.
///
/// Eleven are read-only; `propose_memory` stages a suggestion to a review file and
/// still never writes the database. Every answer is markdown and every answer
/// carries provenance: which application the text came from and when it was seen,
/// so the calling agent can cite it instead of asserting it.
public enum ToolCatalog {
    /// Names in the order they are advertised.
    ///
    /// Taken from ``MemoirTools`` rather than written out again here. The same division
    /// (eleven that read, one that stages) decides which tools the installer pre-approves in
    /// a client's allowlist, and two hand-maintained copies of it would drift into a state
    /// where a tool is advertised as read-only in one file and prompted for in the other.
    public static let names = MemoirTools.all

    /// All tool definitions.
    public static let all: [ToolDefinition] = [
        recall, whoIs, whatHappened, openCommitments, today,
        whatChangedSince, priorArt, workingSet, sourcesFor, verify,
        timesheet, proposeMemory, coverage,
    ]

    /// Looks a definition up by name.
    public static func definition(named name: String) -> ToolDefinition? {
        all.first { $0.name == name }
    }

    /// The bounds `recall` advertises for its `limit` argument.
    ///
    /// Declared once and used twice: here, to build the JSON Schema a calling agent
    /// reads, and in `ToolHandler.recall`, to clamp what it actually returns. They
    /// used to be written out separately and had drifted: the schema promised a
    /// default of 10 and a maximum of 50 while the handler used 8 and 40, which
    /// makes the catalogue a lie an agent has no way to detect. CF-31 reads these
    /// values back out of `tools/list` and checks the server obeys them.
    public enum RecallLimit {
        /// Smallest accepted value.
        public static let minimum = 1
        /// Largest accepted value. Anything above is clamped, never rejected.
        public static let maximum = 50
        /// Used when the caller omits `limit`.
        public static let fallback = 10
    }

    private static func schema(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }

    /// The envelope every tool returns beside its markdown.
    ///
    /// One shape for all twelve rather than a payload per tool, because the client
    /// renders them into one chip: a bespoke schema per tool would make that twelve
    /// renderers, and the whole point is that `memoir:recall ✓ 1 capture · 28 days
    /// ago` and `memoir:what_happened ✓ 2 apps · 47 captures` are drawn by the same
    /// code. Only `tool` differs, and it is pinned so a payload that came back from
    /// the wrong handler is caught by the client's own validator rather than
    /// rendered under the wrong name.
    ///
    /// `counts` is left open on purpose: what a tool counts is its own business
    /// (captures, apps, sightings, commitments), and closing it would mean editing
    /// this schema every time a tool learns to count one more thing. The values are
    /// pinned instead, which is what a renderer actually depends on.
    ///
    /// `text` is required for the reason the rest of this envelope exists at all. The
    /// chip needs `summary` and `counts`; the *reader* needs the answer, and a client
    /// that honours `outputSchema` shows this payload in place of the text block. An
    /// envelope without `text` therefore describes an answer nobody receives. That
    /// is not a thin answer, it is a confident wrong one (CF-104).
    private static func resultSchema(for tool: String) -> JSONValue {
        schema(
            properties: [
                "tool": .object([
                    "type": .string("string"),
                    "description": .string("The tool that produced this. Always \"\(tool)\"."),
                    "enum": .array([.string(tool)]),
                ]),
                "status": .object([
                    "type": .string("string"),
                    "description": .string(
                        "ok: answered from the record. empty: looked, found nothing. declined: "
                            + "refused before searching, being outside what a screen can know or an "
                            + "argument it could not use. unavailable: the memory could not be read."
                    ),
                    "enum": .array(["ok", "empty", "declined", "unavailable"].map { .string($0) }),
                ]),
                "summary": .object([
                    "type": .string("string"),
                    "description": .string("One line, chip-sized, e.g. \"2 apps · 47 captures\"."),
                    "minLength": .int(1),
                ]),
                "text": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The answer itself, in markdown, with its provenance: the same content as "
                            + "the text block. Read this, not `summary`: `summary` says how much was "
                            + "found, `text` says what it was."
                    ),
                ]),
                "counts": .object([
                    "type": .string("object"),
                    "description": .string(
                        "What the answer is made of, keyed by what was counted. Durations are not "
                            + "here; they are in `summary`, where they can be read."
                    ),
                    "additionalProperties": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                    ]),
                ]),
                "newest": .object([
                    "type": .string("string"),
                    "description": .string(
                        "ISO-8601 timestamp of the newest dated row the answer rests on. Absent when "
                            + "the answer rests on no dated rows."
                    ),
                ]),
                "oldest": .object([
                    "type": .string("string"),
                    "description": .string("ISO-8601 timestamp of the oldest dated row the answer rests on."),
                ]),
                "ageSeconds": .object([
                    "type": .string("integer"),
                    "description": .string("Seconds between `newest` and the moment the tool answered."),
                    "minimum": .int(0),
                ]),
            ],
            required: ["tool", "status", "summary", "text", "counts"]
        )
    }

    static let recall = ToolDefinition(
        name: "recall",
        description: """
            Search Memoir's memory of the user's working day. Returns entities (people, projects, \
            threads, decisions, commitments, notes) and the raw on-screen captures that match, \
            each with provenance: the application it was seen in, the window title, and the \
            timestamp. Use this for open questions such as "what do we know about the pricing \
            deck". Read-only.
            """,
        inputSchema: schema(
            properties: [
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Words to look for. Multiple words are matched together, then loosened to any-word if nothing matches."),
                    "minLength": .int(1),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Maximum entities and maximum captures to return. Defaults to \(RecallLimit.fallback)."
                    ),
                    "minimum": .int(RecallLimit.minimum),
                    "maximum": .int(RecallLimit.maximum),
                    "default": .int(RecallLimit.fallback),
                ]),
            ],
            required: ["query"]
        ),
        outputSchema: resultSchema(for: "recall")
    )

    static let whoIs = ToolDefinition(
        name: "who_is",
        description: """
            Build a dossier on a person from Memoir's memory: what is known about them, where they \
            were seen (application, window, timestamp), related commitments, projects and threads, \
            and recent captures mentioning them. Falls back to raw captures when no person entity \
            exists yet. Read-only.
            """,
        inputSchema: schema(
            properties: [
                "name": .object([
                    "type": .string("string"),
                    "description": .string("The person's name, or any fragment of it, e.g. \"Ximena\"."),
                    "minLength": .int(1),
                ])
            ],
            required: ["name"]
        ),
        outputSchema: resultSchema(for: "who_is")
    )

    /// How much of a stretch of time Memoir actually watched.
    ///
    /// The denominator for every other answer, and on a real machine it is the answer to more
    /// questions than anything else in the catalogue. Measured over 28 days on the developer's
    /// own vault: Memoir was running for 73 of 672 hours, nothing at all between 1am and 7am,
    /// and not running for 94 to 98 per cent of the 5pm, 6pm and 7pm hours — because the laptop
    /// was shut, which no capture change reaches.
    ///
    /// That makes an honest refusal possible where a vague one is worthless. "I was not running
    /// for 98 per cent of your 5pm hours" tells a reader something. "I do not have enough data"
    /// does not.
    ///
    /// No free-text argument, deliberately. There is no string field on this tool at all, so a
    /// caller cannot point it at a word it brought with it.
    static let coverage = ToolDefinition(
        name: "coverage",
        description: """
            How much of a date range Memoir was actually running, hour by hour: watched hours \
            against wall-clock hours, days with no recording at all, and the split between \
            active, idle and not running for each hour of the day. Ask this BEFORE concluding \
            anything from silence — a quiet evening in the record and an evening Memoir never \
            saw are the same absence, and only this tells them apart. Read-only.
            """,
        inputSchema: schema(
            properties: [
                "from": .object([
                    "type": .string("string"),
                    "description": .string("Start of the range: an ISO date, or `today` / `yesterday`."),
                ]),
                "to": .object([
                    "type": .string("string"),
                    "description": .string("End of the range, inclusive. Defaults to `now`."),
                ]),
            ],
            required: ["from"]
        ),
        outputSchema: resultSchema(for: "coverage")
    )

    static let whatHappened = ToolDefinition(
        name: "what_happened",
        description: """
            Summarise a time range: time spent per application, session and capture counts, the \
            entities created or updated in the range, and sample activity with timestamps. Use it \
            for "what did I do last Tuesday" or "summarise this week". Read-only.
            """,
        inputSchema: schema(
            properties: [
                "from": .object([
                    "type": .string("string"),
                    "description": .string("Start of the range. ISO-8601 date (2026-07-28), full ISO-8601 timestamp (2026-07-28T09:00:00+02:00), or one of now/today/yesterday. A bare date starts at 00:00 local time."),
                ]),
                "to": .object([
                    "type": .string("string"),
                    "description": .string("End of the range, same formats. A bare date ends at 23:59:59 local time."),
                ]),
            ],
            required: ["from", "to"]
        ),
        outputSchema: resultSchema(for: "what_happened")
    )

    static let openCommitments = ToolDefinition(
        name: "open_commitments",
        description: """
            List every open commitment Memoir has extracted, sorted by urgency: overdue first (flagged \
            and quantified), then due soonest, then undated. Each carries its provenance, so the \
            calling agent can quote where the commitment was made. Pass `person` to narrow it to \
            what was promised to, or agreed with, one person: the answer to "what did I tell \
            Marco". Read-only.
            """,
        inputSchema: schema(
            properties: [
                "person": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Optional. Narrow to commitments involving this person, matched against the "
                            + "commitment text and the captures behind it, e.g. \"Marco\"."
                    ),
                    "minLength": .int(1),
                ])
            ],
            required: []
        ),
        outputSchema: resultSchema(for: "open_commitments")
    )

    static let today = ToolDefinition(
        name: "today",
        description: """
            The daily brief: applications used and time spent since midnight local time, \
            commitments due today or overdue, entities that appeared in memory today, and the most \
            recent on-screen activity with timestamps. Read-only.
            """,
        inputSchema: schema(properties: [:], required: []),
        outputSchema: resultSchema(for: "today")
    )

    // MARK: - Substrate tools

    static let whatChangedSince = ToolDefinition(
        name: "what_changed_since",
        description: """
            Everything that changed after a point in time: entities new to memory, entities \
            updated, and where the working time went. Use it to catch up a session that has been \
            away: "what changed since yesterday evening". Read-only.
            """,
        inputSchema: schema(
            properties: [
                "since": .object([
                    "type": .string("string"),
                    "description": .string("The point to diff against. ISO-8601 date or timestamp, or now/today/yesterday."),
                ]),
            ],
            required: ["since"]
        ),
        outputSchema: resultSchema(for: "what_changed_since")
    )

    static let priorArt = ToolDefinition(
        name: "prior_art",
        description: """
            Has the user already been here? Searches the whole retained history for a topic and \
            returns a dated timeline: when it first appeared, when it was last touched, and the \
            evidence in between. Use it before proposing an approach: the user may have already \
            tried it, rejected it, or done it. Read-only.
            """,
        inputSchema: schema(
            properties: [
                "topic": .object([
                    "type": .string("string"),
                    "description": .string("The thing to check for history, e.g. \"reciprocal rank fusion\" or \"stripe webhooks\"."),
                    "minLength": .int(1),
                ]),
            ],
            required: ["topic"]
        ),
        outputSchema: resultSchema(for: "prior_art")
    )

    static let workingSet = ToolDefinition(
        name: "working_set",
        description: """
            What is in play right now: the projects the last hour of work belongs to, the windows \
            and documents recently on screen, and what surfaced in memory today. The fastest way \
            for an agent to load the user's current context. Read-only.
            """,
        inputSchema: schema(properties: [:], required: []),
        outputSchema: resultSchema(for: "working_set")
    )

    static let sourcesFor = ToolDefinition(
        name: "sources_for",
        description: """
            Evidence lookup for a specific claim: returns the on-screen captures whose text \
            supports it, quoted, with application and timestamp, so the calling agent can cite \
            the record instead of asserting from memory. Says plainly when there is no evidence. \
            Read-only.
            """,
        inputSchema: schema(
            properties: [
                "claim": .object([
                    "type": .string("string"),
                    "description": .string("The statement to find sources for, e.g. \"the API moved to v3\"."),
                    "minLength": .int(1),
                ]),
            ],
            required: ["claim"]
        ),
        outputSchema: resultSchema(for: "sources_for")
    )

    static let verify = ToolDefinition(
        name: "verify",
        description: """
            Checks a claim against the record and reports freshness: supported by recent \
            evidence, supported only by stale evidence (with the age), or not in the record at \
            all. Built for keeping OTHER memories honest: a CLAUDE.md line or a vault note has \
            no expiry date; this tool tells you when the screen stopped agreeing with it. \
            Verifies presence in the record, not truth. Read-only.

            CALL THIS before you commit a claim drawn from Memoir to anything durable (a note, \
            a CLAUDE.md line, a commit message, a message to someone else), and before the user \
            acts on one. Memoir cannot check the sentences you write from its rows. This is how \
            you check them yourself. Absence of evidence is reported as absence, never as \
            disproof: capture coverage varies by app, and "not in the record" means Memoir did \
            not see it, not that it did not happen.
            """,
        inputSchema: schema(
            properties: [
                "claim": .object([
                    "type": .string("string"),
                    "description": .string("The statement to check, e.g. \"we use Postgres\"."),
                    "minLength": .int(1),
                ]),
                "freshDays": .object([
                    "type": .string("integer"),
                    "description": .string("How recent evidence must be to count as fresh. Defaults to 14."),
                    "minimum": .int(1),
                    "maximum": .int(365),
                    "default": .int(14),
                ]),
            ],
            required: ["claim"]
        ),
        outputSchema: resultSchema(for: "verify")
    )

    static let timesheet = ToolDefinition(
        name: "timesheet",
        description: """
            A reconstructed timesheet for a date range: per day, per project (real project names \
            where the memory knows them, app names where it does not), with durations measured \
            from session records and the number of captures each attribution rests on. \
            Read-only.
            """,
        inputSchema: schema(
            properties: [
                "from": .object([
                    "type": .string("string"),
                    "description": .string("Start of the range. ISO-8601 date, timestamp, or now/today/yesterday."),
                ]),
                "to": .object([
                    "type": .string("string"),
                    "description": .string("End of the range, same formats."),
                ]),
            ],
            required: ["from", "to"]
        ),
        outputSchema: resultSchema(for: "timesheet")
    )

    static let proposeMemory = ToolDefinition(
        name: "propose_memory",
        description: """
            Stage a memory for the user to review: a decision reached, a commitment made, a \
            fact worth keeping. This does NOT write to Memoir's memory: it appends to a proposals \
            file that the Memoir app shows the user, and only their explicit accept creates the \
            entry. The database stays read-only to this server. Expect proposals to be edited \
            or rejected; do not treat staging as recording.
            """,
        inputSchema: schema(
            properties: [
                "kind": .object([
                    "type": .string("string"),
                    "description": .string("What kind of thing this is."),
                    "enum": .array(EntityKind.allCases.map { .string($0.rawValue) }),
                ]),
                "title": .object([
                    "type": .string("string"),
                    "description": .string("The memory itself, in the user's terms, one line."),
                    "minLength": .int(3),
                ]),
                "detail": .object([
                    "type": .string("string"),
                    "description": .string("Optional supporting detail, a sentence or two."),
                ]),
                "due": .object([
                    "type": .string("string"),
                    "description": .string("Optional due date for commitments, ISO-8601 date (2026-08-14)."),
                ]),
            ],
            required: ["kind", "title"]
        ),
        outputSchema: resultSchema(for: "propose_memory")
    )
}
