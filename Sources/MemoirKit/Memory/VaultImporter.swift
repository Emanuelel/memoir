import CryptoKit
import Foundation

/// Reads a folder of markdown (an Obsidian vault, a notes directory) and turns each
/// note into an *authored* entity with provenance.
///
/// This is the answer to two structural weaknesses at once. Extraction is shallow:
/// the vault is an ontology the user already hand-built: project names, aliases,
/// people, how things relate. Cold start is fatal: a memory product has nothing to
/// show on day one, unless the user's own note titles are in it from the first
/// session. Reading the folder fixes both, for free, with no behaviour change asked
/// of anyone.
///
/// Ground rules:
/// - **Read-only.** The importer never writes into the vault. Ever.
/// - **Authored means authored.** Every imported entity carries `source: .authored`
///   and is therefore protected by the merge law from everything that guesses.
/// - **Traceable.** Each note becomes a capture row (app "Vault", the note's title,
///   its text) and the entity's provenance points at it; CF-15 applies to vault
///   entities exactly as to on-screen ones.
/// - **Idempotent.** Same folder, same content, same IDs. Re-importing merges.
public enum VaultImporter {

    /// The pseudo-app vault captures are recorded under.
    public static let bundleID = "sh.memoir.vault"
    public static let appName = "Vault"

    /// What one import pass produced.
    public struct Summary: Sendable, Equatable {
        public let notesRead: Int
        public let entitiesCommitted: Int
        public init(notesRead: Int, entitiesCommitted: Int) {
            self.notesRead = notesRead
            self.entitiesCommitted = entitiesCommitted
        }
    }

    /// One parsed note, before it becomes storage rows.
    struct Note {
        let title: String
        let kind: EntityKind
        let aliases: [String]
        let detail: String?
        let dueAt: Date?
        let body: String
        let relativePath: String
        let modifiedAt: Date
    }

    /// Folders never read: tool internals, trash, and Memoir's own write-back area.
    /// Importing what Memoir wrote would be the vault-shaped version of self-echo.
    /// Compared case-insensitively: macOS filesystems usually are, and "memoir/"
    /// sneaking past a case-sensitive check would read Memoir's own output back in.
    ///
    static let skippedFolders: Set<String> = [".obsidian", ".trash", ".git", "memoir"]

    /// Ceiling on one note's stored text. A vault note is context, not an archive dump.
    static let maxNoteChars = 4_000

    /// Ceiling on notes per pass, applied after sorting by recency. A pathological
    /// folder should degrade to "the most recent 2000 notes", not to a hang.
    static let maxNotes = 2_000

    // MARK: - Scanning

    /// Reads every markdown note under `folder` into captures and an extraction result.
    ///
    /// Pure with respect to the store: the caller inserts the captures and commits the
    /// result through `MemoryService`, which is where the merge laws live.
    static func scan(folder: URL, now: Date) throws -> (captures: [CaptureEvent], result: ExtractionResult) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MemoirError.storage("vault folder does not exist: \(folder.path)")
        }

        var notes: [Note] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            let name = item.lastPathComponent
            if skippedFolders.contains(name.lowercased()) {
                enumerator?.skipDescendants()
                continue
            }
            guard item.pathExtension.lowercased() == "md" else { continue }
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) < 1_048_576,
                  let raw = try? String(contentsOf: item, encoding: .utf8) else { continue }

            let relative = item.path.hasPrefix(folder.path)
                ? String(item.path.dropFirst(folder.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : item.lastPathComponent
            notes.append(parse(
                raw: raw,
                fileName: item.deletingPathExtension().lastPathComponent,
                relativePath: relative,
                parentFolder: item.deletingLastPathComponent().lastPathComponent,
                modifiedAt: values.contentModificationDate ?? now
            ))
        }

        // Most recently edited first: if the ceiling ever bites, it keeps the notes
        // that matter now.
        notes.sort { $0.modifiedAt > $1.modifiedAt }
        if notes.count > maxNotes { notes.removeLast(notes.count - maxNotes) }

        var captures: [CaptureEvent] = []
        var entities: [Entity] = []
        var provenance: [Provenance] = []

        for note in notes {
            let text = String(note.body.prefix(maxNoteChars))
            let contentHash = Self.hash(text)
            // Capture identity is path + content: an edited note is a new observation,
            // an unchanged one re-inserts the same row.
            let captureID = MemoryText.stableID("vaultcap", note.relativePath, contentHash)
            captures.append(CaptureEvent(
                id: captureID,
                ts: note.modifiedAt,
                appBundleID: bundleID,
                appName: appName,
                windowTitle: note.title,
                text: text,
                textHash: contentHash
            ))

            // Entity identity is kind + normalised title, same derivation the
            // extractors use, so a vault note and an on-screen sighting of the same
            // name collide, which is the point.
            let entityID = MemoryText.stableID("entity", note.kind.rawValue, MemoryText.normalizedTitle(note.title))
            entities.append(Entity(
                id: entityID,
                kind: note.kind,
                title: note.title,
                detail: note.detail,
                dueAt: note.dueAt,
                confidence: 0.95,
                source: .authored,
                aliases: note.aliases,
                createdAt: note.modifiedAt,
                updatedAt: note.modifiedAt
            ))
            provenance.append(Provenance(
                id: MemoryText.stableID("prov", entityID, captureID, "title", note.title),
                entityID: entityID,
                captureID: captureID,
                field: "title",
                snippet: MemoryText.truncate(note.detail ?? note.title, max: 240),
                ts: note.modifiedAt
            ))
        }

        return (captures, ExtractionResult(entities: entities, provenance: provenance))
    }

    // MARK: - Parsing

    /// Names a note plainly goes by, inferred from what it is called.
    ///
    /// Conservative on purpose. An alias is a licence to attach on-screen text to this
    /// entity, so a careless one is worse than a missing one: "Notes" as an alias would
    /// swallow half the day. Only three transformations qualify, each of which produces a
    /// name a person would actually type:
    ///
    /// - a daily-note date prefix removed: `2026-07-14 AI companies hiring` → the subject
    /// - the file name when the front-matter title differs from it
    /// - hyphen and underscore separators read as spaces: `vault-inbox-wiring` → the words
    ///
    /// Single short words are dropped: a one-word alias like "test" or "api" matches
    /// everywhere and means nothing.
    static func derivedAliases(title: String, fileName: String) -> [String] {
        var out: [String] = []

        func offer(_ candidate: String) {
            let cleaned = MemoryText.clean(candidate)
            guard cleaned.count >= 6 else { return }
            // Two words, or one long distinctive one. "Hermes Agent Setup" and
            // "quillvox" both qualify; "notes", "todo", "api" do not.
            let words = cleaned.split(separator: " ")
            guard words.count >= 2 || cleaned.count >= 8 else { return }
            guard !MemoryText.queryStopwords.contains(cleaned.lowercased()) else { return }
            out.append(cleaned)
        }

        for name in Set([title, fileName]) {
            // Leading ISO date, the daily-note convention.
            if let range = name.range(of: #"^\d{4}-\d{2}-\d{2}[ _-]+"#, options: .regularExpression) {
                offer(String(name[range.upperBound...]))
            }
            // Separators as spaces, when there are any to convert.
            if name.contains("-") || name.contains("_") {
                offer(name.replacingOccurrences(of: "-", with: " ")
                          .replacingOccurrences(of: "_", with: " "))
            }
        }
        if MemoryText.normalizedTitle(fileName) != MemoryText.normalizedTitle(title) {
            offer(fileName)
        }
        // Order-preserving dedupe, case-insensitive.
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Parses one note: frontmatter, title, kind, aliases, detail, due date.
    static func parse(
        raw: String,
        fileName: String,
        relativePath: String,
        parentFolder: String,
        modifiedAt: Date
    ) -> Note {
        let (frontmatter, body) = splitFrontmatter(raw)

        let title = frontmatter["title"]?.first ?? fileName
        let declared = frontmatter["aliases"] ?? frontmatter["alias"] ?? []
        // Declared aliases first, then the ones the note's own name implies. Measured on
        // a real vault: 36 notes imported, zero with an `aliases:` field. Almost nobody
        // writes one, so reading only that field left the entire matcher with nothing but
        // exact titles to work with, and "hermes" on screen matched no note at all.
        var aliases = declared + derivedAliases(title: title, fileName: fileName)
        aliases = aliases.filter { !$0.isEmpty && $0.lowercased() != title.lowercased() }

        let kind = kindFor(
            declared: frontmatter["type"]?.first ?? frontmatter["kind"]?.first,
            parentFolder: parentFolder
        )

        let dueAt = (frontmatter["due"]?.first ?? frontmatter["deadline"]?.first)
            .flatMap(Self.parseDay)

        return Note(
            title: MemoryText.clean(title),
            kind: kind,
            aliases: aliases.map { MemoryText.clean($0) },
            detail: firstParagraph(of: body),
            dueAt: dueAt,
            body: body,
            relativePath: relativePath,
            modifiedAt: modifiedAt
        )
    }

    /// Splits YAML frontmatter from the body. Supports the two shapes notes actually
    /// use (`key: value` and `key: [a, b]`, plus block lists) and nothing more.
    /// A vault importer with a full YAML parser would be a dependency in disguise.
    static func splitFrontmatter(_ raw: String) -> (fields: [String: [String]], body: String) {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], raw)
        }
        var fields: [String: [String]] = [:]
        var currentKey: String?
        var end = lines.count
        for (index, line) in lines.enumerated().dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { end = index + 1; break }
            if trimmed.hasPrefix("- "), let key = currentKey {
                fields[key, default: []].append(cleanValue(String(trimmed.dropFirst(2))))
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            currentKey = key
            if value.isEmpty { continue }            // block list follows
            if value.hasPrefix("["), value.hasSuffix("]") {
                fields[key] = value.dropFirst().dropLast()
                    .components(separatedBy: ",")
                    .map { cleanValue($0) }
                    .filter { !$0.isEmpty }
            } else {
                fields[key] = [cleanValue(value)]
            }
        }
        let body = lines.dropFirst(end).joined(separator: "\n")
        return (fields, body)
    }

    private static func cleanValue(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// Maps a declared type or a containing folder onto an entity kind.
    static func kindFor(declared: String?, parentFolder: String) -> EntityKind {
        if let declared, let kind = kindSynonyms[declared.lowercased()] { return kind }
        if let kind = kindSynonyms[parentFolder.lowercased()] { return kind }
        return .note
    }

    static let kindSynonyms: [String: EntityKind] = [
        "project": .project, "projects": .project,
        "person": .person, "people": .person, "contact": .person, "contacts": .person,
        "thread": .thread, "threads": .thread,
        "decision": .decision, "decisions": .decision,
        "commitment": .commitment, "commitments": .commitment,
        "task": .commitment, "tasks": .commitment,
        "note": .note, "notes": .note,
    ]

    /// The first real paragraph of a body: not a heading, not a wiki-link line, capped.
    static func firstParagraph(of body: String) -> String? {
        for block in body.components(separatedBy: "\n\n") {
            let flat = MemoryText.clean(block)
            guard !flat.isEmpty, !flat.hasPrefix("#") else { continue }
            return MemoryText.truncate(flat, max: 300)
        }
        return nil
    }

    /// "2026-08-14" and nothing cleverer. Day-granularity resolves to 17:00 local,
    /// the same convention `MemoryDateResolver` uses.
    static func parseDay(_ s: String) -> Date? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = 17
        return Calendar.current.date(from: components)
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// The orchestrating entry point is `MemoryService.importVault(at:now:)`; it lives on
// the service because that is where the store and the merge laws are.
