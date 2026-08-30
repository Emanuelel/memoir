import Foundation

/// Everything Memoir holds, in a format something else can read.
///
/// **Why this exists.** Settings had a prominent "Delete everything" and no way at all to take
/// anything out: no JSON, no CSV, no markdown, no flag, no button. For a product whose pitch
/// is that the memory is *yours* and stays on your machine, that asymmetry says the opposite:
/// leaving is the same act as destroying. The database is right there and a determined user
/// could open it with a SQLite tool, but "you may reverse-engineer our schema" is not data
/// portability, and it is not what someone deciding whether to trust this with a year of their
/// working life is asking about.
///
/// Two formats, because they answer two different questions:
///
/// - ``json(from:)`` is the archive: every entity, every quote of evidence behind it, every
///   capture, every session, losslessly, with the schema version it came from. This is the one
///   to keep, and the one another program can read.
/// - ``markdown(from:)`` is the reading copy: what Memoir believes, grouped, each belief
///   followed by the words it was drawn from. It goes straight into Obsidian or any notes app,
///   which is where a vault user's ontology came from in the first place.
public enum MemoryExport {

    /// The archive's own version, independent of the database schema. Bump it when the shape
    /// below changes in a way a reader would notice.
    public static let formatVersion = 1
    public static let formatName = "memoir.archive"

    /// The top-level object written by ``json(from:)``.
    ///
    /// Deliberately flat lists rather than entities with their provenance nested inside them:
    /// a provenance row points at a capture that may have rolled off under retention, and
    /// nesting would quietly imply the capture is present when it is not. Readers join on
    /// `entityID` and `captureID` and can see for themselves which links still resolve.
    public struct Archive: Codable, Sendable {
        public let format: String
        public let formatVersion: Int
        public let exportedAt: Date
        public let counts: Counts
        public let entities: [Entity]
        public let provenance: [Provenance]
        public let captures: [CaptureEvent]
        public let sessions: [Session]

        public struct Counts: Codable, Sendable {
            public let entities: Int
            public let provenance: Int
            public let captures: Int
            public let sessions: Int
        }
    }

    /// Reads the whole store into an archive.
    ///
    /// Includes entities the user deleted. `deleted: true` is carried through rather than
    /// filtered, because an export that silently drops rows is not an export. A reader that
    /// wants the live view filters on the flag.
    public static func archive(from store: Store, now: Date = Date()) async throws -> Archive {
        let entities = try await store.entities(kind: nil, includeDeleted: true)
        var provenance: [Provenance] = []
        for entity in entities {
            provenance.append(contentsOf: try await store.provenance(entityID: entity.id))
        }
        let captures = try await store.captures(since: .distantPast, limit: 0)
        let sessions = try await store.sessions(from: .distantPast, to: .distantFuture)

        return Archive(
            format: formatName,
            formatVersion: formatVersion,
            exportedAt: now,
            counts: .init(
                entities: entities.count,
                provenance: provenance.count,
                captures: captures.count,
                sessions: sessions.count
            ),
            entities: entities,
            provenance: provenance,
            captures: captures,
            sessions: sessions
        )
    }

    /// The complete archive as JSON.
    public static func json(from store: Store, now: Date = Date()) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(try await archive(from: store, now: now))
    }

    /// What Memoir believes, as a document a person can read.
    ///
    /// Captures are summarised rather than reproduced: the archive already holds them
    /// verbatim, and a markdown file with 3,000 pages of screen text in it is not a reading
    /// copy of anything. What is quoted here is the provenance (the specific words each
    /// belief rests on), because a belief without its evidence is exactly the thing this
    /// product refuses to hand anyone.
    public static func markdown(from store: Store, now: Date = Date()) async throws -> String {
        let archive = try await archive(from: store, now: now)
        let byEntity = Dictionary(grouping: archive.provenance, by: \.entityID)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]

        var out: [String] = [
            "# Memoir memory",
            "",
            "Exported \(stamp.string(from: now)).",
            "",
            "\(archive.counts.entities) things remembered · "
                + "\(archive.counts.captures) captures · "
                + "\(archive.counts.sessions) sessions.",
            "",
            "Each entry says whether you wrote it or Memoir inferred it, and quotes what it "
                + "was drawn from. Anything marked inferred is Memoir's reading of a screen, "
                + "not a record of something you did.",
        ]

        for kind in EntityKind.allCases {
            let group = archive.entities
                .filter { $0.kind == kind && !$0.deleted }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            guard !group.isEmpty else { continue }

            out.append("")
            out.append("## \(kind.displayName)")

            for entity in group {
                out.append("")
                out.append("### \(entity.title)")

                var tags: [String] = [entity.source == .authored ? "yours" : "inferred"]
                if entity.corrected { tags.append("corrected") }
                if entity.pinned { tags.append("pinned") }
                if entity.provisional { tags.append("unconfirmed") }
                if let due = entity.dueAt { tags.append("due \(stamp.string(from: due))") }
                if let done = entity.completedAt { tags.append("done \(stamp.string(from: done))") }
                out.append("*\(tags.joined(separator: " · "))*")

                if let detail = entity.detail, !detail.isEmpty {
                    out.append("")
                    out.append(detail)
                }

                let evidence = (byEntity[entity.id] ?? []).sorted { $0.ts < $1.ts }
                if !evidence.isEmpty {
                    out.append("")
                    out.append("Where this came from:")
                    for record in evidence.prefix(10) {
                        let quote = record.snippet
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        out.append("- \(stamp.string(from: record.ts)): \"\(quote)\"")
                    }
                    if evidence.count > 10 {
                        out.append("- …and \(evidence.count - 10) more, in the JSON archive")
                    }
                }
            }
        }

        out.append("")
        return out.joined(separator: "\n")
    }

    /// Writes an export, choosing the format from the file extension.
    ///
    /// `.md` and `.markdown` produce the reading copy; anything else produces the archive.
    @discardableResult
    public static func write(from store: Store, to url: URL, now: Date = Date()) async throws -> Int {
        let data: Data
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            data = Data(try await markdown(from: store, now: now).utf8)
        default:
            data = try await json(from: store, now: now)
        }
        try data.write(to: url, options: .atomic)
        Log.shared.info("exported memory to \(url.lastPathComponent) (\(data.count) bytes)")
        return data.count
    }
}
