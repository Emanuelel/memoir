# Memoir: Architecture & Interface Contract

**This file is the contract.** Every module is written against the signatures below. Do not change a public signature without changing it here first.

The product is **Memoir**. It was called Pip until August 2026; `sh.pip.*` bundle ids survive the rename on purpose and must not be "corrected" (see `FLOWS.md`).

---

## What it is

A memory of your own life, held on your own Mac. A small character lives on your screen. Memoir builds the record by reading on-screen *text* through the accessibility system and by importing what you already have (contacts, calendar, photos, your notes vault), structures that into people / places / projects / commitments you can read and correct, and answers questions using either Apple's on-device model, your own API key, or your existing Claude Code. Everything lives in one encrypted container that never leaves the machine. It exposes the memory over MCP so other agents can read it.

**It advises. It never acts on your behalf.**

**`CF-` numbers, throughout this file and the source comments,** are core flows: numbered
behaviours defined in [FLOWS.md](FLOWS.md), each with a stated pass condition and a test that
carries the same ID. `CF-11` in a comment means that code is what makes flow 11 hold, and
`Scripts/verify.sh --flows` prints the table of which are covered.

---

## Hard constraints

1. **Zero third-party dependencies.** Everything is Apple frameworks + system libsqlite3. No SwiftPM dependencies at all. This is non-negotiable: it is what makes the build reliable.
2. **Swift 6 strict concurrency.** Every type crossing an actor boundary is `Sendable`. Use `actor` for mutable shared state.
3. **macOS 15 minimum, macOS 26 features gated at runtime** via `if #available(macOS 26, *)`.
4. **Nothing leaves the machine unless the user picked a cloud brain.** No analytics, no telemetry, no phone-home. Ever.
5. **No screenshots, no OCR, no video.** Capture is text only. The single audio path is *dictation into the ask bar*: the microphone opens only while the bar is listening, transcription is 100% on-device, and no audio or transcript is ever stored or transmitted. If a locale cannot be transcribed on-device, voice reports itself unavailable rather than falling back to a server.
6. **Never blocks the UI.** All capture, storage and inference is off the main actor.

---

## Layout

```
Sources/
  MemoirKit/            # all logic, no UI, unit-testable
    Capture/         # accessibility reads, event-driven
    Storage/         # SQLite
    Memory/          # entities, extraction, retention
    Brain/           # LLM routing
    Rules/           # when the companion may speak
    Voice/           # dictation state machine, no audio, no UI
    Setup/           # wiring the MCP server into the agent clients on this Mac
    Util/            # logging, clock, config
  MemoirApp/            # the app
    UI/              # settings, memory browser, ask bar
    Character/       # the face
    Overlay/         # NSPanel windows + dictation driver
  MemoirMCP/            # stdio MCP server over the same DB
Tests/MemoirKitTests/
Scripts/             # build-app.sh
```

---

## Core value types (`MemoirKit/Util/CoreTypes.swift`): OWNED BY SCAFFOLD, DO NOT REDEFINE

```swift
public typealias ID = String   // UUID string, lowercase

public struct CaptureEvent: Sendable, Codable, Identifiable {
    public let id: ID
    public let ts: Date
    public let appBundleID: String
    public let appName: String
    public let windowTitle: String?
    public let text: String          // deduped, trimmed on-screen text
    public let textHash: String      // sha256 of normalized text, for dedupe
    public let visibleText: String?  // the part that was inside the window (schema v8);
                                     // nil = geometry never read, "" = nothing on screen
}

public enum EntityKind: String, Sendable, Codable, CaseIterable {
    case person, project, thread, decision, commitment, note
}

public struct Entity: Sendable, Codable, Identifiable {
    public let id: ID
    public var kind: EntityKind
    public var title: String
    public var detail: String?
    public var dueAt: Date?          // commitments only
    public var confidence: Double    // 0...1
    public var pinned: Bool
    public var corrected: Bool       // user edited it; never overwrite by extraction
    public var deleted: Bool
    public var completedAt: Date?    // done, visibly and permanently vs extraction (schema v5)
    public var source: EntitySource  // authored beats inferred, always (schema v3)
    public var aliases: [String]     // alternate names, fed by vault frontmatter (schema v6)
    public let createdAt: Date
    public var updatedAt: Date
}

/// Ties an entity field back to the capture it came from. Law: every entity is traceable.
public struct Provenance: Sendable, Codable, Identifiable {
    public let id: ID
    public let entityID: ID
    public let captureID: ID
    public let field: String         // "title", "dueAt", ...
    public let snippet: String       // the exact text it was derived from
    public let ts: Date
}

public struct Session: Sendable, Codable, Identifiable {
    public let id: ID
    public let appBundleID: String
    public let appName: String
    public var startedAt: Date
    public var endedAt: Date
    public var idle: Bool
}

public enum BrainKind: String, Sendable, Codable, CaseIterable {
    case appleOnDevice     // FoundationModels, macOS 26+
    case anthropicAPI      // user's API key
    case claudeCode        // `claude -p` subprocess if installed
    case rulesOnly         // no LLM at all
}

public struct BrainAnswer: Sendable {
    public let text: String
    public let brain: BrainKind      // ALWAYS shown in the UI
    public let citedCaptureIDs: [ID]
    public let latency: TimeInterval
}

public enum MemoirError: Error, Sendable {
    case accessibilityPermissionDenied
    case storage(String)
    case brainUnavailable(BrainKind, String)
    case invalidConfig(String)
}
```

---

## Module contracts

### Capture: `MemoirKit/Capture/`

```swift
public protocol CaptureSource: Sendable {
    func snapshot() async throws -> CaptureEvent?
}

public actor AccessibilityCapture: CaptureSource {
    public init(config: CaptureConfig)
    public func snapshot() async throws -> CaptureEvent?
}

public struct CaptureConfig: Sendable, Codable {
    public var idleThresholdSeconds: Double = 120
    public var excludedBundleIDs: Set<String>   // password managers, banking, etc.
    public var captureWindowTitles: Bool = true // needs Screen Recording; degrade if denied
    public var maxTextLength: Int = 20_000

    // Event-driven capture. None of these five are persisted, deliberately: they are tuning
    // rather than settings, so a changed default reaches an installation that already has a
    // config.json. Nothing in Settings writes to them.
    public var pollIntervalSeconds: Double = 0.25      // how often the CHEAP signals are read
    public var minCaptureIntervalSeconds: Double = 0.2 // hard floor between any two captures
    public var checkpointIntervalSeconds: Double = 1.5 // higher floor for burst-prone triggers
    public var idleCaptureIntervalSeconds: Double = 30 // backstop while the user only reads
    public var typingPauseSeconds: Double = 1.2        // quiet keyboard = typing has stopped

    // A hole in the tick stream this wide splits the session. A constant: ticks arrive a
    // quarter second apart whatever the triggers decide, so 30s means the loop was not
    // running, never "nothing happened".
    public static let sessionGapSeconds: Double = 30
}

public enum CaptureTrigger: String, Sendable, CaseIterable {
    case appSwitch, windowChange, typingPause, idleFallback, resume, manual
}

public struct TriggerDetector: Sendable {
    public mutating func evaluate(_ signals: CaptureSignals, config: CaptureConfig,
                                  now: Date, isFirstTick: Bool) -> CaptureTrigger?
    public mutating func noteCapture(at now: Date)
    public func idleFallbackDue(now: Date, config: CaptureConfig) -> Bool
}

public actor CaptureLoop {
    public init(source: CaptureSource, store: Store, config: CaptureConfig)
    public func start() async
    public func stop() async
    public var isRunning: Bool { get async }
}

public enum Permissions {
    public static func hasAccessibility() -> Bool
    public static func requestAccessibility()          // opens System Settings pane
    public static func hasScreenRecording() -> Bool
}
```

Rules:
- **Capture is event-driven, and there is no capture interval.** The loop ticks every
  `pollIntervalSeconds` and reads only cheap signals on that tick: frontmost app, window title,
  seconds since the last keystroke. A tree walk is paid for only when `TriggerDetector` says one
  of them actually moved — app switch, window change, typing pause — or when the idle backstop
  comes due. The fixed six-second timer this replaced walked the tree whether or not anything
  had changed, which is what filled the context with eight copies of the same page.
- **Nothing user-facing offers to set a capture rate**, because there is no single number that
  would mean anything. Settings → Capture says in words when Memoir reads instead. A stepper
  labelled "Interval" survived the rewrite for a while and reached nothing but session rotation.
- `AXUIElementCreateSystemWide` + `kAXFocusedUIElementAttribute`, walk for `kAXValueAttribute` / `kAXTitleAttribute` / `kAXDescriptionAttribute`. The walk is bounded by `CaptureLimits`: depth 40, 12 000 nodes, 20 000 characters and a wall-clock deadline. The AX tree can be enormous. **Do not lower the depth or node limits.** They started at 12 / 2000, which is far too shallow for a Chromium or Electron tree: the walk came back near-empty, the near-empty text hashed identically every poll, dedupe threw away ~98% of captures and the count froze. Guarded by CF-11.
- Frontmost app via `NSWorkspace.shared.frontmostApplication` (no permission needed).
- Idle via `CGEventSource.secondsSinceLastEventType`: **never** an event tap for idle.
- Skip if bundle ID is excluded. Skip if `textHash` matches the previous capture.
- Never throw on a single failed read; log and return nil.

### Storage: `MemoirKit/Storage/`

```swift
public actor Store {
    public init(path: URL) throws          // creates + migrates
    public static func defaultPath() -> URL // ~/Library/Application Support/Memoir/memoir.sqlite

    public func insert(capture: CaptureEvent) throws
    public func captures(since: Date, limit: Int) throws -> [CaptureEvent]
    public func capture(id: ID) throws -> CaptureEvent?
    public func searchCaptures(_ query: String, limit: Int) throws -> [CaptureEvent]  // FTS5, OR-joined
    /// An exact adjacent phrase. Two words the asker put side by side are a far stronger
    /// signal than the same two words scattered across a page, and OR-search cannot say so.
    public func searchCapturesPhrase(_ phrase: String, limit: Int) throws -> [CaptureEvent]

    public func setEmbedding(captureID: ID, vector: [Float]) throws
    public func allEmbeddings(limit: Int) throws -> [(id: ID, vector: [Float])]
    public func capturesMissingEmbeddings(limit: Int) throws -> [CaptureEvent]

    /// Never demotes `source` from authored to inferred: enforced in the SQL itself, not
    /// only in `MemoryMerge`, because the store is the last line.
    public func upsert(entity: Entity) throws
    public func entities(kind: EntityKind?, includeDeleted: Bool) throws -> [Entity]
    public func entity(id: ID) throws -> Entity?
    public func deleteEntity(id: ID) throws          // soft delete
    public func searchEntities(_ query: String, limit: Int) throws -> [Entity]
    /// Exact match on title OR alias, case-insensitively. `entities_fts` indexes title and
    /// detail only, so aliases are invisible to `searchEntities`. This is the lookup that
    /// reaches them. Exact, never substring: an alias is a three-letter token.
    public func entitiesNamed(_ name: String, limit: Int) throws -> [Entity]

    public func add(provenance: Provenance) throws
    public func provenance(entityID: ID) throws -> [Provenance]
    /// Provenance with each row resolved against its capture. A capture that retention
    /// removed resolves to `.expired`: never a throw, never a dangling reference.
    public func evidence(entityID: ID) throws -> [ProvenanceRecord]

    public func upsert(session: Session) throws
    public func sessions(from: Date, to: Date) throws -> [Session]

    // Todos (Store+Todos.swift). "Open" means deleted = 0 AND completed_at IS NULL.
    public func commitmentCounts(now: Date, calendar: Calendar) throws -> CommitmentCounts
    public func openCommitments(now: Date) throws -> [Entity]   // overdue, then due, then dateless
    public func completedToday(now: Date, calendar: Calendar) throws -> [Entity]
    public func setCompleted(entityID: ID, at: Date?) throws    // nil reopens

    public func purgeCaptures(olderThan: Date) throws -> Int
    public func purgeEverything() throws
    public func stats() throws -> StoreStats
    /// Per-app coverage over a trailing window, computed at read time from
    /// sessions + captures, deliberately not a table, so it can never drift.
    public func captureQuality(since: Date) throws -> [AppCaptureQuality]
}

public struct AppCaptureQuality: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let appName: String
    public let activeSeconds: TimeInterval
    public let captureCount: Int
    public let capturedChars: Int
    public let titledShare: Double
    public let lastCapture: Date?
    public var charsPerActiveMinute: Double { get }
    public var grade: CaptureGrade { get }   // nothing / poor / partial / good / unknown
}

public struct CommitmentCounts: Sendable, Equatable {
    public let overdue: Int
    public let dueToday: Int
}

public struct StoreStats: Sendable, Codable {
    public let captureCount: Int
    public let entityCount: Int
    public let sessionCount: Int
    public let oldestCapture: Date?
    public let fileSizeBytes: Int64
}
```

Rules:
- Raw sqlite3 C API. WAL mode. `PRAGMA foreign_keys=ON`.
- Schema versioned in `user_version`; migrations are additive and idempotent, with one
  documented exception: `ALTER TABLE ... ADD COLUMN` has no `IF NOT EXISTS`, so the v3 `source`
  and v5 `completed_at` migrations rely on two mechanisms instead. Each step runs inside
  `BEGIN IMMEDIATE` with its own `user_version` bump (a crash rolls back and replays cleanly),
  and `migrate` runs statement-by-statement, treating "duplicate column" on a replay as
  "already applied" (CF-7b winds the version back and replays the final step on purpose).
- **Authored beats inferred.** `entities.source` distinguishes what the user typed from what Memoir
  guessed. Nothing that guesses may overwrite something authored.
- **Completed stays completed.** `entities.completed_at` (v5) is the visible, reopenable "done":
  the row is shown struck through, drops out of every open list and count, and no extraction
  pass may resurrect it. It is the same law as the soft delete, one shade gentler.
- FTS5 virtual table over `captures.text` and over `entities.title || entities.detail`.
- **Retention is two-tier:** entities persist forever and are only ever *soft* deleted; captures
  roll off only if the user asks for it. `AppConfig.retentionDays` defaults to **0**, which means
  no expiry: keep everything. Imported history is exempt from the sweep at any setting
  (`Store.purgeCaptures`), because those rows are dated by when the thing happened rather than by
  when Memoir read them, so a timestamp sweep would delete the decade the import exists to provide.

### Memory: `MemoirKit/Memory/`

```swift
public struct ExtractionResult: Sendable {
    public let entities: [Entity]
    public let provenance: [Provenance]
}

public protocol Extractor: Sendable {
    func extract(from captures: [CaptureEvent]) async throws -> ExtractionResult
}

/// Always runs. Zero-cost, deterministic, no model.
public struct RuleExtractor: Extractor {
    public init()
}

/// Runs only if a brain is available. Merges on top of rule output.
public struct LLMExtractor: Extractor {
    public init(brain: any Brain)
}

public actor MemoryService {
    public init(store: Store, extractors: [any Extractor])
    public func consolidate(since: Date) async throws -> Int   // returns entities touched
    /// Builds the packet handed to a brain. Hard token budget.
    public func context(for question: String, budget: Int) async throws -> ContextPacket
    public func applyRetention(captureDays: Int) async throws -> Int

    // The ontology layer: what the work was about, not just where it happened.
    public func workSpans(from: Date, to: Date) async throws -> [WorkSpan]
    public func timesheet(from: Date, to: Date) async throws -> Timesheet
    public func weeklyReview(from: Date, to: Date, now: Date) async throws -> String

    // Authored memory. All three commit through the same merge laws.
    public func importVault(at folder: URL, now: Date) async throws -> VaultImporter.Summary
    public func dailyNoteDraft(for day: Date, now: Date) async throws -> String
    public func accept(proposal: MemoryProposal, now: Date) async throws -> ID
}

/// Labels captures with names the memory already knows (titles + aliases, authored
/// first, longest first, camelCase split on the haystack). Pure; built per pass.
public struct Ontology: Sendable {
    public static func build(from entities: [Entity]) -> Ontology
    public func match(windowTitle: String?, text: String) -> Match?
}

/// Ranking signals between search and the context packet. Pure; no store, no clock of
/// its own: `now` is always injected.
///
/// Entity linking is the third retrieval signal, alongside keyword and semantic: the
/// question resolves to entities, and their OTHER names are searched for in the capture
/// stream. It is the only signal that can cross a rename.
///
/// Temporal decay lands on ENTITIES and deliberately not on captures. An entity is a
/// standing belief and goes stale; a capture is a timestamped event, and "old" is what
/// most recall questions are actually asking for.
public enum MemoryRank {
    /// Alternate names for these entities that the question did not already use. Names
    /// the asker typed are dropped: keyword search has already searched them, and
    /// re-searching would stack four copies of one signal into the fusion.
    public static func linkedNames(for: [Entity], question: String, limit: Int) -> [String]

    /// 1.5 at zero age, floors at 0.3 near seven weeks, crosses 1.0 near a fortnight.
    /// Authored / corrected / pinned entities sit at the 1.5 ceiling forever, so
    /// freshness can never overtake authorship. Only a better search rank can.
    /// A completed commitment floors immediately.
    public static func recencyWeight(for: Entity, now: Date) -> Double

    /// Reciprocal rank (as `MemoryService.reciprocalRankFusion`) times `recencyWeight`.
    public static func byRelevanceAndRecency(_: [Entity], now: Date, k: Double) -> [Entity]
}

/// One contiguous stretch of work on one thing, across apps.
public struct WorkSpan: Sendable, Equatable {
    public let label: String        // entity title, or app name for unlabelled time
    public let entityID: ID?        // nil == app fallback, no project claim
    public let start: Date
    public let end: Date
    public let seconds: TimeInterval
    public let apps: [String]
    public let captureIDs: [ID]     // the evidence the attribution rests on
}

public enum WorkSpanBuilder {   // pure: sessions + captures + ontology → spans
    public static func spans(sessions: [Session], captures: [CaptureEvent],
                             ontology: Ontology, mergeGap: TimeInterval,
                             minimumSpanSeconds: TimeInterval) -> [WorkSpan]
}

/// Per-day, per-thing reconstruction with evidence. `TimesheetBuilder.markdown`
/// renders it; `ReviewBuilder.markdown` assembles the weekly review.
public struct Timesheet: Sendable, Equatable {
    public struct Line: Sendable, Equatable { /* day, label, entityID?, seconds, apps, captureIDs */ }
    public let from: Date
    public let to: Date
    public let lines: [Line]
    public var totalSeconds: TimeInterval { get }
}

/// Reads a markdown folder as authored entities. Read-only against the vault, ever.
/// Notes become captures (app "Vault") so CF-15 traceability holds; frontmatter
/// aliases feed the ontology; `Memoir/`, `.obsidian`, `.trash`, `.git` are never read.
public enum VaultImporter {
    public struct Summary: Sendable, Equatable { public let notesRead: Int; public let entitiesCommitted: Int }
    public static let bundleID: String   // "sh.memoir.vault"
}

/// The one write path into the vault: an accepted draft, into `<vault>/Memoir/` only.
public enum VaultWriteBack {
    public static let folderName: String  // "Memoir", also excluded from import
    public static func dailyNoteURL(vaultRoot: URL, day: Date, calendar: Calendar) -> URL
    public static func write(draft: String, vaultRoot: URL, day: Date, calendar: Calendar) throws -> URL
}

/// A memory an agent staged, waiting for the user to say yes. Lives in
/// `proposals.json` beside the database, never in it (CF-33, CF-51).
public struct MemoryProposal: Sendable, Codable, Equatable, Identifiable {
    public let id: ID
    public let ts: Date
    public let kind: EntityKind
    public let title: String
    public let detail: String?
    public let dueAt: Date?
    public let origin: String
}

public enum ProposalStore {
    public static func url(alongsideDatabase dbPath: URL) -> URL
    public static func load(at url: URL) -> [MemoryProposal]
    public static func append(_ proposal: MemoryProposal, at url: URL) throws
    public static func remove(id: ID, at url: URL) throws
}

/// One piece of evidence for an entity, with whatever is left of where it came from.
/// Captures roll off; the snippet and this record do not.
public enum ProvenanceSource: Sendable, Equatable {
    case available(CaptureEvent)
    case expired
}

public struct ProvenanceRecord: Sendable, Equatable, Identifiable {
    public let provenance: Provenance
    public let source: ProvenanceSource
    public var snippet: String            // always present
    public var isSourceExpired: Bool
    public var sourceDescription: String  // "Slack · #eng-platform" or "Source expired"
}

public struct ContextPacket: Sendable {
    public let summary: String          // rendered text handed to the model
    public let captureIDs: [ID]         // for citation
    public let entityIDs: [ID]
    public let approxTokens: Int
}
```

Rules:
- **Never overwrite an entity whose `corrected == true`.** User corrections are permanent.
- **An inferred candidate never merges over an authored entity.** Same protection, extended
  from edit to creation. An authored candidate colliding with an inferred entity *adopts*
  it: identity and provenance survive, the user's words replace the guess. Authored over
  authored: the vault file is canon.
- Reconciliation matches on kind + normalised title **and aliases, both directions**: an
  extractor seeing "fenwick" corroborates the authored "Fenwick Migration" instead of
  minting a twin.
- Rule extractor handles: commitment phrasing ("I'll…", "can you…", "by Friday", "before the call"), dates, @mentions, capitalised recurring proper nouns, URLs, ticket keys (`ABC-123`).
- Entity dedupe by normalized title + kind. Merge raises confidence, never silently changes a title.

### Brain: `MemoirKit/Brain/`

```swift
public protocol Brain: Sendable {
    var kind: BrainKind { get }
    func isAvailable() async -> Bool
    func answer(question: String, context: ContextPacket) async throws -> BrainAnswer
    func complete(prompt: String, maxTokens: Int) async throws -> String
}

public struct AppleOnDeviceBrain: Brain { public init() }   // FoundationModels, macOS 26+
public struct AnthropicBrain: Brain { public init(apiKey: String, model: String) }
public struct ClaudeCodeBrain: Brain { public init(binaryPath: String?) }  // `claude -p`
public struct RulesOnlyBrain: Brain { public init(store: Store) }          // template answers

public actor BrainRouter {
    public init(preferred: BrainKind, store: Store, config: BrainConfig)
    public func current() async -> BrainKind
    public func setPreferred(_ kind: BrainKind) async
    /// Falls back down the chain if the preferred brain is unavailable.
    public func answer(question: String, context: ContextPacket) async throws -> BrainAnswer
    public func available() async -> [BrainKind]
}

public struct BrainConfig: Sendable, Codable {
    public var anthropicAPIKey: String?     // stored in Keychain, never in the DB
    public var anthropicModel: String = "claude-sonnet-5"
    public var claudeCodePath: String?
    public var allowCloud: Bool = false     // explicit opt-in, default OFF
}
```

Rules:
- **`allowCloud` defaults to false.** A cloud brain is never used without an explicit toggle.
- API key lives in Keychain (`Security` framework), never in SQLite, never in UserDefaults.
- Every answer carries its `BrainKind` and the UI must display it.
- Fallback order: preferred → appleOnDevice → rulesOnly. Never silently fall back *to* a cloud brain.

### Rules: `MemoirKit/Rules/`

```swift
public struct QuietHours: Sendable, Codable {
    public var start: Int   // hour 0-23
    public var end: Int
    public var enabled: Bool
}

public enum Nudge: Sendable, Equatable {
    // There was a `commitmentDue` case. Memoir never raises a commitment on its own now.
    case distraction(appName: String, minutes: Int)
    case idleReturn
    case dailySummaryReady
}

public actor RestraintEngine {
    public init(config: RestraintConfig)
    /// The ONLY way a nudge reaches the user. Returns nil when it must stay quiet.
    public func propose(_ nudge: Nudge, now: Date) async -> Nudge?
    public func setFocusMode(_ on: Bool) async
    public func recordDismissal(_ nudge: Nudge, now: Date) async
}

public struct RestraintConfig: Sendable, Codable {
    public var quietHours: QuietHours
    public var cooldownSeconds: Double = 900      // 15 min between any two nudges
    public var maxNudgesPerDay: Int = 8
    public var suppressDuringFocus: Bool = true
    public var distractionThresholdMinutes: Int = 11
}
```

**This module is the product.** An annoying companion gets deleted in a week. Bias every ambiguous case toward silence.

### Character: `MemoirApp/Character/`

```swift
public enum Expression: String, Sendable, CaseIterable {
    case idle, happy, thinking, sleepy, alert, celebrate, concerned, wink
}

@MainActor public final class CharacterModel: ObservableObject {
    @Published public private(set) var expression: Expression
    @Published public private(set) var speech: String?
    public func set(_ e: Expression, for duration: TimeInterval?)
    public func say(_ text: String, expression: Expression, duration: TimeInterval)
    public func clear()
}

public struct CharacterView: View {   // pure SwiftUI Canvas/Shape. NO image assets.
    public init(model: CharacterModel, size: CGFloat)
}
```

Rules:
- The face is **drawn in code**: circles, arcs, curves. Deliberately crude. We are testing timing, not art.
- Expressions blend over ~180ms, never cut.
- Eye movement on idle; blink every 3–7s randomised.
- **No image or animation assets. Nothing copied from any other product.**

### Shell: `MemoirApp/Shell/` (+ `MemoirApp/Overlay/` for the hotkey and voice drivers)

Memoir's whole presence is one black band anchored to the notch (it widens and drops, it
never becomes a window), plus a real window it can be promoted to. The old floating
character panel and the centred ask bar are gone; the face lives in the band's strip
and speech arrives as a transient widening of the band.

```swift
/// The hub every shell surface observes.
@MainActor final class ShellModel: ObservableObject {
    enum PaneID: String, CaseIterable {
        case portrait, journal, ask, memories, settings
        case calendar = "today"              // raw value pinned: it is the saved-tab key
        static let bandTabs: [PaneID] = [.calendar, .journal, .ask, .portrait]  // left to right
    }
    enum BandMoment: Equatable {
        case speech(String, Expression)      // character.say, rehomed from the dead bubble
        case nudge(Nudge)                    // the restraint engine's delivery surface
        case saved(title: String, due: Date?)
        case health(CaptureHealth, String)   // capture stopped or started; jumps the queue
    }
    enum Mode: Equatable { case collapsed, moment(BandMoment), open }

    @Published private(set) var mode: Mode
    @Published var pane: PaneID              // persisted; ⌥Space reopens where you were
    @Published private(set) var counts: CommitmentCounts
    @Published private(set) var hasAccessibility: Bool

    func toggleOpen()                        // ⌥Space
    func open(pane: PaneID)                  // face click → .portrait; sentences navigate
    func collapse()                          // Esc / ⌥Space; ALWAYS stops the microphone
    func presentMoment(_ moment: BandMoment) // queued; only while collapsed
    func refreshCounts()
}

/// The one resident panel. Spans the maximum band frame at the top of the screen;
/// the SwiftUI shape inside springs between collapsed / moment / open.
@MainActor final class NotchPanelController {
    init(shell: ShellModel, character: CharacterModel, chat: ChatController)
    func show()
    static func makeBandPanel() -> NotchPanel  // the shipped window, buildable by tests
    func invalidate()                          // detaches observers; call before release
}

/// Chat state and pipeline, presentation-free. The transcript survives collapse;
/// ⌘K is the only thing that clears it. Owns the push path's confirm machinery:
/// `PushBridge` (route / preview / commit), the pending card state, and the due edit.
@MainActor final class ChatController: ObservableObject {
    struct PushBridge: Sendable {
        let route: @Sendable (String) async -> QuestionCategory
        let preview: @Sendable (String) async -> PushIntent?
        let commit: @Sendable (PushIntent) async throws -> Void   // the ONLY write (CF-51)
    }
    let state: ChatState                     // query, isThinking, exchanges, due draft
    init(voice: VoiceConfig, push: PushBridge?, character: CharacterModel?,
         onSubmit: @escaping @Sendable (String) async -> (String, BrainKind, TimeInterval)?)
    func submit()
    func savePendingPush() -> Bool           // Return / the Save button
    func discardPendingPush() -> Bool        // first Escape
    func stopVoice()                         // collapse() calls this; no path leaves the mic open
    static func moveCaretToDueField(in panel: NSWindow?, pendingPush: Bool) -> Bool  // Tab
}

@MainActor public final class HotkeyManager {
    public init(onActivate: @escaping @MainActor () -> Void)
    public func register(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
    public func unregister()
}

/// Drives the microphone. Owns all the audio; owns none of the decisions.
@MainActor public final class VoiceInput: ObservableObject {
    @Published public private(set) var state: VoiceState
    public var currentText: (@MainActor () -> String)?     // reads the composer field
    public var applyText: (@MainActor (String) -> Void)?   // writes the composer field
    public init(config: VoiceConfig)
    public func start()                          // idempotent
    public func stop()                           // idempotent
    public func toggle()
    public func updateConfig(_ config: VoiceConfig)
    public var startsOnOpen: Bool { get }
}
```

Rules:
- **One panel.** `NSPanel`, `[.borderless, .nonactivatingPanel]`, level `.statusBar`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`,
  transparent, `hasShadow = false` (SwiftUI draws the open-state shadow). The panel
  never resizes; the black shape inside springs between states (Reduce Motion: no spring).
- **`canBecomeKey` is dynamic.** False collapsed (the band can never steal typing);
  true open, then `makeKeyAndOrderFront` **without `NSApp.activate`**: typing lands in
  the composer while the frontmost app stays frontmost (the Spotlight pattern). Collapse
  flips it back and deactivates. Never call `NSApp.activate(ignoringOtherApps:)` here.
- **Clicks pass through everything but the drawn shape** (hosting-view `hitTest`
  returns nil outside the band rect). The menu bar and desktop stay clickable under
  the transparent frame.
- **Nothing is ever drawn over the camera.** On notched screens the strip splits
  around the cutout (`NotchGeometry`, from `NSScreen.safeAreaInsets` +
  `auxiliaryTop{Left,Right}Area`); screens without a housing get a synthetic
  rounded-bottom tab hanging under the menu bar. One code path (`BandLayout`).
- Collapsed shows the mark, with a small dot on it — green while capture is landing, red
  the moment it is not — plus **one**
  status slot: capture health, or nothing at all. A bare notch means it is recording. The
  slot used to carry an overdue pill and a due-today line; both are gone, because a count
  parked in the corner of the screen all day is a nag, and the commitments live on the pane
  that is about them. Never a row of badges.
- Open shows **one** column: the pane the selected tab names. There was a second one
  (next due, tracked today, mostly in, a focus ring), and it competed with whichever tab
  the user had actually chosen. The tab is the answer; the pane gets the width.
- The band's keys while open are read by a local monitor, not the text field, because
  the composer is disabled under a pending confirm card: Tab → the card's due field,
  first Escape → discard the card, second Escape / ⌥Space → collapse, Return → save.
- A click outside does **not** collapse: a stray click must not eat a half-typed
  question. Right-click on the band = the app menu (Pause capture, Grant
  Accessibility, Settings…, Quit).
- Band lives on one screen: the mouse's screen when opened, `NSScreen.main` collapsed;
  re-anchored on `didChangeScreenParametersNotification`.
- Hotkey uses `NSEvent.addGlobalMonitorForEvents`: **listen only**, never synthesize events.
- Default hotkey: `⌥Space`.
- **Nothing but the mic button opens the microphone; collapse, submit and Escape all
  stop it.** Opening onto Ask used to start listening in one motion. It does not any
  more. There is no path that opens the mic by itself, and none that leaves the band
  closed and the microphone open.
- macOS 26: `SpeechAnalyzer` + `SpeechTranscriber(reportingOptions: [.volatileResults])`, fed an `AsyncStream<AnalyzerInput>`. macOS 15: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`.
- Audio is captured with an `AVAudioEngine` input tap and passed through an `AVAudioConverter`: **formats are never assumed to match**.

### Voice: `MemoirKit/Voice/`

Everything about dictation that is not audio. Lives in `MemoirKit` so it is unit-testable without a microphone.

```swift
public enum VoiceState: Sendable, Equatable {
    case idle
    case requestingPermission
    case downloadingModel(Double)          // 0...1
    case listening(level: Float)           // RMS of the mic input, 0...1
    case unavailable(String)               // names the System Settings pane to open
}

/// The only thing that decides whether a session is running. This is what makes
/// start()/stop() idempotent and what keeps a stale session's results out of a new one.
public struct VoiceMachine: Sendable, Equatable {
    public private(set) var state: VoiceState
    public private(set) var isRunning: Bool
    public private(set) var session: Int
    public mutating func requestStart() -> Bool   // false ⇒ caller must do nothing
    public mutating func requestStop() -> Bool    // false ⇒ caller must do nothing
    public mutating func downloading(_ progress: Double)
    public mutating func opened()
    public mutating func setLevel(_ level: Float)
    public mutating func fail(_ reason: String)
    public mutating func clearFailure()
}

/// Voice appends to what the user typed. It never clobbers it.
public struct DictationBuffer: Sendable, Equatable {
    public init(prefix: String)
    public var text: String { get }
    public mutating func commit(_ segment: String)      // final result
    public mutating func setVolatile(_ segment: String) // live result, replaced each time
    public mutating func rebase(to fieldText: String)   // the user typed mid-dictation
}

public enum VoicePermissions {
    public enum Grant: Sendable, Equatable, CaseIterable { case granted, denied, restricted, notDetermined }
    public static func blockingState(speech: Grant, microphone: Grant) -> VoiceState?  // nil ⇒ proceed
}

/// The privacy floor, in one place.
public enum OnDeviceSpeech {
    public static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest  // always on-device
    public static func isOnDeviceOnly(_ request: SFSpeechRecognitionRequest) -> Bool
    public static func offDeviceReason(locale: Locale) -> String
    public static func grant(for status: SFSpeechRecognizerAuthorizationStatus) -> VoicePermissions.Grant
}

public struct VoiceConfig: Sendable, Codable, Equatable {
    public var localeIdentifier: String              // must be in SpeechTranscriber.supportedLocales
}
```

Rules:
- **Every `SFSpeechRecognitionRequest` in this codebase is built by `OnDeviceSpeech.makeRequest()`.** Nothing else may construct one, because nothing else guarantees `requiresOnDeviceRecognition`.
- A missing speech model is a **state**, not a crash: `.downloadingModel(progress)` while it fetches, `.unavailable(reason)` when it cannot.
- Denied authorization produces `.unavailable` naming the exact System Settings pane.
- `Info.plist` must carry `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`. `VoiceInput` refuses to ask for permission when they are absent rather than letting TCC kill the process.

### Setup: `MemoirKit/Setup/`

Connects the MCP server to the agent clients the user already has. `MCPInstaller` owns the
surface table and the writes; `SkillInstaller` copies the bundled skill into
`~/.claude/skills/memoir`.

There is no global MCP registry on macOS. Each client reads its own file, and the two called
Claude read two different ones: `claude_desktop_config.json` for the chat app, `~/.claude.json`
for Claude Code. Connecting one says nothing about the other, and treating them as one surface
is the single most common way this feature appears broken.

| Surface | File | Key |
|---|---|---|
| Claude Desktop | `Library/Application Support/Claude/claude_desktop_config.json` | `mcpServers` |
| Claude Code | `.claude.json` | `mcpServers` |
| Cursor | `.cursor/mcp.json` | `mcpServers` |
| Windsurf | `.codeium/windsurf/mcp_config.json` | `mcpServers` |
| Zed | `.config/zed/settings.json` | `context_servers` |

Rules, each one a way writing another application's config goes wrong:
- **Merge, never replace.** These files hold other people's servers, their API keys, and a
  preferences block the client maintains for itself. Only our own key is ever touched.
- **Write atomically, through a temporary file in the same directory.** A client that cannot
  parse its config does not start degraded; it starts with no servers at all.
- **Back up before the first change**, to `<config>.memoir-backup`, once.
- **Read back and report.** `~/.claude.json` is rewritten by every running Claude Code session,
  so a correct write can be undone seconds later. `Outcome.verified` says whether it survived;
  nothing claims success on the strength of the write alone.
- **Refuse what cannot be round-tripped.** Zed's settings file allows comments, which
  `JSONSerialization` will not parse. Those surfaces are detected, reported, and offered a
  snippet to paste, never written blind.
- **Never invent a client.** A surface whose client is not installed is `.clientNotFound` and
  is not work outstanding. Presence is decided by `Surface.presencePath` where the config's own
  directory cannot decide it: `~/.claude.json` sits at the root of the home directory, which
  exists on every Mac.
- The path written is derived from the **running bundle**, never hardcoded to `/Applications`.
  A moved or renamed app makes every entry `.stale(recorded:)`, which the UI offers to repair.

The consent layer is `MemoirApp/UI/ConnectionsView.swift`, not this module: nothing here
connects anything on its own, and every write is the direct result of a button.

### MCP: `Sources/MemoirMCP/`

Standalone executable, stdio JSON-RPC 2.0, protocol `2025-06-18`. Opens the same SQLite file **read-only**.

Lookup tools:
- `recall(query: String, limit: Int?)` → matching entities + captures with provenance
- `who_is(name: String)` → person dossier
- `what_happened(from: String, to: String)` → session and capture summary for a range
- `open_commitments()` → commitments with due dates
- `today()` → today's brief

Substrate tools (context an agent loads before acting):
- `what_changed_since(since: String)` → new entities, updated entities, where time went
- `prior_art(topic: String)` → dated history of a topic: first seen, last touched, timeline
- `working_set()` → what is in play right now: spans, windows, today's entities
- `sources_for(claim: String)` → quoted captures supporting a claim, or an honest absence
- `verify(claim: String, freshDays: Int?)` → fresh / stale (with age) / not in the record.
  Built to keep *other* memories honest; verifies presence in the record, not truth.
- `timesheet(from: String, to: String)` → per-day, per-project reconstruction with evidence

Recording (staged, never direct):
- `propose_memory(kind, title, detail?, due?)` → appends to `proposals.json` **beside** the
  database. The app lists proposals; only the user's accept commits one (as authored). The
  database remains read-only to this server in all cases.

Rules:
- Never writes the database. Never mutates memory. Opens with `SQLITE_OPEN_READONLY`.
- The single file it may write is `proposals.json`, and that is a review queue, not memory.
- Prints **nothing** to stdout except JSON-RPC frames. All logging goes to stderr.
- Every answer comes back twice: the markdown in `content`, for a reader, and a
  `structuredContent` envelope (`tool`, `status`, `summary`, `counts`, and
  `newest`/`oldest`/`ageSeconds` where the answer rests on dated rows) validating against the
  tool's advertised `outputSchema`, for a client drawing a summary chip. `ToolHandler` returns
  both as one `ToolResult`; nothing re-reads the prose to learn what is in it (CF-93).

---

## Config & paths

```
~/Library/Application Support/Memoir/
  memoir.sqlite            # everything
  config.json           # CaptureConfig + RestraintConfig + BrainConfig (minus the key)
  proposals.json        # agent-staged memories awaiting the user's accept
  logs/memoir.log
```
API key → Keychain, service `sh.memoir.brain`, account `anthropic`.

---

## Build

```
Scripts/build-app.sh     # swift build -c release, assemble Memoir.app, ad-hoc codesign
```
Accessibility permission is bound to the bundle ID + signature; re-signing resets it. Documented in the README as a known annoyance.

---

## Definition of done for v1

- [ ] `swift build` clean, zero warnings under strict concurrency
- [ ] `swift test` passes
- [ ] `Scripts/build-app.sh` produces a launchable `Memoir.app`
- [ ] Character visible, expressive, click-through, movable between monitors
- [ ] ⌥Space opens the ask bar anywhere; answers cite the brain that produced them
- [ ] ⌥Space also opens the microphone; speech streams into the field, Return sends, Escape cancels and closes the mic
- [ ] Capture runs, dedupes, respects the exclusion list, degrades without Screen Recording
- [ ] Memory browser lists entities with provenance; edit sticks; delete works; purge works
- [ ] `memoir-mcp` responds correctly to a handshake and all twelve tools
- [ ] Retention actually deletes old captures
- [ ] Nothing reaches the network unless a cloud brain is explicitly enabled
