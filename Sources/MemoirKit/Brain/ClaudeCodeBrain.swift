import Foundation

/// Uses the `claude` CLI the user already has installed, in headless mode (`claude -p <prompt>`).
///
/// Memoir makes no network request of its own here: it runs a local binary and reads its stdout.
/// That binary does talk to Anthropic on the user's existing account, which is why
/// `BrainKind.claudeCode.isCloud` is `true` and why `BrainRouter` refuses to use it unless
/// `BrainConfig.allowCloud` is on.
///
/// The subprocess is hard-bounded: 60 second wall clock, terminated then killed on timeout,
/// and always reaped so no zombie is left behind.
public struct ClaudeCodeBrain: Brain {
    /// Wall clock ceiling for a single invocation.
    public static let timeout: TimeInterval = 60

    /// Directories searched when no explicit path is configured, in order.
    public static let searchPaths: [String] = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        NSHomeDirectory() + "/.claude/local/claude",
        NSHomeDirectory() + "/.local/bin/claude",
    ]

    /// Largest prompt handed to the CLI as an argument. Well under `ARG_MAX`.
    private static let maxPromptCharacters = 180_000

    /// Explicit binary path from settings, if the user set one.
    private let configuredPath: String?

    /// Creates the brain.
    /// - Parameter binaryPath: explicit path to the `claude` executable, or nil to auto-detect.
    public init(binaryPath: String? = nil) {
        let trimmed = binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configuredPath = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Always `.claudeCode`.
    public var kind: BrainKind { .claudeCode }

    // MARK: - Locating the binary

    /// Resolves the `claude` executable without launching anything.
    ///
    /// Checks the configured path, then the well-known install locations, then the cached result
    /// of a previous `command -v claude` probe. Returns nil when only a shell probe could find it.
    public func knownBinaryPath() -> String? {
        if let configuredPath {
            if Self.isExecutable(configuredPath) { return configuredPath }
            Log.shared.warn("Configured claude path is not executable: \(configuredPath)")
        }
        for candidate in Self.searchPaths where Self.isExecutable(candidate) { return candidate }
        if let cached = Self.shellProbe.cachedValue, Self.isExecutable(cached) { return cached }
        return nil
    }

    /// Resolves the `claude` executable, shelling out to the user's login shell at most once per
    /// process when the well-known locations come up empty (so `nvm`, `asdf`, `mise` and custom
    /// Homebrew prefixes are picked up). The probe result is cached.
    public func resolvedBinaryPath() async -> String? {
        if let known = knownBinaryPath() { return known }
        if let found = await Self.shellProbe.value(), Self.isExecutable(found) { return found }
        return nil
    }

    /// Forgets the cached `command -v claude` result, for use after the user installs the CLI.
    public static func resetDiscoveryCache() { shellProbe.reset() }

    /// True when the path exists, is a file, and has the execute bit for this user.
    private static func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        return fm.isExecutableFile(atPath: path)
    }

    /// Caches the one-per-process login-shell lookup.
    private static let shellProbe = ShellProbe()

    /// Runs `command -v claude` through the login shell, once, and remembers the answer.
    final class ShellProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var probed = false
        private var result: String?

        /// The remembered result, without triggering a probe.
        var cachedValue: String? {
            lock.lock(); defer { lock.unlock() }
            return result
        }

        /// Forgets the cached answer.
        func reset() {
            lock.lock(); probed = false; result = nil; lock.unlock()
        }

        /// The probed path, running the shell lookup on first call.
        func value() async -> String? {
            if let cached = snapshot() { return cached }

            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            var found: String?
            if ClaudeCodeBrain.isExecutable(shell),
               let out = try? await ProcessRunner.run(
                   executable: shell,
                   arguments: ["-lc", "command -v claude"],
                   timeout: 8
               ),
               out.exitCode == 0 {
                found = out.stdout
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
            }
            store(found)
            return found
        }

        /// The remembered answer if the probe already ran. Outer nil means "not probed yet".
        /// Kept non-async so the lock is never taken from an asynchronous context.
        private func snapshot() -> String?? {
            lock.lock(); defer { lock.unlock() }
            return probed ? .some(result) : nil
        }

        /// Records the probe outcome.
        private func store(_ value: String?) {
            lock.lock(); probed = true; result = value; lock.unlock()
        }
    }

    // MARK: - Brain

    /// True when a `claude` binary can be found. Never runs the model.
    public func isAvailable() async -> Bool {
        await resolvedBinaryPath() != nil
    }

    /// Explains the current state for the settings UI.
    public func availabilityDetail() async -> String {
        if let path = await resolvedBinaryPath() {
            return "Using the Claude Code CLI at \(path). Questions go through your existing Claude account."
        }
        return "The claude command was not found. Install Claude Code, or set its path in Settings."
    }

    /// Answers a question against the context packet by shelling out to `claude -p`.
    /// - Throws: `MemoirError.brainUnavailable(.claudeCode, _)` when the binary is missing, times out,
    ///   exits non-zero, or prints nothing.
    public func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
        let started = Date()
        let text = try await run(prompt: BrainPrompt.combined(question: question, context: context))
        return BrainAnswer(
            text: BrainPrompt.clean(text),
            brain: .claudeCode,
            citedCaptureIDs: context.captureIDs,
            latency: Date().timeIntervalSince(started)
        )
    }

    /// Raw completion used by the extraction pipeline.
    ///
    /// The CLI has no token cap flag, so `maxTokens` is applied as a length instruction and as a
    /// hard character trim on the result.
    /// - Throws: `MemoirError.brainUnavailable(.claudeCode, _)`.
    public func complete(prompt: String, maxTokens: Int) async throws -> String {
        let budgeted = prompt + "\n\nKeep the response under roughly \(max(32, maxTokens)) tokens."
        let text = try await run(prompt: budgeted)
        let limit = max(128, maxTokens * 4)
        let cleaned = BrainPrompt.clean(text, fallback: "")
        return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
    }

    // MARK: - Subprocess

    /// Runs `claude -p <prompt>` and returns stdout.
    private func run(prompt: String) async throws -> String {
        guard let binary = await resolvedBinaryPath() else {
            throw MemoirError.brainUnavailable(.claudeCode, "The claude command was not found on this Mac.")
        }

        var payload = prompt
        if payload.count > Self.maxPromptCharacters {
            payload = String(payload.prefix(Self.maxPromptCharacters))
            Log.shared.warn("Claude Code prompt truncated to \(Self.maxPromptCharacters) characters.")
        }

        let result: ProcessRunner.Result
        // A subprocess rather than a socket, but the packet still reaches Anthropic, under
        // the user's own account, which changes who sees it and not whether it left. The
        // availability probe above is not counted: resolving a path sends nothing.
        OutboundMonitor.shared.record(destination: "Claude Code")
        do {
            result = try await ProcessRunner.run(
                executable: binary,
                arguments: ["-p", payload],
                timeout: Self.timeout
            )
        } catch let error as ProcessRunner.Failure {
            throw MemoirError.brainUnavailable(.claudeCode, error.userFacingDescription)
        } catch {
            throw MemoirError.brainUnavailable(.claudeCode, "Could not run the claude command.")
        }

        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty
                ? "The claude command exited with status \(result.exitCode)."
                : "claude: \(String(stderr.prefix(300)))"
            Log.shared.warn("Claude Code failed: \(detail)")
            throw MemoirError.brainUnavailable(.claudeCode, detail)
        }

        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw MemoirError.brainUnavailable(.claudeCode, "The claude command returned nothing.")
        }
        return text
    }
}

// MARK: - Process helper

/// Minimal, deadlock-free subprocess runner.
///
/// stdout and stderr are drained concurrently (draining them in sequence deadlocks as soon as one
/// pipe buffer fills), the child is always waited on, and a watchdog escalates `SIGTERM` to
/// `SIGKILL` when the deadline passes.
enum ProcessRunner {
    /// What a finished process produced.
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Why a process did not finish normally.
    enum Failure: Error {
        case launchFailed(String)
        case timedOut(TimeInterval)

        /// A sentence worth showing a person.
        var userFacingDescription: String {
            switch self {
            case .launchFailed(let m): return "Could not start the claude command: \(m)"
            case .timedOut(let s): return "The claude command did not finish within \(Int(s)) seconds."
            }
        }
    }

    /// Wraps a non-`Sendable` value so it can be captured by a dispatch block we control entirely.
    private struct Unchecked<T>: @unchecked Sendable {
        let value: T
    }

    /// Shared state between the watchdog and the reader, guarded by a lock.
    private final class Guard: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false
        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
        var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    }

    /// Resumes a continuation exactly once, from whichever queue gets there first.
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?

        init(_ c: CheckedContinuation<T, any Error>) { continuation = c }

        /// Hands out the continuation at most once.
        private func take() -> CheckedContinuation<T, any Error>? {
            lock.lock(); defer { lock.unlock() }
            let c = continuation
            continuation = nil
            return c
        }

        func succeed(_ value: sending T) { take()?.resume(returning: value) }
        func fail(_ error: sending any Error) { take()?.resume(throwing: error) }
    }

    /// Runs a process off the cooperative thread pool and awaits its result.
    /// - Throws: ``Failure`` on launch problems or timeout. A non-zero exit is *not* an error here;
    ///   it is reported in `Result.exitCode`.
    static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> Result {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, any Error>) in
            let once = Once(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    once.succeed(try runSync(executable: executable, arguments: arguments, timeout: timeout))
                } catch {
                    once.fail(error)
                }
            }
        }
    }

    /// Blocking implementation. Only ever called on a dispatch queue, never on the Swift
    /// concurrency pool, because it parks the thread while the child runs.
    static func runSync(executable: String, arguments: [String], timeout: TimeInterval) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Keep the environment but make the child non-interactive.
        var env = ProcessInfo.processInfo.environment
        env["CI"] = "1"
        env["TERM"] = "dumb"
        process.environment = env

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        let sentinel = Guard()
        let boxedProcess = Unchecked(value: process)
        let watchdog = DispatchWorkItem {
            let p = boxedProcess.value
            guard p.isRunning else { return }
            sentinel.markTimedOut()
            p.terminate()
            // Give it a moment to exit politely, then insist.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                let inner = boxedProcess.value
                if inner.isRunning { kill(inner.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain both pipes at the same time; draining them one after the other deadlocks.
        let errHandle = Unchecked(value: errPipe.fileHandleForReading)
        let outHandle = Unchecked(value: outPipe.fileHandleForReading)
        let errBuffer = DataBox()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            errBuffer.set(errHandle.value.readDataToEndOfFile())
        }
        let outData = outHandle.value.readDataToEndOfFile()
        group.wait()

        process.waitUntilExit()
        watchdog.cancel()

        if sentinel.didTimeOut {
            throw Failure.timedOut(timeout)
        }

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errBuffer.get(), encoding: .utf8) ?? ""
        )
    }

    /// Lock-guarded `Data` box, so the stderr reader can hand its buffer back across queues.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
