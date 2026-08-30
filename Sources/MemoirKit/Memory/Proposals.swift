import CryptoKit
import Foundation

/// A memory an agent wants to record, waiting for the user to say yes.
///
/// Agents act; Memoir remembers; the user decides. `propose_memory` on the MCP server
/// stages one of these to a small JSON file **next to the database, never in it**:
/// the server's read-only guarantee over `memoir.sqlite` (CF-33) survives untouched.
/// The app surfaces pending proposals; only an explicit accept turns one into an
/// entity, and an accepted proposal is *authored*. The acceptance is the act of
/// authorship. Nothing is written without confirmation (CF-51). A rejection deletes
/// the proposal and leaves no trace.
public struct MemoryProposal: Sendable, Codable, Equatable, Identifiable {
    public let id: ID
    /// When the proposal was staged.
    public let ts: Date
    public let kind: EntityKind
    public let title: String
    public let detail: String?
    public let dueAt: Date?
    /// Who staged it, e.g. "mcp". Shown to the user; never trusted for anything else.
    public let origin: String

    public init(
        id: ID = UUID().uuidString.lowercased(),
        ts: Date,
        kind: EntityKind,
        title: String,
        detail: String? = nil,
        dueAt: Date? = nil,
        origin: String
    ) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.title = title
        self.detail = detail
        self.dueAt = dueAt
        self.origin = origin
    }
}

/// The staging file: load, append, remove. One small JSON array on disk.
///
/// Deliberately not a table. The MCP server must never hold a writable handle to
/// the database, and a file the user can open in a text editor is the right level
/// of ceremony for a queue that exists to be reviewed.
public enum ProposalStore {

    /// Ceiling on staged proposals. An agent looping on `propose_memory` should hit
    /// a wall, not fill a disk.
    public static let maxPending = 200

    /// Ceilings on one proposal's text. `propose_memory` clamps at the tool boundary
    /// too; this is the store refusing regardless of who calls it. A "title" the
    /// length of a novel is not a memory, it is a payload.
    public static let maxTitleChars = 200
    public static let maxDetailChars = 2_000

    /// Where proposals live: `proposals.json` next to the given database file.
    public static func url(alongsideDatabase dbPath: URL) -> URL {
        dbPath.deletingLastPathComponent().appendingPathComponent("proposals.json")
    }

    /// Every pending proposal. A missing or unreadable file is an empty queue.
    public static func load(at url: URL) -> [MemoryProposal] {
        guard let data = try? Data(contentsOf: url),
              let list = try? decoder().decode([MemoryProposal].self, from: data) else { return [] }
        return list
    }

    /// Stages one proposal. Throws when the queue is full or the text oversized.
    public static func append(_ proposal: MemoryProposal, at url: URL) throws {
        guard proposal.title.count <= maxTitleChars else {
            throw MemoirError.storage("proposal title exceeds \(maxTitleChars) characters")
        }
        guard (proposal.detail?.count ?? 0) <= maxDetailChars else {
            throw MemoirError.storage("proposal detail exceeds \(maxDetailChars) characters")
        }
        try withLock(on: url) {
            var list = load(at: url)
            // Same title+kind already pending: replace rather than pile up. Removal
            // happens BEFORE the ceiling check, so a full queue still accepts an
            // update to something already in it: the wall is for new entries.
            list.removeAll {
                $0.kind == proposal.kind
                    && $0.title.lowercased() == proposal.title.lowercased()
            }
            guard list.count < maxPending else {
                throw MemoirError.storage("proposal queue is full (\(maxPending) pending); the user has reviewing to do")
            }
            list.append(proposal)
            try write(list, to: url)
        }
    }

    /// Removes one proposal (accept and reject both end here).
    public static func remove(id: ID, at url: URL) throws {
        try withLock(on: url) {
            var list = load(at: url)
            list.removeAll { $0.id == id }
            try write(list, to: url)
        }
    }

    /// Serialises read-modify-write across processes with an advisory `flock`.
    ///
    /// Two writers exist: the MCP server (append) and the app (remove). An
    /// unsynchronised interleave could resurrect a rejected proposal or drop a
    /// staged one. A sidecar lock file keeps the queue file itself atomic-replace.
    private static func withLock<T>(on url: URL, _ body: () throws -> T) throws -> T {
        let lockURL = url.deletingPathExtension().appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else {
            throw MemoirError.storage("cannot open proposals lock at \(lockURL.path)")
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw MemoirError.storage("cannot lock proposals queue")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func write(_ list: [MemoryProposal], to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        try enc.encode(list).write(to: url, options: .atomic)
    }

    private static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return dec
    }
}

extension MemoryService {

    /// Turns an accepted proposal into memory: a capture row for traceability, an
    /// authored entity, provenance connecting them. The one legitimate path from
    /// proposal to entity, and it only ever runs because the user pressed accept.
    @discardableResult
    public func accept(proposal: MemoryProposal, now: Date = Date()) async throws -> ID {
        let text = [proposal.title, proposal.detail].compactMap { $0 }.joined(separator: "\n")
        let capture = CaptureEvent(
            id: MemoryText.stableID("proposalcap", proposal.id),
            ts: proposal.ts,
            appBundleID: "sh.memoir.agent",
            appName: "Agent proposal (\(proposal.origin))",
            windowTitle: proposal.title,
            text: text,
            textHash: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        )
        let entityID = MemoryText.stableID(
            "entity", proposal.kind.rawValue, MemoryText.normalizedTitle(proposal.title)
        )
        let entity = Entity(
            id: entityID,
            kind: proposal.kind,
            title: proposal.title,
            detail: proposal.detail,
            dueAt: proposal.dueAt,
            confidence: 0.9,
            source: .authored,
            createdAt: now,
            updatedAt: now
        )
        let provenance = Provenance(
            id: MemoryText.stableID("prov", entityID, capture.id, "title", proposal.title),
            entityID: entityID,
            captureID: capture.id,
            field: "title",
            snippet: MemoryText.truncate(text, max: 240),
            ts: proposal.ts
        )
        try await storeInsert(capture)
        try await commit(ExtractionResult(entities: [entity], provenance: [provenance]), now: now)
        return entityID
    }
}
