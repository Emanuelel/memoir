//
//  MCPContractTests.swift
//  Tier 3: CF-30 … CF-34, the MCP contract.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  These tests drive the REAL COMPILED `memoir-mcp` BINARY as a subprocess over
//  stdio. Not a mock, not an in-process handler: the actual executable Claude
//  Code launches, speaking newline-delimited JSON-RPC 2.0 down a pipe.
//
//  That is the whole point. Every interesting failure in this layer (a stray
//  `print()`, a frame without a newline, a hang on EOF, a write to a database
//  that was promised read-only) is invisible to an in-process test and fatal in
//  production.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  How the rules are kept:
//
//  * Fresh temp directory  → `TestWorkspace.with`, as everywhere else.
//  * Never the real database → the child is pinned three ways: `--db` points at
//    the workspace, `HOME` points at the workspace (so the standard-location
//    fallback lands there too), and `MEMOIR_DB_PATH` is a deliberate *decoy* that
//    resolves nowhere. Only `--db` yields data, so a regression that ignored the
//    flag would fail these tests loudly instead of quietly reading the user's
//    real memory.
//  * Never the wall clock  → every seeded row is stamped from `TestClock`, and
//    `what_happened` is given an explicit ISO range. `today` and
//    `open_commitments` genuinely call `Date()` inside the server, so the
//    assertions here are restricted to the parts of their output that do not
//    depend on when the suite runs.
//  * Deterministic         → no sleeps. Waiting is done on semaphores with a
//    monotonic deadline (`DispatchTime.now() + n`), never on `Date()`, and a
//    timeout is a failure, never a synchronisation device.
//  * Always reaped         → every launch is followed by `defer { server.stop() }`,
//    which closes stdin, waits, then escalates SIGTERM → SIGKILL. A failing
//    assertion cannot leak a process.
//

import CryptoKit
import Foundation
import SQLite3
import Testing

import MemoirFixtures
@testable import MemoirKit

// MARK: - Locating (and, if necessary, building) the binary

/// Errors the harness raises on its own behalf, kept separate from anything the
/// server under test might report.
enum MCPHarnessError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case buildFailed(String)
    case timedOut(String)
    case notJSON(String)
    case sqlite(String)

    var description: String {
        switch self {
        case .binaryNotFound(let m): return "memoir-mcp not found: \(m)"
        case .buildFailed(let m): return "building memoir-mcp failed: \(m)"
        case .timedOut(let m): return "timed out: \(m)"
        case .notJSON(let m): return "stdout line is not JSON: \(m)"
        case .sqlite(let m): return "sqlite: \(m)"
        }
    }
}

/// Finds the compiled `memoir-mcp`, building it once if it is missing.
///
/// `swift test` only builds the test target and its dependencies, and `MemoirMCP` is
/// not one of them, so on a clean checkout the binary genuinely does not exist
/// yet. Rather than skip the whole tier (which is how an MCP regression ships),
/// the harness builds it on demand and caches the result for the process.
enum MCPExecutable {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: URL?

    /// The executable, built if necessary. Cached after the first successful resolution.
    static func url() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        if let found = locate() {
            cached = found
            return found
        }

        guard let root = packageRoot() else {
            throw MCPHarnessError.binaryNotFound(
                "no Package.swift above \(Bundle(for: MCPServer.self).bundleURL.path); "
                + "set MEMOIR_MCP_BINARY to the built executable"
            )
        }
        try build(packageRoot: root)

        guard let found = locate(packageRoot: root) else {
            throw MCPHarnessError.binaryNotFound(
                "`swift build --product \(MCPBinary.name)` reported success but produced nothing in \(root.path)/.build"
            )
        }
        cached = found
        return found
    }

    /// Where the on-demand build puts its output.
    ///
    /// Deliberately **not** the package's own `.build`. SwiftPM takes an exclusive
    /// lock on a scratch directory, and `swift test` may still be holding the one on
    /// `.build` while these tests run: a build into it would wait for the test run
    /// that is waiting for the build. A private scratch path has its own lock and
    /// cannot deadlock.
    private static func fallbackScratch(packageRoot root: URL) -> URL {
        root.appendingPathComponent(".build/memoir-mcp-test-scratch", isDirectory: true)
    }

    /// Every place the executable might already be, in priority order.
    private static func locate(packageRoot root: URL? = packageRoot()) -> URL? {
        var candidates = MCPBinary.candidates()
        if let root {
            for configuration in ["debug", "release"] {
                candidates.append(root.appendingPathComponent(".build/\(configuration)/\(MCPBinary.name)"))
                candidates.append(
                    fallbackScratch(packageRoot: root).appendingPathComponent("\(configuration)/\(MCPBinary.name)")
                )
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Walks up from the test bundle looking for the package manifest.
    private static func packageRoot() -> URL? {
        var directory = Bundle(for: MCPServer.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    /// Runs `swift build --product memoir-mcp` once, synchronously and with a deadline.
    ///
    /// The deadline matters: a build that blocks forever on a SwiftPM lock would hang
    /// the whole suite, and a hang is the one failure mode these tests exist to
    /// prevent. Past the deadline the child is killed and the test fails loudly.
    private static func build(packageRoot root: URL) throws {
        let scratch = fallbackScratch(packageRoot: root)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift", "build",
            "--product", MCPBinary.name,
            "--package-path", root.path,
            "--scratch-path", scratch.path,
        ]
        // Output goes to a file rather than a pipe: nothing to drain, so a chatty
        // build cannot fill a buffer and wedge, and no extra thread is needed to
        // stop it happening.
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-mcp-fallback-build-\(ProcessInfo.processInfo.processIdentifier).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }
        if let sink = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = sink
            process.standardError = sink
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw MCPHarnessError.buildFailed("could not launch swift build: \(error)")
        }

        guard finished.wait(timeout: .now() + buildTimeout) == .success else {
            process.terminate()
            _ = finished.wait(timeout: .now() + 10)
            throw MCPHarnessError.buildFailed(
                "`swift build --product \(MCPBinary.name)` did not finish within \(Int(buildTimeout))s; "
                + "build it yourself with `swift build` and re-run"
            )
        }
        guard process.terminationStatus == 0 else {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no output)"
            throw MCPHarnessError.buildFailed("exit \(process.terminationStatus)\n\(log)")
        }
    }

    /// Longest the on-demand build may take. Generous (it is a cold build of
    /// MemoirKit and MemoirMCP) but finite.
    private static let buildTimeout: Double = 600
}

// MARK: - One live server

/// A running `memoir-mcp` subprocess, plus everything needed to talk to it safely.
///
/// stdout is split into newline-delimited frames as they arrive; stderr is drained
/// in parallel so a chatty log can never fill its pipe and wedge the child. Every
/// wait has a deadline, so a hung server fails a test in seconds instead of
/// hanging the suite.
final class MCPServer: @unchecked Sendable {

    /// Longest a single response may take before the test fails.
    static let responseTimeout: Double = 30

    /// Longest the process may take to exit after stdin closes.
    static let exitTimeout: Double = 30

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()

    private let lock = NSLock()
    private let waitQueue: DispatchQueue
    private let lineSignal = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    private let stdoutClosed = DispatchSemaphore(value: 0)
    private let stderrClosed = DispatchSemaphore(value: 0)

    private var outBytes: [UInt8] = []
    private var errBytes: [UInt8] = []
    private var unread: [String] = []
    private var seen: [String] = []
    private var partialTail: String?
    private var stdinOpen = true
    private var reaped = false

    /// The `--db` path this server was pointed at, for failure messages.
    let databasePath: String?

    // MARK: Launching

    /// Starts a server.
    ///
    /// - Parameters:
    ///   - database: value for `--db`. `nil` launches with no flag at all, which is
    ///     only ever useful for proving the decoy environment holds.
    ///   - home: value for `HOME`. Must be inside the workspace: it is the last
    ///     line of defence against the child opening the user's real database.
    ///   - logLevel: `MEMOIR_MCP_LOG_LEVEL`. `nil` leaves the server on its default.
    ///   - decoyDatabasePath: value for `MEMOIR_DB_PATH`. Deliberately not the real
    ///     database, so `--db` has to be honoured for any content to appear.
    static func start(
        database: URL?,
        home: URL,
        logLevel: String? = nil,
        decoyDatabasePath: String
    ) throws -> MCPServer {
        let server = try MCPServer(database: database, home: home, logLevel: logLevel, decoy: decoyDatabasePath)
        try server.launch()
        return server
    }

    private init(database: URL?, home: URL, logLevel: String?, decoy: String) throws {
        Self.ignoreSIGPIPEOnce()
        self.databasePath = database?.path
        self.waitQueue = DispatchQueue(label: "sh.memoir.tests.mcp.wait.\(Self.nextSequence())")

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        process.executableURL = try MCPExecutable.url()
        process.arguments = database.map { MCPBinary.arguments(database: $0) } ?? []
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["MEMOIR_DB_PATH"] = decoy
        environment.removeValue(forKey: "MEMOIR_MCP_BINARY")
        if let logLevel {
            environment["MEMOIR_MCP_LOG_LEVEL"] = logLevel
        } else {
            environment.removeValue(forKey: "MEMOIR_MCP_LOG_LEVEL")
        }
        process.environment = environment
    }

    private func launch() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.absorbOutput(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.absorbErrors(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            self?.exited.signal()
        }
        try process.run()
    }

    // MARK: Pipe plumbing

    private func absorbOutput(_ data: Data) {
        guard !data.isEmpty else {
            output.fileHandleForReading.readabilityHandler = nil
            flushOutputTail()
            stdoutClosed.signal()
            return
        }
        var produced = 0
        lock.lock()
        outBytes.append(contentsOf: data)
        while let index = outBytes.firstIndex(of: 0x0A) {
            let line = String(decoding: outBytes[..<index], as: UTF8.self)
            outBytes.removeSubrange(...index)
            seen.append(line)
            unread.append(line)
            produced += 1
        }
        lock.unlock()
        for _ in 0..<produced { lineSignal.signal() }
    }

    /// A frame the server wrote without a trailing newline. This is a protocol
    /// violation on its own (the framing *is* the newline), so it is recorded
    /// separately rather than silently folded into the line list.
    private func flushOutputTail() {
        lock.lock()
        defer { lock.unlock() }
        guard !outBytes.isEmpty else { return }
        partialTail = String(decoding: outBytes, as: UTF8.self)
        outBytes.removeAll()
    }

    private func absorbErrors(_ data: Data) {
        guard !data.isEmpty else {
            errors.fileHandleForReading.readabilityHandler = nil
            stderrClosed.signal()
            return
        }
        lock.withLock { errBytes.append(contentsOf: data) }
    }

    // MARK: Reading

    /// Every complete stdout line the server has produced, in order.
    var stdoutLines: [String] { lock.withLock { seen } }

    /// A frame written without its terminating newline, if the server ever did that.
    var unterminatedTail: String? { lock.withLock { partialTail } }

    /// Everything the server has written to stderr so far.
    var stderrText: String { lock.withLock { String(decoding: errBytes, as: UTF8.self) } }

    /// The next unread stdout line, or `nil` if none arrives before the deadline.
    ///
    /// The blocking wait happens on a private queue rather than on the cooperative
    /// pool, so a stalled server cannot starve the rest of the suite.
    func nextLine(timeout: Double = MCPServer.responseTimeout) async -> String? {
        await withCheckedContinuation { continuation in
            waitQueue.async { [self] in
                guard lineSignal.wait(timeout: .now() + timeout) == .success else {
                    continuation.resume(returning: nil)
                    return
                }
                let line = lock.withLock { unread.isEmpty ? nil : unread.removeFirst() }
                continuation.resume(returning: line)
            }
        }
    }

    // MARK: Writing

    /// Writes one raw line, newline included. Never throws on a dead child: a
    /// broken pipe here is the server having exited, which the test asserts on
    /// separately and more informatively.
    func send(rawLine: String) {
        let shouldWrite = lock.withLock { stdinOpen }
        guard shouldWrite else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data((rawLine + "\n").utf8))
    }

    /// Sends a request and returns the very next stdout frame.
    ///
    /// Deliberately strict: the server answers a single stream of requests in
    /// order, so the *next* frame must be this request's response. Anything else
    /// (an answered notification, an unsolicited log line on stdout) surfaces here
    /// as a mismatched id rather than being quietly skipped over.
    @discardableResult
    func request(
        _ method: String,
        params: [String: Any]? = nil,
        id: Int,
        timeout: Double = MCPServer.responseTimeout,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> MCPFrame {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let params { message["params"] = params }
        send(rawLine: try Self.encode(message))

        guard let line = await nextLine(timeout: timeout) else {
            throw MCPHarnessError.timedOut("no response to \(method) (id \(id)) within \(timeout)s")
        }
        let frame = try MCPFrame(line: line)
        #expect(frame.jsonrpc == "2.0", "every frame must carry jsonrpc 2.0: \(line)", sourceLocation: sourceLocation)
        #expect(frame.id == id, "response id must match the request: \(line)", sourceLocation: sourceLocation)
        return frame
    }

    /// Sends a notification. Notifications must never be answered.
    func notify(_ method: String, params: [String: Any]? = nil) throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        send(rawLine: try Self.encode(message))
    }

    /// Calls a tool and returns the frame.
    @discardableResult
    func callTool(
        _ name: String,
        arguments: [String: Any] = [:],
        id: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> MCPFrame {
        try await request(
            "tools/call",
            params: ["name": name, "arguments": arguments],
            id: id,
            sourceLocation: sourceLocation
        )
    }

    /// initialize → initialized → (caller continues from `nextID`).
    ///
    /// Returns the `initialize` frame so a test can still assert on it.
    @discardableResult
    func handshake(sourceLocation: SourceLocation = #_sourceLocation) async throws -> MCPFrame {
        let frame = try await request(
            "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "memoir-integration-tests", "version": "1.0.0"],
            ],
            id: 1,
            sourceLocation: sourceLocation
        )
        try notify("notifications/initialized")
        return frame
    }

    private static func encode(_ message: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Shutting down

    /// Closes stdin, which is how an MCP client says goodbye.
    func closeInput() {
        let shouldClose = lock.withLock {
            defer { stdinOpen = false }
            return stdinOpen
        }
        guard shouldClose else { return }
        try? input.fileHandleForWriting.close()
    }

    /// Closes stdin and waits for a clean exit.
    ///
    /// - Returns: the exit status, or `nil` if the process was still alive at the
    ///   deadline (which is itself a failure: the server must exit on EOF).
    func waitForExit(timeout: Double = MCPServer.exitTimeout) async -> Int32? {
        closeInput()
        return await withCheckedContinuation { continuation in
            waitQueue.async { [self] in
                guard Self.pass(exited, timeout: timeout) else {
                    continuation.resume(returning: nil)
                    return
                }
                // Let the pipe readers reach EOF so stderr is complete before a test
                // asserts on it.
                _ = Self.pass(stdoutClosed, timeout: 5)
                _ = Self.pass(stderrClosed, timeout: 5)
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    /// Unconditional teardown for `defer`. Idempotent, and never leaves a process behind.
    func stop() {
        let alreadyReaped = lock.withLock {
            defer { reaped = true }
            return reaped
        }
        guard !alreadyReaped else { return }

        closeInput()
        if !Self.pass(exited, timeout: 5) {
            process.terminate()
            if !Self.pass(exited, timeout: 5) {
                kill(process.processIdentifier, SIGKILL)
                _ = Self.pass(exited, timeout: 5)
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }

    /// Waits on a one-shot event used as a **gate**: once it opens it stays open.
    ///
    /// Both `waitForExit` and the `defer`-ed `stop()` wait on the same events. A
    /// plain `DispatchSemaphore` is a counter, so the second waiter would block for
    /// its whole timeout on an event that has already happened, which is how every
    /// test in this suite silently cost fifteen seconds before this existed.
    /// Re-signalling makes the wait idempotent.
    private static func pass(_ gate: DispatchSemaphore, timeout: Double) -> Bool {
        guard gate.wait(timeout: .now() + timeout) == .success else { return false }
        gate.signal()
        return true
    }

    // MARK: Odds and ends

    private static let sequenceLock = NSLock()
    nonisolated(unsafe) private static var sequence = 0
    nonisolated(unsafe) private static var sigpipeIgnored = false

    private static func nextSequence() -> Int {
        sequenceLock.withLock {
            sequence += 1
            return sequence
        }
    }

    /// Writing to a pipe whose reader has exited raises SIGPIPE, whose default
    /// action would kill the *test runner*. A test that provokes an early exit
    /// must fail on an assertion, not take the suite down with it.
    private static func ignoreSIGPIPEOnce() {
        sequenceLock.withLock {
            guard !sigpipeIgnored else { return }
            sigpipeIgnored = true
            signal(SIGPIPE, SIG_IGN)
        }
    }
}

// MARK: - One parsed frame

/// A single JSON-RPC frame read off the server's stdout.
struct MCPFrame {

    /// The raw line, for failure messages.
    let line: String

    /// The parsed object.
    let object: [String: Any]

    init(line: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw MCPHarnessError.notJSON(line)
        }
        self.line = line
        self.object = object
    }

    var jsonrpc: String? { object["jsonrpc"] as? String }
    var id: Int? { object["id"] as? Int }
    var hasNullID: Bool { object["id"] is NSNull }
    var result: [String: Any]? { object["result"] as? [String: Any] }
    var error: [String: Any]? { object["error"] as? [String: Any] }
    var errorCode: Int? { error?["code"] as? Int }
    var errorMessage: String? { error?["message"] as? String }

    /// `result.isError`, which MCP requires on a `tools/call` result.
    var isError: Bool? { result?["isError"] as? Bool }

    /// The `result.content` array, when the shape is right.
    var contentBlocks: [[String: Any]]? { result?["content"] as? [[String: Any]] }

    /// `result.structuredContent`, the machine-readable half of an answer (CF-93).
    var structuredContent: [String: Any]? { result?["structuredContent"] as? [String: Any] }

    /// The text of a single well-formed text content block.
    var contentText: String? {
        guard let blocks = contentBlocks, blocks.count == 1,
              blocks[0]["type"] as? String == "text",
              let text = blocks[0]["text"] as? String
        else { return nil }
        return text
    }
}

// MARK: - A very small JSON Schema checker

/// Enough of JSON Schema to prove that what `tools/list` advertises is a real
/// schema and not a decorative dictionary.
///
/// Two jobs, both needed:
///
/// * ``structuralProblems(in:)``: is this *a schema*? Known `type`, `required`
///   entries that actually exist in `properties`, sane `minimum`/`minLength`.
/// * ``validate(_:against:)``: does the schema *do anything*? A tool schema that
///   accepts `{}` when it declares `query` required is broken, and only an
///   instance check catches it.
enum MiniSchema {

    private static let knownTypes: Set<String> = [
        "object", "array", "string", "integer", "number", "boolean", "null",
    ]

    /// Structural complaints about a schema. Empty means well formed.
    static func structuralProblems(in schema: Any, path: String = "$") -> [String] {
        guard let schema = schema as? [String: Any] else {
            return ["\(path): a schema must be a JSON object"]
        }
        var problems: [String] = []

        guard let rawType = schema["type"] else {
            return ["\(path): missing `type`"]
        }
        let declared: [String]
        if let single = rawType as? String {
            declared = [single]
        } else if let many = rawType as? [String] {
            declared = many.compactMap { $0 as String? }
        } else {
            return ["\(path): `type` must be a string or an array of strings"]
        }
        for type in declared where !knownTypes.contains(type) {
            problems.append("\(path): unknown type `\(type)`")
        }

        if let description = schema["description"], !(description is String) {
            problems.append("\(path): `description` must be a string")
        }

        if declared.contains("object") {
            var propertyNames: Set<String> = []
            if let properties = schema["properties"] {
                guard let properties = properties as? [String: Any] else {
                    problems.append("\(path): `properties` must be an object")
                    return problems
                }
                propertyNames = Set(properties.keys)
                for (name, sub) in properties.sorted(by: { $0.key < $1.key }) {
                    problems += structuralProblems(in: sub, path: "\(path).properties.\(name)")
                }
            }
            if let required = schema["required"] {
                guard let required = required as? [Any] else {
                    problems.append("\(path): `required` must be an array")
                    return problems
                }
                for entry in required {
                    guard let name = entry as? String else {
                        problems.append("\(path): `required` entries must be strings")
                        continue
                    }
                    // Only meaningful when the schema is closed: an open schema may
                    // legitimately require a property it does not describe.
                    if schema["additionalProperties"] as? Bool == false, !propertyNames.contains(name) {
                        problems.append("\(path): requires `\(name)`, which is not in `properties`")
                    }
                }
            }
            if let additional = schema["additionalProperties"], !(additional is Bool) {
                problems += structuralProblems(in: additional, path: "\(path).additionalProperties")
            }
        }

        if declared.contains("array"), let items = schema["items"] {
            problems += structuralProblems(in: items, path: "\(path).items")
        }

        for key in ["minLength", "maxLength"] {
            if let value = schema[key] {
                guard let number = value as? NSNumber, number.intValue >= 0 else {
                    problems.append("\(path): `\(key)` must be a non-negative integer")
                    continue
                }
            }
        }
        for key in ["minimum", "maximum"] where schema[key] != nil {
            if !(schema[key] is NSNumber) {
                problems.append("\(path): `\(key)` must be a number")
            }
        }
        if let minimum = schema["minimum"] as? NSNumber, let maximum = schema["maximum"] as? NSNumber,
           minimum.doubleValue > maximum.doubleValue {
            problems.append("\(path): `minimum` is above `maximum`")
        }
        if let fallback = schema["default"] {
            let bad = validate(fallback, against: schema, path: "\(path).default")
            problems += bad.map { "\(path): `default` does not satisfy its own schema (\($0))" }
        }

        return problems
    }

    /// Reasons `instance` fails `schema`. Empty means it validates.
    static func validate(_ instance: Any, against schema: Any, path: String = "$") -> [String] {
        guard let schema = schema as? [String: Any] else { return ["\(path): schema is not an object"] }
        var problems: [String] = []

        let declared: [String]
        if let single = schema["type"] as? String {
            declared = [single]
        } else if let many = schema["type"] as? [String] {
            declared = many
        } else {
            declared = []
        }
        if !declared.isEmpty, !declared.contains(where: { matches(instance, type: $0) }) {
            return ["\(path): expected \(declared.joined(separator: " or ")), got \(describe(instance))"]
        }

        if declared.contains("object"), let object = instance as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for entry in schema["required"] as? [Any] ?? [] {
                if let name = entry as? String, object[name] == nil {
                    problems.append("\(path): missing required `\(name)`")
                }
            }
            if schema["additionalProperties"] as? Bool == false {
                for key in object.keys.sorted() where properties[key] == nil {
                    problems.append("\(path): `\(key)` is not allowed")
                }
            }
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                if let sub = properties[key] {
                    problems += validate(value, against: sub, path: "\(path).\(key)")
                }
            }
        }

        if declared.contains("string"), let text = instance as? String {
            if let minimum = schema["minLength"] as? NSNumber, text.count < minimum.intValue {
                problems.append("\(path): shorter than minLength \(minimum.intValue)")
            }
            if let maximum = schema["maxLength"] as? NSNumber, text.count > maximum.intValue {
                problems.append("\(path): longer than maxLength \(maximum.intValue)")
            }
        }

        if let number = instance as? NSNumber, !(instance is String) {
            if let minimum = schema["minimum"] as? NSNumber, number.doubleValue < minimum.doubleValue {
                problems.append("\(path): below minimum \(minimum)")
            }
            if let maximum = schema["maximum"] as? NSNumber, number.doubleValue > maximum.doubleValue {
                problems.append("\(path): above maximum \(maximum)")
            }
        }

        return problems
    }

    private static func matches(_ instance: Any, type: String) -> Bool {
        switch type {
        case "object": return instance is [String: Any]
        case "array": return instance is [Any]
        case "string": return instance is String
        case "null": return instance is NSNull
        case "boolean":
            guard let number = instance as? NSNumber else { return false }
            return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
        case "integer":
            guard let number = instance as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else {
                return false
            }
            return number.doubleValue == number.doubleValue.rounded()
        case "number":
            guard let number = instance as? NSNumber else { return false }
            return CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID()
        default: return false
        }
    }

    private static func describe(_ instance: Any) -> String {
        switch instance {
        case is [String: Any]: return "object"
        case is [Any]: return "array"
        case is String: return "string"
        case is NSNull: return "null"
        case let number as NSNumber:
            return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() ? "boolean" : "number"
        default: return "\(Swift.type(of: instance))"
        }
    }
}

// MARK: - The world the MCP server reads

/// The seeded memory CF-31 and CF-33 assert against.
///
/// Everything is stamped from ``TestClock``, so the same rows appear whatever day
/// the suite runs. The titles are distinctive enough that finding one in a tool's
/// markdown proves the tool read the database rather than emitting a template.
enum MCPSeed {

    static let commitment = "Merge the rate limiter fix and deploy to staging"
    static let undatedCommitment = "Write up the migration notes and post them in the channel"
    static let person = "Priya Raman"
    static let project = "ACME-418 headcount rollup"
    static let decision = "Hold the pricing page rollout until the rate limiter is stable"

    /// The snippet stored as the commitment's provenance. It is a real substring of
    /// the Slack fixture, which is what makes the citation honest.
    static let commitmentSnippet = "I'll have the fix merged and deployed by Friday so QA gets a clean build."

    /// Newest capture in the seeded world; `today` renders its app name.
    static let newestCaptureApp = "Google Chrome"

    /// App name on the longest seeded session.
    static let busiestApp = "Slack"

    /// Writes the whole world into a real store.
    static func install(into store: Store) async throws {
        let captures = Fixtures.all()
        let slack = captures[0]

        let commitmentEntity = makeEntity(
            kind: .commitment,
            title: commitment,
            detail: "Blocked on the staging deploy; QA needs a clean build.",
            dueAt: TestClock.days(4),
            confidence: 0.8,
            at: TestClock.reference
        )
        let undatedEntity = makeEntity(
            kind: .commitment,
            title: undatedCommitment,
            detail: "Promised to Marco in #eng-platform.",
            confidence: 0.6,
            at: TestClock.reference
        )
        let personEntity = makeEntity(
            kind: .person,
            title: person,
            detail: "Platform engineer. Owns the rate limiter.",
            confidence: 0.9,
            pinned: true,
            at: TestClock.reference
        )
        let projectEntity = makeEntity(
            kind: .project,
            title: project,
            detail: "Blocked on Finance.",
            at: TestClock.reference
        )
        let decisionEntity = makeEntity(
            kind: .decision,
            title: decision,
            at: TestClock.reference
        )

        try await seed(
            store: store,
            captures: captures,
            entities: [commitmentEntity, undatedEntity, personEntity, projectEntity, decisionEntity],
            provenance: [
                makeProvenance(
                    entityID: commitmentEntity.id,
                    captureID: slack.id,
                    field: "title",
                    snippet: commitmentSnippet,
                    at: TestClock.reference
                ),
                makeProvenance(
                    entityID: personEntity.id,
                    captureID: slack.id,
                    field: "title",
                    snippet: "Priya Raman  10:04",
                    at: TestClock.reference
                ),
            ],
            sessions: [
                makeSession(
                    appName: busiestApp,
                    bundleID: "com.tinyspeck.slackmacgap",
                    from: TestClock.reference,
                    to: TestClock.minutes(40)
                ),
                makeSession(
                    appName: "Mail",
                    bundleID: "com.apple.mail",
                    from: TestClock.minutes(40),
                    to: TestClock.minutes(55)
                ),
                makeSession(
                    appName: "Screen Saver",
                    bundleID: "com.apple.ScreenSaver",
                    from: TestClock.minutes(55),
                    to: TestClock.minutes(70),
                    idle: true
                ),
            ]
        )
    }
}

// MARK: - Filesystem fingerprints (CF-33)

/// mtime, size and content hash of one file: everything CF-33 needs to say
/// "this was not written to".
struct FileFingerprint: Equatable, CustomStringConvertible {
    let name: String
    let exists: Bool
    let size: Int
    let modified: TimeInterval
    let digest: String

    static func of(_ url: URL) -> FileFingerprint {
        let manager = FileManager.default
        let name = url.lastPathComponent
        guard let attributes = try? manager.attributesOfItem(atPath: url.path) else {
            return FileFingerprint(name: name, exists: false, size: 0, modified: 0, digest: "-")
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let data = manager.contents(atPath: url.path) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return FileFingerprint(name: name, exists: true, size: size, modified: modified, digest: digest)
    }

    var description: String {
        exists ? "\(name) size=\(size) mtime=\(modified) sha256=\(digest.prefix(16))" : "\(name) (absent)"
    }
}

/// Row counts straight out of SQLite, bypassing every layer under test.
///
/// Opened `SQLITE_OPEN_READONLY`, and always called either before the "before"
/// fingerprint or after the "after" one, so the reader's own bookkeeping can
/// never be mistaken for the server writing.
func mcpRowCounts(at url: URL) -> [String: Int] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
        if let handle { sqlite3_close_v2(handle) }
        return [:]
    }
    defer { sqlite3_close_v2(handle) }

    var counts: [String: Int] = [:]
    for table in ["captures", "entities", "provenance", "sessions"] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM \"\(table)\"", -1, &statement, nil) == SQLITE_OK else {
            continue
        }
        if sqlite3_step(statement) == SQLITE_ROW {
            counts[table] = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
    }
    return counts
}

/// Creates a real SQLite database carrying a schema Memoir knows nothing about.
func makeForeignSchemaDatabase(at url: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let handle
    else {
        if let handle { sqlite3_close_v2(handle) }
        throw MCPHarnessError.sqlite("could not create \(url.path)")
    }
    defer { sqlite3_close_v2(handle) }
    let sql = """
    CREATE TABLE recipes (id TEXT PRIMARY KEY, title TEXT NOT NULL);
    INSERT INTO recipes (id, title) VALUES ('1', 'Not a capture');
    """
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
        let text = message.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(message)
        throw MCPHarnessError.sqlite(text)
    }
}

// MARK: - Shared launch helpers

/// A `HOME` for the child, inside the workspace. If `--db` ever stopped working,
/// the standard-location fallback would land here (an empty directory) rather
/// than on the user's real memory.
func mcpChildHome(_ ws: TestWorkspace) -> URL {
    ws.root.appendingPathComponent("child-home", isDirectory: true)
}

/// A `MEMOIR_DB_PATH` that resolves to nothing. Deliberately a decoy: only `--db`
/// may produce data, so a regression that ignored the flag fails the content
/// assertions instead of silently passing through the environment variable.
func mcpDecoyDatabasePath(_ ws: TestWorkspace) -> String {
    ws.root.appendingPathComponent("decoy-never-used.sqlite").path
}

/// Launches a server against a workspace, with the child fully boxed in.
func startMCPServer(
    _ ws: TestWorkspace,
    database: URL?,
    logLevel: String? = nil
) throws -> MCPServer {
    try MCPServer.start(
        database: database,
        home: mcpChildHome(ws),
        logLevel: logLevel,
        decoyDatabasePath: mcpDecoyDatabasePath(ws)
    )
}

/// Fails unless every line the server put on stdout is a JSON-RPC frame.
///
/// This is the assertion CF-32 exists for, and it is cheap enough to run at the
/// end of every MCP test: one stray `print()` anywhere in the server breaks all
/// of them at once, which is exactly the blast radius it deserves.
func expectPureJSONStdout(_ server: MCPServer, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(
        server.unterminatedTail == nil,
        "the server wrote a frame with no trailing newline: \(server.unterminatedTail ?? "")",
        sourceLocation: sourceLocation
    )
    for line in server.stdoutLines {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            Issue.record("stdout line is not a JSON object: \(line)", sourceLocation: sourceLocation)
            continue
        }
        #expect(
            object["jsonrpc"] as? String == "2.0",
            "stdout frame is not JSON-RPC 2.0: \(line)",
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - The flows

@Suite("CF-30…CF-34 · MCP contract (real binary, real subprocess)", .serialized)
struct MCPContractTests {

    // MARK: CF-30: Handshake

    @Test("CF-30 initialize, initialized and tools/list speak MCP 2025-06-18")
    func handshakeAndCatalogue() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }

            let initialize = try await server.handshake()
            let result = try #require(initialize.result, "initialize returned no result: \(initialize.line)")
            #expect(initialize.error == nil, "initialize must not fail: \(initialize.line)")
            #expect(result["protocolVersion"] as? String == "2025-06-18")

            let serverInfo = try #require(result["serverInfo"] as? [String: Any])
            #expect(serverInfo["name"] as? String == "memoir")
            #expect((serverInfo["version"] as? String)?.isEmpty == false)

            let capabilities = try #require(result["capabilities"] as? [String: Any])
            #expect(capabilities["tools"] != nil, "a server advertising tools must say so in capabilities")

            // The `initialized` notification carries no id and must produce no frame.
            // Proven by the next frame being the answer to id 2, not to the notification.
            let list = try await server.request("tools/list", id: 2)
            #expect(list.error == nil, "tools/list must not fail: \(list.line)")

            let tools = try #require((list.result?["tools"]) as? [[String: Any]])
            #expect(tools.count == 13, "the contract is exactly thirteen tools, got \(tools.count)")

            let names = tools.compactMap { $0["name"] as? String }
            #expect(
                Set(names) == [
                    "recall", "who_is", "what_happened", "open_commitments", "today",
                    "what_changed_since", "prior_art", "working_set", "sources_for", "verify",
                    "timesheet", "propose_memory", "coverage",
                ],
                "tool names drifted: \(names.sorted())"
            )

            for tool in tools {
                let name = (tool["name"] as? String) ?? "?"
                #expect((tool["description"] as? String)?.isEmpty == false, "\(name) has no description")

                let schema = try #require(tool["inputSchema"], "\(name) has no inputSchema")

                // "Actually parses": round-trip it through JSONSerialization. A schema
                // that cannot be re-encoded is not a schema a client could ever use.
                #expect(
                    JSONSerialization.isValidJSONObject(schema),
                    "\(name).inputSchema is not a serialisable JSON object"
                )
                let reparsed = try JSONSerialization.jsonObject(
                    with: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
                )

                let problems = MiniSchema.structuralProblems(in: reparsed)
                #expect(problems.isEmpty, "\(name).inputSchema is not a valid JSON Schema: \(problems.joined(separator: "; "))")
                #expect((reparsed as? [String: Any])?["type"] as? String == "object", "\(name).inputSchema must describe an object")
            }

            // The schemas must actually constrain something, or `tools/list` is decoration.
            let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool -> (String, Any)? in
                guard let name = tool["name"] as? String, let schema = tool["inputSchema"] else { return nil }
                return (name, schema)
            })

            let recall = try #require(byName["recall"])
            #expect(MiniSchema.validate(["query": "rate limiter"], against: recall).isEmpty)
            #expect(MiniSchema.validate(["query": "rate limiter", "limit": 5], against: recall).isEmpty)
            #expect(!MiniSchema.validate([String: Any](), against: recall).isEmpty, "recall must require `query`")
            #expect(!MiniSchema.validate(["query": "x", "limit": "5"], against: recall).isEmpty, "`limit` is an integer")
            #expect(!MiniSchema.validate(["query": "x", "sneaky": 1], against: recall).isEmpty, "recall is a closed schema")

            let whoIs = try #require(byName["who_is"])
            #expect(MiniSchema.validate(["name": "Priya"], against: whoIs).isEmpty)
            #expect(!MiniSchema.validate([String: Any](), against: whoIs).isEmpty, "who_is must require `name`")

            let whatHappened = try #require(byName["what_happened"])
            #expect(MiniSchema.validate(["from": "2026-03-01", "to": "2026-03-31"], against: whatHappened).isEmpty)
            #expect(!MiniSchema.validate(["from": "2026-03-01"], against: whatHappened).isEmpty, "`to` is required")

            for name in ["open_commitments", "today"] {
                let schema = try #require(byName[name])
                #expect(MiniSchema.validate([String: Any](), against: schema).isEmpty, "\(name) takes no arguments")
            }

            // `--db` was honoured: the server said so on stderr, and it named our file.
            let status = await server.waitForExit()
            #expect(status == 0, "the server must exit cleanly when stdin closes, got \(String(describing: status))")
            #expect(
                server.stderrText.contains("db=\(ws.dbURL.path)"),
                "the server did not open the database it was pointed at:\n\(server.stderrText)"
            )
            expectPureJSONStdout(server)
        }
    }

    // MARK: CF-31: Every tool answers

    @Test("CF-31 the original five tools answer with real content from a seeded database")
    func everyToolAnswers() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            /// Shared shape check: MCP content blocks, no error, non-empty text.
            func answer(
                _ name: String,
                _ arguments: [String: Any],
                id: Int,
                sourceLocation: SourceLocation = #_sourceLocation
            ) async throws -> String {
                let frame = try await server.callTool(name, arguments: arguments, id: id, sourceLocation: sourceLocation)
                #expect(frame.error == nil, "\(name) returned a protocol error: \(frame.line)", sourceLocation: sourceLocation)
                #expect(frame.isError == false, "\(name) set isError: \(frame.line)", sourceLocation: sourceLocation)
                let blocks = try #require(frame.contentBlocks, "\(name) returned no content array", sourceLocation: sourceLocation)
                #expect(blocks.count == 1, "\(name) should answer in one block", sourceLocation: sourceLocation)
                let text = try #require(frame.contentText, "\(name) content block is malformed: \(frame.line)", sourceLocation: sourceLocation)
                #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name) answered with nothing", sourceLocation: sourceLocation)
                #expect(
                    !text.hasPrefix("Memoir's memory is not available"),
                    "\(name) could not see the seeded database. Was --db honoured?",
                    sourceLocation: sourceLocation
                )
                return text
            }

            // recall: entities, captures and the provenance that ties them together.
            let recall = try await answer("recall", ["query": "rate limiter", "limit": 10], id: 10)
            #expect(recall.contains("# Recall: rate limiter"))
            #expect(recall.contains(MCPSeed.commitment), "recall did not surface the seeded commitment:\n\(recall)")
            #expect(recall.contains("## Where it was seen"), "recall must cite where it saw things")
            #expect(recall.contains("Slack"), "recall did not cite the Slack capture:\n\(recall)")
            #expect(recall.contains("Seen in:"), "recall must render provenance for an entity that has it")
            #expect(recall.contains(MCPSeed.commitmentSnippet), "the cited snippet must be the stored one")

            // who_is: the person dossier, matched on a fragment of the name.
            let whoIs = try await answer("who_is", ["name": "Priya"], id: 11)
            #expect(whoIs.contains(MCPSeed.person), "who_is did not find the seeded person:\n\(whoIs)")
            #expect(whoIs.contains("Platform engineer"), "who_is dropped the person's detail")
            #expect(whoIs.contains("Recent mentions"), "who_is must show where the name was seen")

            // what_happened: an explicit range, wide enough to hold in any timezone.
            let whatHappened = try await answer("what_happened", ["from": "2026-03-01", "to": "2026-03-31"], id: 12)
            // Answer first (CF-92): the lead sentence carries the total and the app it went
            // on, and the breakdown follows it. What must never change is that the time is
            // reported, the real app is named, and idle is not counted as work.
            #expect(whatHappened.contains("active"), "what_happened must report time spent:\n\(whatHappened)")
            #expect(whatHappened.contains(MCPSeed.busiestApp), "what_happened lost the Slack session")
            #expect(whatHappened.contains("Screen Saver") == false, "idle sessions must not count as active time")
            #expect(whatHappened.contains("## What the time went on"), "what_happened must break the time down by work")
            #expect(whatHappened.contains("## New in this window"), "what_happened must list what appeared in range")
            #expect(whatHappened.contains(MCPSeed.project), "what_happened lost a seeded entity")

            // open_commitments: dated and undated both have to appear.
            let commitments = try await answer("open_commitments", [:], id: 13)
            #expect(commitments.contains("# Open commitments"))
            #expect(commitments.contains(MCPSeed.commitment), "the dated commitment is missing:\n\(commitments)")
            #expect(commitments.contains(MCPSeed.undatedCommitment), "the undated commitment is missing:\n\(commitments)")
            #expect(!commitments.contains(MCPSeed.person), "open_commitments must not leak other entity kinds")

            // today: the clock-dependent halves are deliberately not asserted; the
            // "most recently seen" tail is a plain ORDER BY ts DESC and always holds.
            let today = try await answer("today", [:], id: 14)
            #expect(today.hasPrefix("# Today"), "today must render its header:\n\(today)")
            #expect(today.contains("## Most recently seen"), "today must show recent activity")
            #expect(today.contains(MCPSeed.newestCaptureApp), "today lost the newest capture:\n\(today)")

            // An unknown tool is a protocol error, not a content block.
            let unknown = try await server.callTool("definitely_not_a_tool", id: 15)
            let error = try #require(unknown.error, "an unknown tool must be a JSON-RPC error: \(unknown.line)")
            #expect(unknown.errorCode == -32601, "expected methodNotFound, got \(String(describing: error["code"]))")
            #expect(unknown.result == nil, "an error frame must not also carry a result")

            let status = await server.waitForExit()
            #expect(status == 0, "clean exit expected, got \(String(describing: status))")
            expectPureJSONStdout(server)
        }
    }

    @Test("CF-31 recall obeys the limit its own schema advertises")
    func recallHonoursAdvertisedLimit() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // Sixty captures carrying a token that appears nowhere else, so every
            // matching row is one this test put there and the count is exact.
            let token = "widgetronic"
            let haystack: [CaptureEvent] = (0..<60).map { index in
                Fixtures.capture(
                    text: "Ticket \(index): the \(token) subsystem needs a look before the review.",
                    app: "Linear",
                    bundleID: "com.linear",
                    windowTitle: "Backlog",
                    at: TestClock.minutes(Double(index)),
                    name: "limit-\(index)"
                )
            }
            try await seed(store: store, captures: haystack)
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            // The numbers come from the catalogue, not from this file. The flow being
            // tested is "the schema tells the truth", so hardcoding them here would
            // test nothing: both sides could drift together.
            let list = try await server.request("tools/list", id: 2)
            let tools = try #require((list.result?["tools"]) as? [[String: Any]])
            let recallSchema = try #require(
                tools.first { $0["name"] as? String == "recall" }?["inputSchema"] as? [String: Any]
            )
            let limitSchema = try #require((recallSchema["properties"] as? [String: Any])?["limit"] as? [String: Any])
            let advertisedDefault = try #require((limitSchema["default"] as? NSNumber)?.intValue)
            let advertisedMaximum = try #require((limitSchema["maximum"] as? NSNumber)?.intValue)
            let advertisedMinimum = try #require((limitSchema["minimum"] as? NSNumber)?.intValue)
            #expect(advertisedMaximum <= haystack.count, "the fixture must be able to satisfy the advertised maximum")

            /// Counts the capture citations. Entity blocks render provenance as
            /// `- app · …`; only captures are bolded, so this cannot over-count.
            func citedCaptures(in text: String) throws -> Int {
                let parts = text.components(separatedBy: "## Where it was seen")
                #expect(parts.count == 2, "recall did not render its citations section:\n\(text)")
                guard parts.count == 2 else { return 0 }
                return parts[1]
                    .split(separator: "\n")
                    .filter { $0.hasPrefix("- **") }
                    .count
            }

            let byDefault = try #require(
                try await server.callTool("recall", arguments: ["query": token], id: 10).contentText
            )
            let defaultCount = try citedCaptures(in: byDefault)
            #expect(
                defaultCount == advertisedDefault,
                "recall's schema promises a default of \(advertisedDefault), the server returned \(defaultCount)"
            )

            let atMaximum = try #require(
                try await server.callTool("recall", arguments: ["query": token, "limit": advertisedMaximum], id: 11).contentText
            )
            let maximumCount = try citedCaptures(in: atMaximum)
            #expect(
                maximumCount == advertisedMaximum,
                "recall's schema allows a limit of \(advertisedMaximum), the server returned \(maximumCount)"
            )

            let atMinimum = try #require(
                try await server.callTool("recall", arguments: ["query": token, "limit": advertisedMinimum], id: 12).contentText
            )
            #expect(try citedCaptures(in: atMinimum) == advertisedMinimum)

            // Out-of-range input is clamped rather than rejected: an agent that
            // over-asks still gets an answer, and never more than the advertised cap.
            let overAsk = try #require(
                try await server.callTool("recall", arguments: ["query": token, "limit": 5_000], id: 13).contentText
            )
            #expect(try citedCaptures(in: overAsk) == advertisedMaximum, "an over-large limit must clamp to the cap")

            let status = await server.waitForExit()
            #expect(status == 0, "clean exit expected, got \(String(describing: status))")
            expectPureJSONStdout(server)
        }
    }

    @Test("CF-31 a citation quotes what was read, not the navigation menu around it")
    func recallQuotesContentNotChrome() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // A social feed as the accessibility tree actually returns one: a stack of
            // short navigation lines carrying the site's own vocabulary, and only then the
            // thing the user was reading. The real capture that prompted this test opened
            // with 712 characters of exactly this and put the post at 14,605.
            let chrome = """
                Feed | LinkedIn
                0 notifications
                Skip navigation menu
                LinkedIn
                Home
                My Network, 0 new notifications
                Jobs, 0 new notifications
                Messaging, 2 new notifications
                Start a post
                Post impressions
                """
            let body = """
                Meta just pulled the biggest reversal in open-weight models this year, and \
                the reasoning behind it is more interesting than the benchmark table anyone \
                is going to screenshot. Distillation from a much larger teacher is the part \
                worth reading twice, because it changes what a thirty-billion parameter \
                model is allowed to be good at.
                """
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: chrome + "\n" + body,
                    app: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: "Feed | LinkedIn",
                    at: TestClock.minutes(1),
                    name: "feed"
                ),
            ])
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            // Every word of this query appears in the navigation and none of it appears in
            // the post: the shape of "what was that LinkedIn post", and the shape that
            // used to return a menu. The snippet is scored, so the discounted chrome
            // matches lose to the prose that has no query term in it at all.
            let text = try #require(
                try await server.callTool(
                    "recall", arguments: ["query": "linkedin feed post"], id: 10
                ).contentText
            )
            let citation = try #require(
                text.components(separatedBy: "## Where it was seen").last?
                    .split(separator: "\n")
                    .first { $0.contains("> ") },
                "recall did not render a capture citation:\n\(text)"
            )

            #expect(
                citation.contains("open-weight models"),
                "the citation must quote what was read, got:\n\(citation)"
            )
            #expect(
                !citation.contains("Skip navigation menu"),
                "the citation quoted the navigation menu instead of the post:\n\(citation)"
            )

            let status = await server.waitForExit()
            #expect(status == 0, "clean exit expected, got \(String(describing: status))")
            expectPureJSONStdout(server)
        }
    }

    /// The same law, on the three tools that were quoting the whole accessibility tree.
    ///
    /// `recall` and `who_is` were built with `Fmt.citation` from the start. `sources_for`,
    /// `verify` and `prior_art` were built with `Fmt.snippet` forty lines away and nobody
    /// noticed, so the two tools whose entire job is evidence — and the one an agent calls to
    /// decide whether the user has been here before — quoted text that was never in frame.
    /// Measured on a real vault: across captures where the viewport was known, only about
    /// half of stored characters were inside the window.
    /// A mail title is a person's name, and nothing was checking.
    ///
    /// A mail client and a messenger put the correspondent in the window title, so the subject
    /// of a screen becomes whoever wrote to you. The six-word cap does not reach it and the
    /// address rule does not either: a name is four words and has no @ in it.
    ///
    /// Nothing had to be inferred. Memoir already holds the people — 191 imported from the
    /// address book on a real machine — and no reader had ever thought to check a subject
    /// against them. Full names only, two tokens or more, because a bare first name is a name
    /// for everyone who has it and redacting on one would hollow out ordinary titles.
    @Test("CF-39 a correspondent's name never becomes the subject of a screen")
    func namesAreNotSubjects() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            let start = cal.startOfDay(for: TestClock.reference).addingTimeInterval(10 * 3600)

            try await store.upsert(entity: Entity(
                kind: .person, title: "Ingrid Halvorsen", source: .authored))
            // A first name alone must NOT redact, or every ordinary title loses a word.
            try await store.upsert(entity: Entity(
                kind: .person, title: "Chrome", source: .authored))

            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: "a mail thread with a reasonable amount of body text in it",
                    app: "Microsoft Outlook", bundleID: "com.microsoft.Outlook",
                    windowTitle: "Ingrid Halvorsen - Q3 handover - Outlook",
                    at: start.addingTimeInterval(60), name: "mail"),
                Fixtures.capture(
                    text: "a page of documentation with a reasonable amount of text",
                    app: "Microsoft Outlook", bundleID: "com.microsoft.Outlook",
                    windowTitle: "Deployment checklist - Outlook",
                    at: start.addingTimeInterval(600), name: "doc"),
            ], sessions: [
                makeSession(appName: "Microsoft Outlook", bundleID: "com.microsoft.Outlook",
                            from: start, to: start.addingTimeInterval(1200)),
            ])
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withFullDate]
            let key = iso.string(from: TestClock.reference)
            let text = try #require(
                try await server.callTool(
                    "what_happened", arguments: ["from": key, "to": key], id: 98).contentText)

            #expect(!text.contains("Ingrid Halvorsen"), "a correspondent was named:\n\(text)")
            #expect(text.contains("[someone]"), "the name was dropped rather than marked:\n\(text)")
            // The rest of the title survives — the subject is still legible.
            #expect(text.contains("Q3 handover"), "the whole subject was destroyed:\n\(text)")
            // And a one-word person name redacts nothing.
            #expect(text.contains("Deployment checklist"),
                    "a single-token person name hollowed out an ordinary title:\n\(text)")

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    /// A dialog is a thing that happens to you. A page is a thing you go to.
    ///
    /// Two earlier attempts to keep sign-in sheets, permission prompts and "this extension is
    /// disabled" banners out of a subject ranking both had to be thrown away. One keyed on how
    /// long a screen was held, the other on how often it repeated, and under either rule a
    /// four-second glance at something private and a pass-through dialog are the same event —
    /// so both deleted a wedding venue and a streaming page along with the junk.
    ///
    /// Bracketing is not the same measurement. An interruption is *defined* by your going back
    /// to what you were doing, so the screen either side of it is the same screen. Measured on
    /// a real vault the offenders score 45 to 75 per cent against a corpus base of 4.8, while
    /// the wedding venues score 0, the job board 0, the gym 3 and the anime 1.
    @Test("CF-38 a screen you were interrupted by is not a thing you were doing")
    func interruptingScreensAreNotSubjects() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            let start = cal.startOfDay(for: TestClock.reference).addingTimeInterval(10 * 3600)
            var captures: [CaptureEvent] = []
            var t = 0.0
            func add(_ title: String) {
                captures.append(Fixtures.capture(
                    text: "page content of a reasonable length for a real screen",
                    app: "Google Chrome", bundleID: "com.google.Chrome", windowTitle: title,
                    at: start.addingTimeInterval(t), name: "c\(captures.count)"))
                t += 60
            }
            // Seven interruptions: the banner appears and the same page comes back. And a
            // real destination visited the same number of times, always moved on from.
            for i in 0..<7 {
                add("Working page \(i)")
                add("Some Extension is disabled")
                add("Working page \(i)")
                add("Venue in Ravensmoor")
                add("Next thing \(i)")
            }
            try await seed(store: store, captures: captures, sessions: [
                makeSession(appName: "Google Chrome", bundleID: "com.google.Chrome",
                            from: start, to: start.addingTimeInterval(t + 60)),
            ])
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withFullDate]
            let key = iso.string(from: TestClock.reference)
            let text = try #require(
                try await server.callTool(
                    "what_happened", arguments: ["from": key, "to": key], id: 97).contentText)

            #expect(!text.contains("Some Extension is disabled"),
                    "an interruption was reported as something the user was doing:\n\(text)")
            // And the thing seen exactly as often, that was never returned from, survives.
            #expect(text.contains("Venue in Ravensmoor"),
                    "a real destination was deleted with the junk:\n\(text)")

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    /// A subject key is a thing, and an address is a person.
    ///
    /// A mail client puts the account in its window title, so the first real run of a ranked
    /// subject table printed the user's own email address as a row key — exactly where an
    /// earlier review had predicted it would appear. That table has since been cut by its own
    /// ablation gate, but the defect was never the table's: `Fmt.screenSubject` is what every
    /// tool reads a subject through, and it was handing addresses to all of them.
    ///
    /// The rule is structural rather than a list, because a list of the user's own addresses
    /// is one this product must not hold and would miss every other person's anyway. It also
    /// catches a correspondent's address in a thread title and a `user@host` shell prompt.
    @Test("CF-37 a subject read off a window title never carries an address")
    func subjectsNeverCarryAddresses() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            let start = cal.startOfDay(for: TestClock.reference).addingTimeInterval(10 * 3600)

            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: "an inbox listing with a good deal of text in it",
                    app: "Google Chrome", bundleID: "com.google.Chrome",
                    windowTitle: "Posta in arrivo - someone@example.com - Gmail",
                    at: start.addingTimeInterval(60), name: "mail"),
                Fixtures.capture(
                    text: "a terminal session with a good deal of text in it",
                    app: "Terminal", bundleID: "com.apple.Terminal",
                    windowTitle: "person@somehost ~",
                    at: start.addingTimeInterval(600), name: "shell"),
            ], sessions: [
                makeSession(appName: "Google Chrome", bundleID: "com.google.Chrome",
                            from: start, to: start.addingTimeInterval(900)),
            ])
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withFullDate]
            let key = iso.string(from: TestClock.reference)
            let text = try #require(
                try await server.callTool(
                    "what_happened", arguments: ["from": key, "to": key], id: 96).contentText)

            #expect(!text.contains("someone@example.com"), "an address was printed:\n\(text)")
            #expect(!text.contains("person@somehost"), "a shell prompt address was printed:\n\(text)")

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    /// A quiet evening and an evening nobody watched are the same absence.
    ///
    /// Every coverage number this product produced before collapsed "Memoir was running and the
    /// screen was idle" with "no session at all". The first is evidence the instrument was
    /// there; the second is evidence of nothing whatsoever. Reading them as one is how "you did
    /// nothing on Tuesday" and "I was not looking on Tuesday" came to sound the same.
    ///
    /// Measured on a real vault: 11.0% of the clock watched over 28 days, zero between 1am and
    /// 7am, and 100% not running at 5pm — because the laptop was shut, which no capture change
    /// reaches. That is the fact this tool exists to state.
    @Test("CF-36 coverage separates idle from not-running, and says what it did not see")
    func coverageSeparatesIdleFromAbsent() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            let day = cal.startOfDay(for: TestClock.reference)
            func at(_ hour: Int, _ minute: Int = 0) -> Date {
                cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
            }

            // 10:00–11:00 somebody is working. 14:00–15:00 the screensaver is up and Memoir is
            // watching it. Everything else is nothing at all.
            try await store.upsert(session: Session(
                appBundleID: "com.apple.dt.Xcode", appName: "Xcode",
                startedAt: at(10), endedAt: at(11)))
            try await store.upsert(session: Session(
                appBundleID: "com.apple.ScreenSaver", appName: "Screen Saver",
                startedAt: at(14), endedAt: at(15), idle: true))
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withFullDate]
            let key = iso.string(from: day)
            let text = try #require(
                try await server.callTool(
                    "coverage", arguments: ["from": key, "to": key], id: 95).contentText)

            func row(_ label: String) -> String? {
                text.split(separator: "\n").first { $0.hasPrefix("| \(label) ") }.map(String.init)
            }

            // The working hour is active, not idle.
            let ten = try #require(row("10"), "no row for 10:00 in:\n\(text)")
            #expect(ten.contains("100%"), "the worked hour was not reported as covered: \(ten)")

            // The screensaver hour is IDLE and NOT counted as absent — Memoir was there.
            let fourteen = try #require(row("14"), "no row for 14:00 in:\n\(text)")
            let cells = fourteen.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(cells.count >= 4, "unexpected row shape: \(fourteen)")
            #expect(cells[1] == "—", "an idle hour was reported as active: \(fourteen)")
            #expect(cells[2] == "100%", "an idle hour was not reported as idle: \(fourteen)")
            #expect(cells[3] == "—", "an hour Memoir watched was reported as not running: \(fourteen)")

            // And the hours nothing was recorded say so, collapsed rather than repeated.
            #expect(text.contains("100%"), "no hour was reported as unwatched")
            #expect(text.contains("evidence of nothing"),
                    "the tool did not state what an absence means:\n\(text.suffix(400))")

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    /// One page counted as many, because its unread badge moved.
    ///
    /// `Fmt.screenSubject` stripped a bracketed unread count only when it sat at the very
    /// front of the title. Sites put it elsewhere — after the site name, between separators —
    /// and every value of the counter produced a different-looking subject. Measured on a real
    /// vault, one page fragmented into 32 separate subjects, taking its day count with it,
    /// which is precisely the number a returned-to ranking is built on: a page visited on six
    /// days looks like six pages visited once.
    ///
    /// Driven through the real binary because the subject normaliser lives in the MCP target
    /// and cannot be imported by a test.
    @Test("CF-34 an unread badge does not split one page into several")
    func unreadBadgeDoesNotSplitASubject() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // The same page, six times, with the counter moving. One subject, six sightings.
            var rows: [CaptureEvent] = []
            for (i, badge) in ["", "(1) ", "(12) ", "(7) ", "(3) ", "(21) "].enumerated() {
                rows.append(Fixtures.capture(
                    text: "a long stretch of page content that is the same every time",
                    app: "Google Chrome", bundleID: "com.google.Chrome",
                    windowTitle: "\(badge)Messaging | Fenwick Migration - Google Chrome",
                    at: TestClock.minutes(Double(i * 3 + 1)), name: "badge-\(i)"))
            }
            // And a mid-string badge, the shape that was never handled at all.
            rows.append(Fixtures.capture(
                text: "a long stretch of page content that is the same every time",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Messaging (9) | Fenwick Migration - Google Chrome",
                at: TestClock.minutes(25), name: "badge-mid"))
            let session = makeSession(
                appName: "Google Chrome", bundleID: "com.google.Chrome",
                from: TestClock.minutes(0), to: TestClock.minutes(30))
            try await seed(store: store, captures: rows, sessions: [session])
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withFullDate]
            let key = iso.string(from: TestClock.reference)
            let text = try #require(
                try await server.callTool(
                    "what_happened", arguments: ["from": key, "to": key], id: 90).contentText)

            // The subject appears once, not seven times, and carries no counter.
            let mentions = text.components(separatedBy: "Fenwick Migration").count - 1
            #expect(mentions <= 2, "one page was reported as \(mentions) subjects:\n\(text.prefix(700))")
            for badge in ["(1)", "(12)", "(7)", "(3)", "(21)", "(9)"] {
                #expect(!text.contains(badge), "the unread counter \(badge) reached the answer")
            }

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    /// The user's own words had never once reached an answer.
    ///
    /// A journal entry and a note pushed from the chat were structurally identical rows — same
    /// kind, same authored source, same confidence, same null detail — so nothing could ask for
    /// the journal. It reached `what_happened` only through the generic "New in this window"
    /// list, sorted against every other entity by a column that means *last seen* for an
    /// inferred row, and capped at eight. Measured on the real vault, the six entries ranked
    /// 20th, 149th, 15th, 53rd, 42nd and 97th inside their own days. None of them ever showed.
    ///
    /// Schema v12 gives the act its own column, and the answer leads with it.
    @Test("CF-32 what_happened leads with what the user wrote")
    func whatHappenedLeadsWithTheJournal() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let service = MemoryService(store: store, extractors: [])
            let day = TestClock.reference

            // The entry, and a wall of inferred rows to bury it under — the real vault had 104
            // entities competing for eight slots on the day this was found.
            _ = try await service.writeEntry("Long call with the venue. Said yes.", filedAt: day, now: day)
            for i in 0..<40 {
                try await store.upsert(entity: Entity(
                    kind: .commitment, title: "inferred noise \(i)",
                    createdAt: day, updatedAt: day))
            }
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withFullDate]
            let key = iso.string(from: day)
            let text = try #require(
                try await server.callTool(
                    "what_happened", arguments: ["from": key, "to": key], id: 80).contentText)

            #expect(text.contains("What you wrote"), "the journal section is missing:\n\(text.prefix(400))")
            #expect(text.contains("Long call with the venue"),
                    "the entry was not quoted:\n\(text.prefix(600))")

            // It leads. Whatever else the day holds, the user's sentence comes before Memoir's
            // reconstruction of it.
            let wroteAt = text.range(of: "What you wrote")
            let timeAt = text.range(of: "What the time went on")
            if let wroteAt, let timeAt {
                #expect(wroteAt.lowerBound < timeAt.lowerBound,
                        "Memoir's own reconstruction came before the user's words")
            }

            // A day with nothing written renders no section rather than an empty one.
            let quiet = iso.string(from: TestClock.days(-30))
            let none = try #require(
                try await server.callTool(
                    "what_happened", arguments: ["from": quiet, "to": quiet], id: 81).contentText)
            #expect(!none.contains("What you wrote"),
                    "an empty journal section was rendered:\n\(none.prefix(300))")

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    /// A memory that cannot tell two people apart must say so.
    ///
    /// `who_is` rendered `people.first` and stopped. Asking about a common first name returned
    /// one record with no hint that others existed — the real count survived only in a
    /// structured field nothing displays. Answering as though there is one person when the
    /// memory holds three is not brevity, it is a wrong answer the reader cannot detect.
    @Test("CF-35 who_is names every person it cannot tell apart")
    func whoIsAdmitsAmbiguity() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // Three people who share a first name, which is the ordinary case, not a corner.
            for (full, alias) in [
                ("David Okonkwo", "Dave from the gym"),
                ("David Lindqvist", ""),
                ("David Serra", ""),
            ] {
                try await store.upsert(entity: Entity(
                    kind: .person, title: full, source: .authored,
                    aliases: alias.isEmpty ? [] : [alias]))
            }
            let text = "a message from David about Thursday"
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: text, app: "Mail", bundleID: "com.apple.mail",
                    windowTitle: "Inbox", at: TestClock.minutes(1), name: "david"),
            ])
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let out = try #require(
                try await server.callTool("who_is", arguments: ["name": "David"], id: 70).contentText)

            #expect(out.contains("3 people"), "the count was not stated:\n\(out.prefix(200))")
            #expect(out.contains("cannot tell them apart"), "the limit was not stated")
            for full in ["David Okonkwo", "David Lindqvist", "David Serra"] {
                #expect(out.contains(full), "\(full) was not rendered:\n\(out.prefix(400))")
            }
            // And the alias is shown, because it is what let a mention attach to one record
            // rather than another.
            #expect(out.contains("also called"), "the alias was not surfaced")

            // One person is still answered as one person, with no ambiguity language.
            let single = try #require(
                try await server.callTool(
                    "who_is", arguments: ["name": "Okonkwo"], id: 71).contentText)
            #expect(!single.contains("cannot tell them apart"),
                    "an unambiguous name was reported as ambiguous:\n\(single.prefix(200))")

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    /// `verify` certified claims from words that were never in the same sentence.
    ///
    /// The test was "every distinctive word appears somewhere in this capture", and a capture
    /// is a whole accessibility tree — navigation, sidebar, footer, and two thousand characters
    /// of page in between. Two words at opposite ends of a page neither of them was about
    /// passed, and the tool whose entire job is evidence had the loosest test in the product.
    ///
    /// Bounded and whole-word now. Still not entailment: words near each other on a screen is
    /// not the screen asserting the sentence, which is why the wording changed too.
    @Test("CF-34 verify does not certify words that merely share a page")
    func verifyRequiresCoOccurrence() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // One page. The two words are real and far apart, in unrelated sections.
            let filler = String(repeating: "unrelated filler sentence about other matters. ", count: 40)
            let sprawl = "quarterly budget approved by finance. " + filler
                + "elsewhere on this page, a note about the kubernetes migration."
            // A second page where the same two words are actually in one sentence.
            let together = "the kubernetes budget was approved on Tuesday."

            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: sprawl, app: "Google Chrome", bundleID: "com.google.Chrome",
                    windowTitle: "wiki", at: TestClock.minutes(1), name: "sprawl"),
                Fixtures.capture(
                    text: together, app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                    windowTitle: "team", at: TestClock.minutes(2), name: "together"),
            ])
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            // The claim's two distinctive words exist on the sprawling page, far apart. They
            // also exist together on the Slack line. Only the second is evidence of anything.
            let text = try #require(
                try await server.callTool(
                    "verify", arguments: ["claim": "kubernetes budget"], id: 60).contentText)

            #expect(!text.contains("Not in the record"), "the real co-occurrence was missed:\n\(text)")
            #expect(text.contains("Slack"), "the screen that carries both words was not cited:\n\(text)")
            let cited = text.split(separator: "\n").filter { $0.contains("> ") }
            let fromSprawl = cited.filter { $0.contains("unrelated filler") || $0.contains("quarterly") }
            #expect(
                fromSprawl.isEmpty,
                "a page where the words merely coexist was cited as evidence: \(fromSprawl.count) of \(cited.count)"
            )

            // Substring co-presence is gone too: "budge" is not "budget".
            let substring = try #require(
                try await server.callTool(
                    "verify", arguments: ["claim": "kubernete budge"], id: 61).contentText)
            #expect(substring.contains("Not in the record"),
                    "a partial word still certified a claim:\n\(substring.prefix(200))")

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    /// Rarity has to be measured against this life, not against English.
    ///
    /// `distinctiveTerms` is a stopword list. It knows "the" is common and has no idea that on
    /// a given machine one word sits on every screen its owner has ever looked at. So that word
    /// stayed in the query, and when the real subject of the question was nowhere in the
    /// record, the fallback OR search happily returned forty screens of wallpaper — an answer
    /// made entirely of the term that discriminates nothing.
    ///
    /// Measured on a real vault, this is not hypothetical: the product's own name appeared in
    /// 20.1% of every capture, "architecture" in 6.1%, while a ticket key central to months of
    /// work sat at 3.5%. Rarity in English ranks those in exactly the wrong order.
    @Test("CF-33 recall ranks by rarity in this corpus, not rarity in English")
    func recallRanksByCorpusRarity() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // Forty screens, all carrying the same saturating word. None of them is about
            // anything else.
            var rows: [CaptureEvent] = []
            for i in 0..<40 {
                rows.append(Fixtures.capture(
                    text: "workspace dashboard panel", app: "Google Chrome",
                    bundleID: "com.google.Chrome", windowTitle: "workspace",
                    at: TestClock.minutes(Double(i + 1)), name: "rank-\(i)"))
            }
            try await seed(store: store, captures: rows)
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            // A question about something the record does not contain, phrased with a word the
            // record contains constantly. The honest answer is "nothing matched".
            let text = try #require(
                try await server.callTool(
                    "recall", arguments: ["query": "workspace quinta"], id: 50).contentText)

            let quoted = text.split(separator: "\n").filter { $0.contains("> ") }
            let wallpaper = quoted.prefix(3).joined(separator: "\n")
            #expect(
                quoted.isEmpty,
                "recall answered a question about something absent with \(quoted.count) screens of the one word that discriminates nothing:\n\(wallpaper)"
            )
            #expect(text.contains("Nothing in Memoir's memory matches"),
                    "the honest answer was not given:\n\(text.prefix(300))")

            // And it says what it looked for, which is now the discriminating word alone.
            if let looked = text.components(separatedBy: "Looked for: ").dropFirst().first {
                #expect(!looked.hasPrefix("workspace"),
                        "the saturating term is still steering the search: \(looked.prefix(40))")
            }

            // The control: a term the corpus does carry is still found. Dropping the common
            // word must not turn recall into a machine that answers nothing.
            let present = try #require(
                try await server.callTool(
                    "recall", arguments: ["query": "dashboard panel"], id: 51).contentText)
            #expect(present.contains("> "), "recall stopped finding what is actually there:\n\(present.prefix(300))")

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    /// A month with years of photographs behind it used to answer "Nothing recorded".
    ///
    /// `what_happened` consulted sessions and entities, and neither reaches back: sessions
    /// begin the day Memoir was installed. Everything before that arrives through the
    /// importers, dated by the day it happened. On a real vault that meant July 2019 — 27
    /// days and 221 photographs — came back as a blank.
    ///
    /// It reports days and counts and nothing else. A photo row says "6 photos" and a
    /// coordinate; the memory did not see the afternoon, it saw that a camera was used.
    @Test("CF-32 what_happened answers from imported history, not just from sessions")
    func whatHappenedReachesBeforeCapture() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            var madrid = Calendar(identifier: .gregorian)
            madrid.timeZone = TimeZone(identifier: "Europe/Madrid")!

            // Three days in a month years before any session exists.
            var rows: [CaptureEvent] = []
            for (day, shots) in [(3, 6), (14, 12), (27, 4)] {
                let midnight = madrid.date(from: DateComponents(year: 2019, month: 7, day: day))!
                let text = "\(shots) photos"
                rows.append(CaptureEvent(
                    id: "photo-2019-07-\(day)", ts: midnight,
                    appBundleID: PhotoImporter.bundleID, appName: PhotoImporter.appName,
                    windowTitle: nil, text: text, textHash: MemoryText.stableID("hash", text),
                    localDay: LifeImporter.localDayKey(midnight, calendar: madrid)
                ))
            }
            try await seed(store: store, captures: rows)
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            let frame = try await server.callTool(
                "what_happened", arguments: ["from": "2019-07-01", "to": "2019-07-31"], id: 40)
            let text = try #require(frame.contentText)

            #expect(!text.contains("Nothing recorded"),
                    "a month with three days of photographs came back blank:\n\(text)")
            #expect(text.contains("3 days"), "the day count is missing:\n\(text)")
            #expect(text.contains("22 photographs"), "the photograph count is missing:\n\(text)")

            // And it says only what it saw. No claim about what the days were about.
            #expect(!text.contains("41.3"), "a coordinate leaked into the answer:\n\(text)")

            // A month with nothing at all still says so.
            let empty = try await server.callTool(
                "what_happened", arguments: ["from": "2015-01-01", "to": "2015-01-31"], id: 41)
            #expect(try #require(empty.contentText).contains("Nothing recorded"),
                    "an empty month must still be reported as empty")

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    @Test("CF-31 sources_for, verify and prior_art quote the screen too, not the whole tree")
    func evidenceToolsQuoteWhatWasOnScreen() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            let scrolledPast = """
                An advertisement for a live coaching session, mounted in the feed above the \
                thing being read and carrying the word migration purely by coincidence.
                """
            let onScreen = """
                The Fenwick migration is finished and the cutover ran clean on Tuesday night, \
                with no rollback and nothing left on the old cluster.
                """
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: [scrolledPast, onScreen].joined(separator: "\n"),
                    app: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: "Feed | LinkedIn",
                    at: TestClock.minutes(1),
                    name: "evidence-viewport",
                    visibleText: onScreen
                ),
            ])
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            for (id, tool, args) in [
                (20, "sources_for", ["claim": "the fenwick migration is finished"]),
                (21, "verify", ["claim": "the fenwick migration is finished"]),
                (22, "prior_art", ["topic": "fenwick migration"]),
            ] as [(Int, String, [String: String])] {
                let text = try #require(
                    try await server.callTool(
                        tool, arguments: args, id: id
                    ).contentText,
                    "\(tool) returned nothing"
                )
                let quotes = text.split(separator: "\n").filter { $0.contains("> ") }
                #expect(!quotes.isEmpty, "\(tool) rendered no quote at all:\n\(text)")
                #expect(
                    quotes.contains { $0.contains("cutover") || $0.contains("old cluster") },
                    "\(tool) did not quote what was on screen:\n\(quotes.joined(separator: "\n"))"
                )
                #expect(
                    !quotes.contains { $0.contains("coaching session") },
                    "\(tool) quoted the advertisement scrolled past above it:\n\(quotes.joined(separator: "\n"))"
                )
            }

            let status = await server.waitForExit()
            #expect(status == 0 || status == 15, "server exited \(status)")
        }
    }

    @Test("CF-31 a citation quotes the post that was on screen, not the one above it")
    func recallQuotesWhatWasOnScreen() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // The shape of the capture that started this: navigation, then a mounted post
            // that had been scrolled past, then the post actually in front of the user. Only
            // the last was inside the viewport.
            let chrome = """
                Feed | LinkedIn
                0 notifications
                Skip navigation menu
                Home
                Start a post
                """
            let scrolledPast = """
                Looking for a job you will actually enjoy? Find work that aligns with your \
                strengths and long-term goals with guidance from a LinkedIn career expert, in \
                a live coaching session for job seekers running later this week.
                """
            let onScreen = """
                Meta just pulled the biggest reversal in open-weight models this year, and the \
                distillation story underneath it is more interesting than the benchmark table \
                everybody is going to screenshot instead.
                """
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: [chrome, scrolledPast, onScreen].joined(separator: "\n"),
                    app: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: "Feed | LinkedIn",
                    at: TestClock.minutes(1),
                    name: "viewport",
                    visibleText: onScreen
                ),
            ])
            await store.close()

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }
            try await server.handshake()

            // "what was that LinkedIn post": every term is in the navigation, and the only
            // one that appears in prose appears in the post that was scrolled past. Choosing
            // the source by "does a term appear in it" lands on the wrong post; scoring the
            // two windows against each other lands on the one that was on screen.
            let text = try #require(
                try await server.callTool(
                    "recall", arguments: ["query": "linkedin feed post"], id: 10
                ).contentText
            )
            let citation = try #require(
                text.components(separatedBy: "## Where it was seen").last?
                    .split(separator: "\n")
                    .first { $0.contains("> ") },
                "recall did not render a capture citation:\n\(text)"
            )

            #expect(
                citation.contains("open-weight models"),
                "the citation must quote the post that was on screen, got:\n\(citation)"
            )
            #expect(
                !citation.contains("career expert"),
                "the citation quoted a post that had been scrolled past:\n\(citation)"
            )

            // The off-screen half is still reachable when it is what was actually asked for.
            let aboutTheOther = try #require(
                try await server.callTool(
                    "recall", arguments: ["query": "coaching session job seekers"], id: 11
                ).contentText
            )
            #expect(
                aboutTheOther.contains("career expert") || aboutTheOther.contains("coaching session"),
                "a question about the scrolled-past post must still be answerable:\n\(aboutTheOther)"
            )

            let status = await server.waitForExit()
            #expect(status == 0, "clean exit expected, got \(String(describing: status))")
            expectPureJSONStdout(server)
        }
    }

    // MARK: CF-32: stdout carries only protocol

    @Test("CF-32 stdout stays pure JSON under debug logging and malformed input")
    func stdoutPurityUnderNoise() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            // Debug level turns on the schema dump, the per-notification trace and the
            // prepare-failure log, the noisiest the server ever gets.
            let server = try startMCPServer(ws, database: ws.dbURL, logLevel: "debug")
            defer { server.stop() }

            try await server.handshake()
            try await server.request("tools/list", id: 2)
            try await server.callTool("recall", arguments: ["query": "rate limiter"], id: 3)

            // Two malformed lines. Each must produce exactly one error frame and no
            // more, and must not take the server down.
            server.send(rawLine: "{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\"")
            let truncated = try MCPFrame(line: try #require(await server.nextLine()))
            #expect(truncated.hasNullID, "a parse error has a null id: \(truncated.line)")
            #expect(truncated.errorCode == -32700, "expected parseError, got \(String(describing: truncated.errorCode))")

            server.send(rawLine: "this is not JSON at all")
            let garbage = try MCPFrame(line: try #require(await server.nextLine()))
            #expect(garbage.errorCode == -32700)

            // Blank lines are skipped entirely: no frame at all. Proven by the next
            // frame being the answer to id 4.
            server.send(rawLine: "")
            server.send(rawLine: "   ")

            let unknownMethod = try await server.request("resources/list", id: 4)
            #expect(unknownMethod.errorCode == -32601, "unknown methods are methodNotFound: \(unknownMethod.line)")

            let missingName = try await server.request("tools/call", params: ["arguments": [String: Any]()], id: 5)
            #expect(missingName.errorCode == -32602, "a tools/call with no name is invalidParams: \(missingName.line)")

            try await server.callTool("open_commitments", id: 6)

            // A second notification, mid-stream, still answered by nothing.
            try server.notify("notifications/cancelled", params: ["requestId": 6])
            let ping = try await server.request("ping", id: 7)
            #expect(ping.error == nil, "ping must succeed: \(ping.line)")

            let status = await server.waitForExit()
            #expect(status == 0, "clean exit expected, got \(String(describing: status))")

            // stdout: nine frames, every one of them JSON-RPC, nothing else at all.
            expectPureJSONStdout(server)
            let lines = server.stdoutLines
            let transcript = lines.joined(separator: "\n")
            #expect(
                lines.count == 9,
                "expected exactly one frame per request and none for the notifications, got \(lines.count):\n\(transcript)"
            )
            for line in lines {
                #expect(!line.contains("[memoir-mcp]"), "a log line reached stdout: \(line)")
            }

            // stderr: the diagnostics really did happen, and they happened over there.
            let diagnostics = server.stderrText
            #expect(diagnostics.contains("[memoir-mcp]"), "no diagnostics on stderr at all")
            #expect(diagnostics.contains("[DEBUG]"), "debug level produced no debug lines:\n\(diagnostics)")
            #expect(
                diagnostics.contains("notification: notifications/initialized"),
                "the initialized notification was not traced to stderr:\n\(diagnostics)"
            )
            #expect(
                diagnostics.contains("read-only"),
                "the server never logged how it opened the database:\n\(diagnostics)"
            )
        }
    }

    @Test("CF-32 an unreadable database is reported on stderr, never on stdout")
    func stdoutPurityWithBrokenDatabase() async throws {
        try await TestWorkspace.with { ws in
            // A file that exists and is emphatically not a database: the loudest
            // failure path the server has, and the one most likely to print.
            try Data("this is not a SQLite database, it is a sentence".utf8).write(to: ws.dbURL)

            let server = try startMCPServer(ws, database: ws.dbURL, logLevel: "debug")
            defer { server.stop() }

            try await server.handshake()

            let list = try await server.request("tools/list", id: 2)
            #expect(list.error == nil, "the catalogue needs no database: \(list.line)")
            #expect(((list.result?["tools"]) as? [[String: Any]])?.count == 13)

            var id = 10
            for tool in ["recall", "who_is", "what_happened", "open_commitments", "today"] {
                let arguments: [String: Any]
                switch tool {
                case "recall": arguments = ["query": "anything"]
                case "who_is": arguments = ["name": "anyone"]
                case "what_happened": arguments = ["from": "2026-03-01", "to": "2026-03-31"]
                default: arguments = [:]
                }
                let frame = try await server.callTool(tool, arguments: arguments, id: id)
                id += 1
                #expect(frame.error == nil, "\(tool) must degrade to prose, not a protocol error: \(frame.line)")
                let text = try #require(frame.contentText, "\(tool) returned a malformed block: \(frame.line)")
                #expect(text.contains("not available"), "\(tool) should explain itself:\n\(text)")
                #expect(text.contains(ws.dbURL.path), "\(tool) should name the database it could not read:\n\(text)")
            }

            let status = await server.waitForExit()
            #expect(status == 0, "a broken database must not stop the server exiting cleanly")

            expectPureJSONStdout(server)
            #expect(server.stdoutLines.count == 7, "expected 7 frames, got \(server.stdoutLines.count)")

            let diagnostics = server.stderrText
            #expect(diagnostics.contains("[ERROR]"), "an unreadable database must be logged as an error:\n\(diagnostics)")
            #expect(diagnostics.contains("cannot open"), "the error must say what went wrong:\n\(diagnostics)")

            // And it stayed a sentence: nothing tried to repair or recreate the file.
            let bytes = try Data(contentsOf: ws.dbURL)
            #expect(String(decoding: bytes, as: UTF8.self) == "this is not a SQLite database, it is a sentence")
        }
    }

    // MARK: CF-33: The server cannot write

    @Test("CF-33 exercising every tool leaves the database byte-identical")
    func serverCannotWrite() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            // Folds the WAL back into the main file, which is the state an app that
            // has exited cleanly leaves behind.
            await store.close()

            let wal = URL(fileURLWithPath: ws.dbURL.path + "-wal")
            let shm = URL(fileURLWithPath: ws.dbURL.path + "-shm")

            // Read the counts *before* fingerprinting, so this reader's own
            // bookkeeping is part of the baseline rather than mistaken for a write.
            let countsBefore = mcpRowCounts(at: ws.dbURL)
            #expect(countsBefore["captures"] == 5, "seeding did not land: \(countsBefore)")
            #expect(countsBefore["entities"] == 5)
            #expect(countsBefore["provenance"] == 2)
            #expect(countsBefore["sessions"] == 3)

            // The harness's own boxed-in HOME, created up front so it is part of the
            // baseline rather than looking like something the server did.
            try FileManager.default.createDirectory(at: mcpChildHome(ws), withIntermediateDirectories: true)

            let databaseBefore = FileFingerprint.of(ws.dbURL)
            let walBefore = FileFingerprint.of(wal)
            let filesBefore = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: ws.root.path)) ?? []
            )

            let server = try startMCPServer(ws, database: ws.dbURL)
            defer { server.stop() }

            try await server.handshake()
            try await server.request("tools/list", id: 2)

            var id = 10
            for (tool, arguments) in [
                ("recall", ["query": "rate limiter", "limit": 25] as [String: Any]),
                ("recall", ["query": "nothing here matches this phrase"] as [String: Any]),
                ("who_is", ["name": "Priya"] as [String: Any]),
                ("who_is", ["name": "Nobody At All"] as [String: Any]),
                ("what_happened", ["from": "2026-03-01", "to": "2026-03-31"] as [String: Any]),
                ("what_happened", ["from": "today", "to": "now"] as [String: Any]),
                ("open_commitments", [:] as [String: Any]),
                ("today", [:] as [String: Any]),
            ] {
                let frame = try await server.callTool(tool, arguments: arguments, id: id)
                id += 1
                #expect(frame.error == nil, "\(tool) failed: \(frame.line)")
                #expect(frame.contentText != nil, "\(tool) returned a malformed block: \(frame.line)")
            }

            let status = await server.waitForExit()
            #expect(status == 0, "clean exit expected, got \(String(describing: status))")

            let databaseAfter = FileFingerprint.of(ws.dbURL)
            let walAfter = FileFingerprint.of(wal)

            #expect(
                databaseAfter == databaseBefore,
                "the database changed under a read-only server.\nbefore: \(databaseBefore)\nafter:  \(databaseAfter)"
            )
            #expect(
                walAfter == walBefore,
                "the write-ahead log changed under a read-only server.\nbefore: \(walBefore)\nafter:  \(walAfter)"
            )

            // A reader may legitimately materialise the shared-memory index, which is
            // scratch state and not the database. Nothing *else* may appear.
            let filesAfter = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: ws.root.path)) ?? []
            )
            let appeared = filesAfter.subtracting(filesBefore).subtracting([shm.lastPathComponent])
            #expect(appeared.isEmpty, "the server created files: \(appeared.sorted())")
            #expect(filesBefore.subtracting(filesAfter).isEmpty, "the server removed files")

            // Counts last, so this reader cannot have influenced the fingerprints.
            let countsAfter = mcpRowCounts(at: ws.dbURL)
            #expect(countsAfter == countsBefore, "row counts moved: \(countsBefore) → \(countsAfter)")

            expectPureJSONStdout(server)
        }
    }

    @Test("CF-33 the server still answers when the database directory is read-only")
    func serverNeedsNoWritePermission() async throws {
        // Root ignores the permission bits, so the test would prove nothing.
        try #require(getuid() != 0, "this flow is meaningless as root")

        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await MCPSeed.install(into: store)
            await store.close()

            // A dedicated read-only directory holding a copy of the database. The
            // workspace root itself stays writable so the child's HOME still works.
            let vault = ws.root.appendingPathComponent("vault", isDirectory: true)
            try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
            let readOnlyDatabase = vault.appendingPathComponent("memoir.sqlite")
            try FileManager.default.copyItem(at: ws.dbURL, to: readOnlyDatabase)

            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: vault.path)
            defer {
                // Restore before the workspace is torn down, or cleanup cannot delete it.
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vault.path)
            }

            let server = try startMCPServer(ws, database: readOnlyDatabase)
            defer { server.stop() }

            try await server.handshake()
            let frame = try await server.callTool("open_commitments", id: 10)
            #expect(frame.error == nil, "open_commitments failed: \(frame.line)")
            let text = try #require(frame.contentText)
            #expect(
                text.contains(MCPSeed.commitment),
                "a read-only directory must not cost the server its data:\n\(text)"
            )

            let status = await server.waitForExit()
            #expect(status == 0, "clean exit expected, got \(String(describing: status))")
            expectPureJSONStdout(server)
        }
    }

    // MARK: CF-34: Empty and missing databases are survivable

    @Test("CF-34 a nonexistent database path is explained, not crashed on")
    func nonexistentDatabase() async throws {
        try await TestWorkspace.with { ws in
            let missing = ws.root
                .appendingPathComponent("no-such-directory", isDirectory: true)
                .appendingPathComponent("memoir.sqlite")

            let server = try startMCPServer(ws, database: missing, logLevel: "debug")
            defer { server.stop() }

            let initialize = try await server.handshake()
            #expect(initialize.result?["protocolVersion"] as? String == "2025-06-18")

            let list = try await server.request("tools/list", id: 2)
            #expect(((list.result?["tools"]) as? [[String: Any]])?.count == 13, "the catalogue must not depend on the database")

            var id = 10
            for (tool, arguments) in [
                ("recall", ["query": "anything"] as [String: Any]),
                ("who_is", ["name": "anyone"] as [String: Any]),
                ("what_happened", ["from": "2026-03-01", "to": "2026-03-31"] as [String: Any]),
                ("open_commitments", [:] as [String: Any]),
                ("today", [:] as [String: Any]),
            ] {
                let frame = try await server.callTool(tool, arguments: arguments, id: id)
                id += 1
                #expect(frame.error == nil, "\(tool) must answer in prose, not a protocol error: \(frame.line)")
                #expect(frame.isError == false)
                let text = try #require(frame.contentText, "\(tool) block malformed: \(frame.line)")
                #expect(text.contains("not available"), "\(tool) must say what is wrong:\n\(text)")
                #expect(text.contains(missing.path), "\(tool) must name the path it looked at:\n\(text)")
                #expect(text.contains("Launch Memoir"), "\(tool) must say what to do about it:\n\(text)")
            }

            let status = await server.waitForExit()
            #expect(status == 0, "a missing database must still exit cleanly, got \(String(describing: status))")

            // Read-only means read-only even when there is nothing to read.
            #expect(
                !FileManager.default.fileExists(atPath: missing.path),
                "the server created the database it was told to read"
            )
            #expect(
                !FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path),
                "the server created the directory it was told to read from"
            )
            // The decoy and the boxed-in HOME are both untouched, so nothing fell
            // through to the standard location either.
            #expect(!FileManager.default.fileExists(atPath: mcpDecoyDatabasePath(ws)))
            #expect(
                !FileManager.default.fileExists(
                    atPath: mcpChildHome(ws)
                        .appendingPathComponent("Library/Application Support/Memoir/memoir.sqlite").path
                ),
                "the server fell back to the standard location"
            )

            expectPureJSONStdout(server)
            #expect(server.stderrText.contains("no database at"), "the missing file should be logged:\n\(server.stderrText)")
        }
    }

    @Test("CF-34 an empty database file answers instead of hanging or crashing")
    func emptyDatabaseFile() async throws {
        try await TestWorkspace.with { ws in
            // Zero bytes is a legal, completely empty SQLite database.
            #expect(FileManager.default.createFile(atPath: ws.dbURL.path, contents: Data()))

            let server = try startMCPServer(ws, database: ws.dbURL, logLevel: "debug")
            defer { server.stop() }

            try await server.handshake()

            var id = 10
            for (tool, arguments) in [
                ("recall", ["query": "anything"] as [String: Any]),
                ("who_is", ["name": "anyone"] as [String: Any]),
                ("what_happened", ["from": "2026-03-01", "to": "2026-03-31"] as [String: Any]),
                ("open_commitments", [:] as [String: Any]),
                ("today", [:] as [String: Any]),
            ] {
                let frame = try await server.callTool(tool, arguments: arguments, id: id)
                id += 1
                #expect(frame.error == nil, "\(tool) must not fail at the protocol level: \(frame.line)")
                let text = try #require(frame.contentText, "\(tool) block malformed: \(frame.line)")
                #expect(text.contains("not available"), "\(tool) must explain the empty schema:\n\(text)")
                #expect(text.contains(ws.dbURL.path))
            }

            let status = await server.waitForExit()
            #expect(status == 0, "an empty database must still exit cleanly, got \(String(describing: status))")

            #expect(
                (try? Data(contentsOf: ws.dbURL))?.isEmpty == true,
                "the server wrote a schema into a database it opened read-only"
            )
            expectPureJSONStdout(server)
        }
    }

    @Test("CF-34 a database with somebody else's schema is survivable")
    func foreignSchemaDatabase() async throws {
        try await TestWorkspace.with { ws in
            try makeForeignSchemaDatabase(at: ws.dbURL)
            let before = FileFingerprint.of(ws.dbURL)

            let server = try startMCPServer(ws, database: ws.dbURL, logLevel: "debug")
            defer { server.stop() }

            try await server.handshake()

            let list = try await server.request("tools/list", id: 2)
            #expect(((list.result?["tools"]) as? [[String: Any]])?.count == 13)

            let frame = try await server.callTool("today", id: 10)
            #expect(frame.error == nil, "a foreign schema must not be a protocol error: \(frame.line)")
            let text = try #require(frame.contentText)
            #expect(text.contains("not available"), "the server must say the memory is unusable:\n\(text)")

            let recall = try await server.callTool("recall", arguments: ["query": "recipes"], id: 11)
            #expect(recall.error == nil)
            #expect(recall.contentText?.contains("not available") == true, "a foreign table is not Memoir's memory")

            let status = await server.waitForExit()
            #expect(status == 0, "clean exit expected, got \(String(describing: status))")

            #expect(
                FileFingerprint.of(ws.dbURL) == before,
                "the server modified a database it did not understand"
            )
            expectPureJSONStdout(server)
            #expect(
                server.stderrText.contains("recipes") || server.stderrText.contains("mapped tables: none"),
                "the schema mismatch should be visible on stderr:\n\(server.stderrText)"
            )
        }
    }
}
