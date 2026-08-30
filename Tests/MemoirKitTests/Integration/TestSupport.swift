//
//  TestSupport.swift
//  Shared harness for the CF-* integration tests.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THIS FILE IS A CONTRACT. Six other suites are written against it.
//  Add to it freely; do not change or remove what is already here.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  The five rules every integration test obeys, and where each one is now enforced:
//
//  1. Fresh temp directory per test           → `TestWorkspace.with { ws in ... }`, here.
//  2. Never touch ~/Library/Application Support/Memoir
//                                             → `with` binds `Paths.supportDirectoryOverride`,
//                                               so Store, Log and config.json all land in the
//                                               workspace. Inside `with`, `Store.defaultPath()`
//                                               *is* `ws.dbURL`.
//  3. Never read the wall clock               → `TestClock.reference` and its offsets,
//                                               in `MemoirFixtures`.
//  4. No network, ever                        → `BlockingURLProtocol` + `assertNoNetwork()`, here.
//  5. Deterministic                           → fixtures have stable IDs and stable text;
//                                               nothing here calls `Date()`, `UUID()` or
//                                               `random`.
//
//  ## What moved, and why the contract is still whole
//
//  `TestClock`, `TestID`, `Fixtures`, `seed`, the row builders and the seeded working day are
//  no longer in this file. They are the `MemoirFixtures` module, because `memoir-eval-seed`
//  needs exactly the same world and a second copy of it would drift: both would compile, the
//  names would be identical, and the suite and the eval gate would slowly stop agreeing about
//  what "the seeded day" means.
//
//  Nothing was renamed and nothing changed shape, so every suite written against the old names
//  still reads the same. The only difference at a call site is `import MemoirFixtures`. What
//  stayed here is what genuinely belongs to a test process: the workspace, the network blocker,
//  the fake brains, the MCP subprocess locator and the privacy sentinels.
//

import CryptoKit
import Foundation
import ObjectiveC
import Testing

import MemoirFixtures
@testable import MemoirKit

// MARK: - Isolated workspace

/// One test's private slice of the filesystem: its own directory, its own SQLite file,
/// its own `config.json` and its own log.
///
/// Always reach for ``with(_:)``. It creates the directory, redirects `Paths` so nothing
/// can escape into the user's real `~/Library/Application Support/Memoir`, installs the
/// network blocker, and tears the directory down even when the body throws.
///
/// ```swift
/// @Test("CF-10 capture lands correctly")
/// func captureLands() async throws {
///     try await TestWorkspace.with { ws in
///         let store = try await ws.store()
///         try await store.insert(capture: Fixtures.email())
///         ...
///     }
/// }
/// ```
struct TestWorkspace: Sendable {

    /// The private directory. Everything else lives inside it.
    let root: URL

    /// `root/memoir.sqlite`; inside ``with(_:)``, exactly `Store.defaultPath()`.
    let dbURL: URL

    /// `root/config.json`; inside ``with(_:)``, exactly `Paths.configURL()`.
    let configURL: URL

    /// `root/logs/memoir.log`; inside ``with(_:)``, exactly where `Log.shared` writes.
    let logURL: URL

    /// Creates a uniquely named directory under the system temp directory.
    ///
    /// Prefer ``with(_:)``: a bare `init` does **not** redirect `Paths`, so `Log` and
    /// anything reading `Store.defaultPath()` would still point at the user's real folder.
    init() throws {
        let name = "memoir-integration-\(ProcessInfo.processInfo.processIdentifier)-\(Self.nextSequence())"
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.root = base.appendingPathComponent(name, isDirectory: true)
        self.dbURL = root.appendingPathComponent("memoir.sqlite")
        self.configURL = root.appendingPathComponent("config.json")
        self.logURL = root.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("memoir.log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Opens a real read-write `Store` on ``dbURL``, creating and migrating the file.
    func store() async throws -> Store {
        try Store(path: dbURL)
    }

    /// Opens a real `SQLITE_OPEN_READONLY` `Store` on ``dbURL``. The file must already exist
    /// and already carry the schema. Open a read-write store first.
    func readOnlyStore() async throws -> Store {
        try Store(readOnlyPath: dbURL)
    }

    /// Deletes the directory and everything in it. Safe to call twice.
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs `body` against a fresh workspace and guarantees teardown.
    ///
    /// Inside the closure:
    /// - `Paths.supportDirectory()`, `Paths.databaseURL()`, `Paths.configURL()` and
    ///   `Paths.logsDirectory()` all resolve inside ``root``;
    /// - ``BlockingURLProtocol`` is installed, so any attempted request is recorded and failed;
    /// - the directory is removed on the way out, whether the body returns or throws.
    @discardableResult
    static func with<T>(_ body: (TestWorkspace) async throws -> T) async throws -> T {
        BlockingURLProtocol.install()
        let workspace = try TestWorkspace()
        defer { workspace.cleanup() }
        return try await Paths.$supportDirectoryOverride.withValue(workspace.root) {
            try await body(workspace)
        }
    }

    // MARK: Reading what landed on disk (CF-4 greps these)

    /// Every byte of the database, including the `-wal` and `-shm` sidecars.
    ///
    /// CF-4 greps this for the API key: a key that lives only in the Keychain must not
    /// appear anywhere in here, and the WAL is where a naive implementation would leak it.
    func databaseBytes() -> Data {
        var out = Data()
        for path in [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm"] {
            if let data = FileManager.default.contents(atPath: path) { out.append(data) }
        }
        return out
    }

    /// The contents of `config.json`, or `""` when it was never written.
    func configContents() -> String {
        (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    }

    /// The contents of the log file, or `""` when nothing was logged.
    func logContents() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    /// Writes a `BrainConfig` to ``configURL`` exactly the way the app does.
    ///
    /// `BrainConfig`'s encoder drops the API key on purpose; CF-4 uses this to prove it.
    func writeConfig(_ config: BrainConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    /// True when `needle` appears in the database bytes, the config file or the log.
    ///
    /// The comparison is case sensitive and treats the database as UTF-8-ish bytes, which is
    /// what a leaked ASCII API key would look like on disk.
    func anyArtifactContains(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        if configContents().contains(needle) { return true }
        if logContents().contains(needle) { return true }
        let bytes = databaseBytes()
        guard !bytes.isEmpty else { return false }
        return bytes.range(of: Data(needle.utf8)) != nil
    }

    // MARK: Naming

    private static let sequenceLock = NSLock()
    nonisolated(unsafe) private static var sequence = 0

    /// A process-unique counter, so two workspaces never collide without touching `UUID()`.
    private static func nextSequence() -> Int {
        sequenceLock.withLock {
            sequence += 1
            return sequence
        }
    }
}

// MARK: - Network blocker

/// A `URLProtocol` that intercepts **every** outbound request in the test process, records
/// its URL, and fails it without a byte leaving the machine.
///
/// This is the structural backbone of CF-2. Two mechanisms are needed, because either one
/// alone leaves a hole:
///
/// 1. `URLProtocol.registerClass`: covers `URLSession.shared`.
/// 2. Swizzling `+[NSURLSessionConfiguration defaultSessionConfiguration]` and
///    `+ephemeralSessionConfiguration` to prepend this class to `protocolClasses`: covers
///    every session built from a configuration, which is what `AnthropicBrain` uses.
///    Globally registered classes are *not* consulted by such sessions; verified by TS-3.
///
/// Recording is process-global, which is correct: no test in this suite may ever make a
/// request, so the list should stay empty for the whole run. The one sanctioned exception is
/// the self-test probe at ``probeHost``, which ``unexpectedRequests`` filters out so it
/// cannot fail a concurrently running test.
final class BlockingURLProtocol: URLProtocol, @unchecked Sendable {

    /// Host reserved for the harness's own "does the blocker actually work" probe.
    /// `.invalid` is guaranteed never to resolve. Production code must never use it.
    static let probeHost = "memoir-selftest.invalid"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URL] = []
    nonisolated(unsafe) private static var isInstalled = false
    nonisolated(unsafe) private static var isSwizzled = false

    /// Every URL any request has been attempted against, oldest first, probe included.
    static var attemptedRequests: [URL] {
        lock.withLock { recorded }
    }

    /// ``attemptedRequests`` minus the harness's own probe. This is what CF-2 asserts on.
    static var unexpectedRequests: [URL] {
        attemptedRequests.filter { $0.host != probeHost }
    }

    /// Installs the blocker. Idempotent and safe to call from every test.
    static func install() {
        lock.withLock {
            guard !isInstalled else { return }
            isInstalled = true
            URLProtocol.registerClass(BlockingURLProtocol.self)
            if !isSwizzled {
                isSwizzled = true
                exchange("defaultSessionConfiguration", "memoirBlocking_defaultSessionConfiguration")
                exchange("ephemeralSessionConfiguration", "memoirBlocking_ephemeralSessionConfiguration")
            }
        }
    }

    /// Removes the blocker. Provided for completeness; the suite never calls it, because a
    /// hole in the blocker is exactly the bug CF-2 exists to catch.
    static func uninstall() {
        lock.withLock {
            guard isInstalled else { return }
            isInstalled = false
            URLProtocol.unregisterClass(BlockingURLProtocol.self)
            if isSwizzled {
                isSwizzled = false
                exchange("defaultSessionConfiguration", "memoirBlocking_defaultSessionConfiguration")
                exchange("ephemeralSessionConfiguration", "memoirBlocking_ephemeralSessionConfiguration")
            }
        }
    }

    /// Forgets every recorded request. Note this is process-global state: only reset when
    /// no other test could be observing it, which in practice means only after a probe.
    static func reset() {
        lock.withLock { recorded.removeAll() }
    }

    /// Swaps two class-method implementations on `URLSessionConfiguration`.
    private static func exchange(_ original: String, _ replacement: String) {
        let cls: AnyClass = URLSessionConfiguration.self
        guard let a = class_getClassMethod(cls, NSSelectorFromString(original)),
              let b = class_getClassMethod(cls, NSSelectorFromString(replacement))
        else { return }
        method_exchangeImplementations(a, b)
    }

    // MARK: URLProtocol

    /// Records and claims every request. Returning true here is what guarantees the request
    /// never reaches the transport layer.
    override class func canInit(with request: URLRequest) -> Bool {
        if let url = request.url {
            lock.withLock { recorded.append(url) }
        }
        return true
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        if let url = task.originalRequest?.url ?? task.currentRequest?.url {
            lock.withLock { recorded.append(url) }
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Swizzle targets. Inside each body the same-named call reaches the *original*
/// implementation, because the two IMPs have been exchanged.
extension URLSessionConfiguration {

    @objc class func memoirBlocking_defaultSessionConfiguration() -> URLSessionConfiguration {
        let config = memoirBlocking_defaultSessionConfiguration()
        var classes = config.protocolClasses ?? []
        classes.insert(BlockingURLProtocol.self, at: 0)
        config.protocolClasses = classes
        return config
    }

    @objc class func memoirBlocking_ephemeralSessionConfiguration() -> URLSessionConfiguration {
        let config = memoirBlocking_ephemeralSessionConfiguration()
        var classes = config.protocolClasses ?? []
        classes.insert(BlockingURLProtocol.self, at: 0)
        config.protocolClasses = classes
        return config
    }
}

/// Fails the current test if anything attempted a network request.
///
/// Call it at the end of any flow that exercises the brain layer, and in CF-2 after every
/// stage of the pipeline.
func assertNoNetwork(sourceLocation: SourceLocation = #_sourceLocation) {
    let attempts = BlockingURLProtocol.unexpectedRequests
    #expect(
        attempts.isEmpty,
        "Something tried to reach the network: \(attempts.map(\.absoluteString).joined(separator: ", "))",
        sourceLocation: sourceLocation
    )
}

// MARK: - Fake brains

/// A `Brain` that answers whatever you told it to, reports whatever availability you told
/// it to, and counts how often it was asked.
///
/// Use it wherever a brain is an input rather than the thing under test: `LLMExtractor`
/// (CF-16), the fallback chain, and anywhere a test needs an answer without a model.
///
/// The default `completionText` is `"[]"`, which is a valid empty `LLMExtractor` payload,
/// so `LLMExtractor(brain: StubBrain())` layers cleanly on top of `RuleExtractor` and
/// contributes nothing, which is usually what an idempotence test wants.
final class StubBrain: Brain, @unchecked Sendable {

    /// Which brain this pretends to be. Reported on every answer.
    let kind: BrainKind

    private let lock = NSLock()
    private var available: Bool
    private var answerText: String
    private var citedCaptureIDs: [ID]
    private var completionText: String
    private var counts = Counts()

    /// Call counters and the last inputs seen.
    struct Counts: Sendable {
        var availability = 0
        var answers = 0
        var completions = 0
        var lastQuestion: String?
        var lastPrompt: String?
        var lastMaxTokens: Int?
    }

    /// - Parameters:
    ///   - kind: the `BrainKind` reported by `kind` and stamped on every `BrainAnswer`.
    ///   - available: what `isAvailable()` returns.
    ///   - answerText: what `answer(question:context:)` returns as its text.
    ///   - citedCaptureIDs: cited ids on the returned answer. Empty means "echo the packet's".
    ///   - completionText: what `complete(prompt:maxTokens:)` returns.
    init(
        kind: BrainKind = .appleOnDevice,
        available: Bool = true,
        answerText: String = "Stub brain answer.",
        citedCaptureIDs: [ID] = [],
        completionText: String = "[]"
    ) {
        self.kind = kind
        self.available = available
        self.answerText = answerText
        self.citedCaptureIDs = citedCaptureIDs
        self.completionText = completionText
    }

    // MARK: Brain

    func isAvailable() async -> Bool {
        lock.withLock {
            counts.availability += 1
            return available
        }
    }

    func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
        let (text, cited) = lock.withLock { () -> (String, [ID]) in
            counts.answers += 1
            counts.lastQuestion = question
            return (answerText, citedCaptureIDs)
        }
        return BrainAnswer(
            text: text,
            brain: kind,
            citedCaptureIDs: cited.isEmpty ? context.captureIDs : cited,
            latency: 0
        )
    }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock {
            counts.completions += 1
            counts.lastPrompt = prompt
            counts.lastMaxTokens = maxTokens
            return completionText
        }
    }

    // MARK: Inspection and control

    /// A snapshot of the counters. Reading is synchronous on purpose.
    var callCounts: Counts { lock.withLock { counts } }

    /// How many times `answer(question:context:)` was called.
    var answerCallCount: Int { lock.withLock { counts.answers } }

    /// How many times `complete(prompt:maxTokens:)` was called.
    var completeCallCount: Int { lock.withLock { counts.completions } }

    /// How many times `isAvailable()` was called. Useful for asserting the router caches.
    var availabilityCallCount: Int { lock.withLock { counts.availability } }

    /// The most recent question passed to `answer`.
    var lastQuestion: String? { lock.withLock { counts.lastQuestion } }

    /// The most recent prompt passed to `complete`.
    var lastPrompt: String? { lock.withLock { counts.lastPrompt } }

    /// Flips availability mid-test.
    func setAvailable(_ value: Bool) { lock.withLock { available = value } }

    /// Replaces the canned answer mid-test.
    func setAnswerText(_ value: String) { lock.withLock { answerText = value } }

    /// Replaces the canned completion mid-test.
    func setCompletionText(_ value: String) { lock.withLock { completionText = value } }

    /// Zeroes the counters, keeping the canned responses.
    func resetCounts() { lock.withLock { counts = Counts() } }
}

/// A `Brain` that reports itself available and then throws on every call.
///
/// This is the shape that matters for fallback: a brain which *claims* it can answer and
/// fails at the last moment is the case a naive router gets wrong.
final class FailingBrain: Brain, @unchecked Sendable {

    /// Which brain this pretends to be.
    let kind: BrainKind

    /// The error thrown by both `answer` and `complete`.
    let error: MemoirError

    private let lock = NSLock()
    private var available: Bool
    private var calls = 0

    /// - Parameters:
    ///   - kind: the `BrainKind` reported by `kind`.
    ///   - available: what `isAvailable()` returns. Defaults to true, so the brain is
    ///     actually reached and actually fails.
    ///   - error: the error to throw. Defaults to `.brainUnavailable(kind, ...)`.
    init(kind: BrainKind = .anthropicAPI, available: Bool = true, error: MemoirError? = nil) {
        self.kind = kind
        self.available = available
        self.error = error ?? .brainUnavailable(kind, "FailingBrain always fails.")
    }

    func isAvailable() async -> Bool { lock.withLock { available } }

    func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
        lock.withLock { calls += 1 }
        throw error
    }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { calls += 1 }
        throw error
    }

    /// How many times this brain was actually reached.
    var callCount: Int { lock.withLock { calls } }

    /// Flips availability mid-test.
    func setAvailable(_ value: Bool) { lock.withLock { available = value } }
}

// MARK: - The MCP executable

/// Finds the compiled `memoir-mcp` binary so the MCP flows (CF-30 … CF-34) can run the real
/// thing as a subprocess rather than an in-process mock.
///
/// The binary reads its database from `--db <path>`, falling back to `MEMOIR_DB_PATH` and then
/// to the user's real database. **Always pass `--db`**. Otherwise the subprocess opens
/// `~/Library/Application Support/Memoir/memoir.sqlite`. The task-local path override cannot help
/// here: it does not cross a process boundary.
enum MCPBinary {

    /// Executable name produced by `swift build`.
    static let name = "memoir-mcp"

    /// Location of the built binary.
    ///
    /// Looked for next to the test bundle (`.build/<config>/memoir-mcp`), which is where SwiftPM
    /// puts it, and overridable with the `MEMOIR_MCP_BINARY` environment variable.
    ///
    /// - Throws: when the binary is missing, which usually means `swift build` has not run.
    static func url() throws -> URL {
        for candidate in candidates() where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw MemoirError.invalidConfig(
            "\(name) not found. Looked in: \(candidates().map(\.path).joined(separator: ", ")). Run `swift build` first."
        )
    }

    /// Every place the binary might be, in priority order.
    static func candidates() -> [URL] {
        var out: [URL] = []
        let environment = ProcessInfo.processInfo.environment["MEMOIR_MCP_BINARY"] ?? ""
        if !environment.isEmpty { out.append(URL(fileURLWithPath: environment)) }

        // The .xctest bundle sits in the build directory alongside the executables.
        let bundle = Bundle(for: BlockingURLProtocol.self).bundleURL.deletingLastPathComponent()
        out.append(bundle.appendingPathComponent(name))
        out.append(bundle.deletingLastPathComponent().appendingPathComponent(name))

        return out
    }

    /// Arguments that point the server at a workspace database.
    ///
    /// ```swift
    /// process.executableURL = try MCPBinary.url()
    /// process.arguments = MCPBinary.arguments(database: ws.dbURL)
    /// ```
    static func arguments(database: URL) -> [String] {
        ["--db", database.path]
    }
}

// MARK: - Brain configuration

/// Ready-made `BrainConfig`s, with the one trap in this codebase spelled out.
///
/// **The trap:** `ClaudeCodeBrain` is a *local subprocess* that reaches the network on its
/// own, so `BrainKind.claudeCode.isCloud` is true. While `allowCloud` is false, `BrainRouter`
/// never constructs it and nothing is ever spawned: the router is completely hermetic.
///
/// Turn `allowCloud` on and that stops being true: `BrainRouter.available()` probes every
/// kind, and probing `claudeCode` runs `command -v claude` through the user's login shell
/// (seconds, once per process) and can then launch the real CLI, which is a genuine escape
/// from the test's sandbox. Setting `claudeCodePath` to a bogus path does **not** prevent it,
/// because discovery falls back to the well-known install locations and the shell probe.
///
/// So: with cloud on, ask the router `current()`, `chain()` or `answer(...)`. Never
/// `available()`, and never make `.claudeCode` the preferred brain.
enum TestBrainConfig {

    /// `allowCloud = false`, no key. The hermetic default, and what CF-2 and CF-3 assert against.
    static let localOnly = BrainConfig(
        anthropicAPIKey: nil,
        claudeCodePath: nil,
        allowCloud: false
    )

    /// `allowCloud = false` but with a key present, which is the interesting negative case:
    /// a configured cloud brain that still must never be selected.
    static let keyedButLocalOnly = BrainConfig(
        anthropicAPIKey: TestSecrets.apiKey,
        claudeCodePath: nil,
        allowCloud: false
    )

    /// `allowCloud = true` with the sentinel key. Read the type's documentation before using
    /// this: it is the only configuration from which a test can reach outside the process.
    static func cloudEnabled(key: String = TestSecrets.apiKey) -> BrainConfig {
        BrainConfig(anthropicAPIKey: key, claudeCodePath: nil, allowCloud: true)
    }
}

// MARK: - Secrets used by the privacy flows

/// Sentinel values the privacy flows grep for.
///
/// They are deliberately shaped like the real thing and deliberately unmistakable, so a hit
/// anywhere on disk is proof of a leak rather than a coincidence.
enum TestSecrets {

    /// A fake Anthropic key. Never valid, never usable, and impossible to confuse with
    /// anything else in a hexdump.
    static let apiKey = "sk-ant-api03-MEMOIRTESTSENTINEL-DO-NOT-PERSIST-0000000000"

    /// The distinctive middle of ``apiKey``. Grep for this when a formatter might have
    /// wrapped or truncated the full string.
    static let apiKeyNeedle = "MEMOIRTESTSENTINEL"
}
