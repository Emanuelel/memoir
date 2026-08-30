import Foundation

public typealias ID = String

// MARK: - Capture

public struct CaptureEvent: Sendable, Codable, Identifiable, Equatable {
    public let id: ID
    public let ts: Date
    public let appBundleID: String
    public let appName: String
    public let windowTitle: String?
    public let text: String
    public let textHash: String

    /// The substantial blocks of ``text`` that were inside the window's bounds when it was
    /// read, or nil when the geometry was never resolved (schema v8).
    ///
    /// A subset of `text`, never anything that is not in it. `nil` and `""` mean different
    /// things: nil is "not known", empty is "nothing substantial was on screen".
    public let visibleText: String?

    /// The calendar date this row belongs to, as `yyyy-MM-dd`, decided at import (schema v10).
    ///
    /// Nil for a screen capture, and correctly so: a screen capture happened at an instant the
    /// user was there for, so `date(ts)` is the right answer and a second one would be a second
    /// truth. An imported row is the opposite — a photo day carries no event time, only a
    /// rendered local midnight — and recomputing its date at read time makes the answer a
    /// function of the reader's timezone. See ``Schema/v10``.
    public let localDay: String?

    public init(
        id: ID = UUID().uuidString.lowercased(),
        ts: Date,
        appBundleID: String,
        appName: String,
        windowTitle: String?,
        text: String,
        textHash: String,
        visibleText: String? = nil,
        localDay: String? = nil
    ) {
        self.id = id
        self.ts = ts
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.text = text
        self.textHash = textHash
        self.visibleText = visibleText
        self.localDay = localDay
    }
}

// MARK: - Entities

public enum EntityKind: String, Sendable, Codable, CaseIterable {
    case person, project, thread, decision, commitment, note
    /// Somewhere the user keeps going back to, from the photo library's coordinates.
    ///
    /// Added with `PhotoImporter`. Safe to add without a migration: the kind column holds the
    /// raw string and `Store.decodeEntity` reads an unrecognised one as `.note`, so a database
    /// written by this build still opens in an older one.
    case place

    public var displayName: String {
        switch self {
        case .person: return "Person"
        case .project: return "Project"
        case .thread: return "Thread"
        case .decision: return "Decision"
        case .commitment: return "Commitment"
        case .note: return "Note"
        case .place: return "Place"
        }
    }
}

/// Where an entity came from, and therefore how much it may be trusted.
///
/// `inferred` is a guess made from text that happened to be on screen. `authored` is
/// something the user said in their own words. The second may never be overwritten,
/// downgraded, or merged away by the first. That is the entire point of PUSH, and it is
/// CF-1's "a user correction is permanent" extended from correction to creation.
public enum EntitySource: String, Sendable, Codable, CaseIterable {
    /// Extracted from a capture. Useful, sometimes wrong, always correctable.
    case inferred
    /// Typed or spoken by the user. Clean by construction.
    case authored

    /// True when this source outranks `other` and must win a merge.
    public func outranks(_ other: EntitySource) -> Bool {
        self == .authored && other == .inferred
    }
}

public struct Entity: Sendable, Codable, Identifiable, Equatable {
    public let id: ID
    public var kind: EntityKind
    public var title: String
    public var detail: String?
    public var dueAt: Date?
    public var confidence: Double
    public var pinned: Bool
    public var corrected: Bool
    public var deleted: Bool
    /// When a commitment was ticked done, or nil while it is open (schema v5).
    ///
    /// Distinct from `deleted` on purpose: a completed todo is still *shown* (struck
    /// through, "Done 16:48") and can be reopened, where a deleted row is gone from
    /// every list. Both are permanent against extraction: no consolidation pass may
    /// resurrect either.
    public var completedAt: Date?
    /// Authored by the user, or inferred by Memoir. See ``EntitySource``.
    public var source: EntitySource
    /// True when Memoir cannot show this was the user's own words rather than something
    /// they merely had on screen. Kept in memory, never asserted: it is not evidence of a
    /// promise, and a memory that invents obligations is worse than one that forgets.
    public var provisional: Bool
    /// Alternate names the same thing goes by ("Fenwick migration", "fenwick", "FEN-42").
    /// Fed by vault frontmatter and used by the ontology matcher to label captures.
    public var aliases: [String]
    /// The day this is *about*, when a human filed it under one (schema v12).
    ///
    /// Non-null only on a journal entry, and that is the point: it is the one marker saying a
    /// person sat down and wrote about a day. See ``Schema/v12`` for what its absence cost.
    public var filedAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = UUID().uuidString.lowercased(),
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
        filedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.dueAt = dueAt
        self.confidence = confidence
        self.pinned = pinned
        self.corrected = corrected
        self.deleted = deleted
        self.completedAt = completedAt
        self.source = source
        self.aliases = aliases
        self.provisional = provisional
        self.filedAt = filedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decodes entities serialised before `completedAt`, `source` or `aliases` existed:
    /// a missing field means the row predates that distinction, and everything old is
    /// inferred and open. Without this an older export fails to load outright.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(ID.self, forKey: .id)
        self.kind = try c.decode(EntityKind.self, forKey: .kind)
        self.title = try c.decode(String.self, forKey: .title)
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail)
        self.dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        self.confidence = try c.decode(Double.self, forKey: .confidence)
        self.pinned = try c.decode(Bool.self, forKey: .pinned)
        self.corrected = try c.decode(Bool.self, forKey: .corrected)
        self.deleted = try c.decode(Bool.self, forKey: .deleted)
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.source = try c.decodeIfPresent(EntitySource.self, forKey: .source) ?? .inferred
        self.aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.provisional = try c.decodeIfPresent(Bool.self, forKey: .provisional) ?? false
        self.filedAt = try c.decodeIfPresent(Date.self, forKey: .filedAt)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// Which pass produced a piece of evidence.
///
/// A bitmask rather than a name, because one row can be found by more than one pass and the
/// answer is *both*, not *whichever wrote last*. Two places would otherwise make it
/// last-writer-wins, and the loser is always the model: `ExtractionResult.merging` drops the
/// second row on a key collision, and `Store.add(provenance:)` used to be `INSERT OR REPLACE`,
/// so the next rules-only consolidation would erase the model's bit from a row they both found.
///
/// `none` is not "unknown extractor", it is **predates attribution**: every row written before
/// schema v9. It gets its own value so the doctor can say "40,000 rows predate attribution, 300
/// are attributed, none of them to the model" rather than the meaningless "0 of 40,300".
public struct ExtractorMask: OptionSet, Sendable, Codable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Written before schema v9. Says nothing about which pass produced it.
    public static let none = ExtractorMask([])
    /// `RuleExtractor`: deterministic, always runs.
    public static let rule = ExtractorMask(rawValue: 1)
    /// `LLMExtractor` via the configured brain's free-text JSON path.
    public static let modelJSON = ExtractorMask(rawValue: 2)
    /// `LLMExtractor` via on-device guided generation.
    public static let modelGuided = ExtractorMask(rawValue: 4)
    /// Read out of a markdown vault.
    public static let vaultImport = ExtractorMask(rawValue: 8)
    /// Typed by the user, or accepted through PUSH.
    public static let authored = ExtractorMask(rawValue: 16)
    /// Contacts, Calendar, Photos.
    public static let lifeImport = ExtractorMask(rawValue: 32)

    /// Either model path. What "did the model pass contribute anything" actually asks.
    public static let anyModel: ExtractorMask = [.modelJSON, .modelGuided]
}

/// How solidly a piece of evidence sits on the screen it came from (schema v11).
///
/// Not every citation is worth the same. A capture is a whole accessibility tree: a window
/// title, whatever was inside the viewport, and often two thousand more characters of
/// navigation, sidebar, footer and comments that were never in front of anybody. Quoting all
/// of it with one voice tells the reader that a match in the title and a match in the footer
/// are the same fact, and they are not.
///
/// Measured on a real vault: across captures where the viewport was known, only about half of
/// the stored characters were inside the window. So roughly half of what could be cited is
/// text the user did not see, and until now nothing said which half a citation came from.
///
/// The grades are deliberately about POSITION, not about confidence. A confidence number would
/// be a guess dressed as arithmetic; where the words were is a fact the capture already knows.
public enum EvidenceStrength: String, Sendable, Codable, CaseIterable {
    /// The window title said it, or it was inside the viewport, or it was in the opening of
    /// the body — the part the matcher itself reads. This is the screen speaking.
    case direct
    /// It appeared deep in a long body, outside the viewport and past the opening. True, and
    /// possibly furniture: a related-links rail, a comment thread, a footer.
    case incidental

    /// What a reader should be told, in as few words as possible.
    public var note: String {
        switch self {
        case .direct: return ""
        case .incidental: return " _(deep in the page)_"
        }
    }
}

public struct Provenance: Sendable, Codable, Identifiable, Equatable {
    public let id: ID
    public let entityID: ID
    public let captureID: ID
    public let field: String
    public let snippet: String
    public let ts: Date
    /// Which pass or passes produced this evidence. See ``ExtractorMask``.
    public var extractor: ExtractorMask
    /// Where on the screen this sat. See ``EvidenceStrength``. Defaults to `direct`, which is
    /// what every row written before schema v11 is read as: the grade did not exist, so the
    /// honest reading of an ungraded row is the one the product already implied.
    public var strength: EvidenceStrength

    public init(
        id: ID = UUID().uuidString.lowercased(),
        entityID: ID,
        captureID: ID,
        field: String,
        snippet: String,
        ts: Date = Date(),
        extractor: ExtractorMask = .none,
        strength: EvidenceStrength = .direct
    ) {
        self.id = id
        self.entityID = entityID
        self.captureID = captureID
        self.field = field
        self.snippet = snippet
        self.ts = ts
        self.extractor = extractor
        self.strength = strength
    }
}

public struct Session: Sendable, Codable, Identifiable, Equatable {
    public let id: ID
    public let appBundleID: String
    public let appName: String
    public var startedAt: Date
    public var endedAt: Date
    public var idle: Bool

    public init(
        id: ID = UUID().uuidString.lowercased(),
        appBundleID: String,
        appName: String,
        startedAt: Date,
        endedAt: Date,
        idle: Bool = false
    ) {
        self.id = id
        self.appBundleID = appBundleID
        self.appName = appName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.idle = idle
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

// MARK: - Brain

public enum BrainKind: String, Sendable, Codable, CaseIterable {
    case appleOnDevice
    /// A model on another machine you own, reached over your own private network.
    ///
    /// A third trust tier, not a rename of the second. No third party sees the request and
    /// there is no account, but the bytes do leave this machine, so it is consented like
    /// cloud and private unlike it.
    case localNetwork
    case anthropicAPI
    case claudeCode
    case rulesOnly

    public var displayName: String {
        switch self {
        case .appleOnDevice: return "On-device (Apple)"
        case .localNetwork: return "Your own machine"
        case .anthropicAPI: return "Anthropic API"
        case .claudeCode: return "Claude Code"
        case .rulesOnly: return "No model"
        }
    }

    /// True when using this brain sends data off the machine.
    public var isCloud: Bool {
        switch self {
        case .anthropicAPI, .claudeCode: return true
        // Not cloud: no third party, no account, no retention. It still leaves the machine,
        // which is why it needs consent of its own rather than riding on this flag. That
        // consent is `BrainConfig.allowLocalNetwork`, enforced in `BrainRouter.isAllowed`.
        // For a while this comment described a guard that did not exist and the brain ran
        // whenever an endpoint was configured; a sentence is not an enforcement point.
        case .localNetwork: return false
        case .appleOnDevice, .rulesOnly: return false
        }
    }
}

public struct BrainAnswer: Sendable, Equatable {
    public let text: String
    public let brain: BrainKind
    public let citedCaptureIDs: [ID]
    public let latency: TimeInterval

    public init(text: String, brain: BrainKind, citedCaptureIDs: [ID] = [], latency: TimeInterval = 0) {
        self.text = text
        self.brain = brain
        self.citedCaptureIDs = citedCaptureIDs
        self.latency = latency
    }
}

public struct ContextPacket: Sendable, Equatable {
    public let summary: String
    public let captureIDs: [ID]
    public let entityIDs: [ID]
    public let approxTokens: Int

    public init(summary: String, captureIDs: [ID] = [], entityIDs: [ID] = [], approxTokens: Int = 0) {
        self.summary = summary
        self.captureIDs = captureIDs
        self.entityIDs = entityIDs
        self.approxTokens = approxTokens
    }

    public static let empty = ContextPacket(summary: "", captureIDs: [], entityIDs: [], approxTokens: 0)
}

// MARK: - Stats

public struct StoreStats: Sendable, Codable, Equatable {
    public let captureCount: Int
    public let entityCount: Int
    public let sessionCount: Int
    public let oldestCapture: Date?
    /// The newest capture on file. How far the record actually reaches, which is not
    /// the same as "now", and the difference is the one thing an answer about recent
    /// activity must never hide.
    public let newestCapture: Date?
    /// The end of the most recent session. Sessions are evidence the product is alive
    /// even when a screen produced no readable text, so freshness is the later of the two.
    public let newestSession: Date?
    public let fileSizeBytes: Int64
    /// Distinct calendar days that produced at least one capture.
    ///
    /// The honest denominator for "how fast is this growing". Wall-clock days since the
    /// oldest capture counts weekends, holidays and the fortnight the app sat quit, and
    /// divides the growth rate down to something reassuring and wrong.
    public let activeDays: Int

    public init(captureCount: Int, entityCount: Int, sessionCount: Int, oldestCapture: Date?, newestCapture: Date? = nil, newestSession: Date? = nil, fileSizeBytes: Int64, activeDays: Int = 0) {
        self.captureCount = captureCount
        self.entityCount = entityCount
        self.sessionCount = sessionCount
        self.oldestCapture = oldestCapture
        self.newestCapture = newestCapture
        self.newestSession = newestSession
        self.fileSizeBytes = fileSizeBytes
        self.activeDays = activeDays
    }

    /// Bytes the database grows per day the user actually works, or nil when there is not
    /// yet enough history to say. Measured, never assumed.
    public var bytesPerActiveDay: Int64? {
        guard activeDays >= 2, fileSizeBytes > 0 else { return nil }
        return fileSizeBytes / Int64(activeDays)
    }
}

// MARK: - Errors

public enum MemoirError: Error, Sendable, Equatable {
    case accessibilityPermissionDenied
    case storage(String)
    case brainUnavailable(BrainKind, String)
    case invalidConfig(String)
}

extension MemoirError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Memoir needs Accessibility permission to read on-screen text."
        case .storage(let m): return "Storage error: \(m)"
        case .brainUnavailable(let k, let m): return "\(k.displayName) unavailable: \(m)"
        case .invalidConfig(let m): return "Invalid configuration: \(m)"
        }
    }
}
