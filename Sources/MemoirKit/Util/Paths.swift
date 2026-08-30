import Foundation

public enum Paths {
    public static let appFolderName = "Memoir"

    /// Redirects the whole support folder somewhere else for the duration of a scope.
    ///
    /// This exists so the test suite can never write into the real
    /// `~/Library/Application Support/Memoir`. It is a **task local**, not a plain global:
    /// each test binds its own value and parallel tests cannot see each other's, while
    /// production code, which never binds it, reads `nil` and behaves exactly as before.
    ///
    /// ```swift
    /// try await Paths.$supportDirectoryOverride.withValue(tempDir) {
    ///     // Store, Log and config.json all live under tempDir in here.
    /// }
    /// ```
    ///
    /// Task locals propagate into actor calls and into `Task { }` children created inside
    /// the scope, so a `Store` or a `CaptureLoop` started within the binding stays redirected.
    @TaskLocal public static var supportDirectoryOverride: URL?

    public static func supportDirectory() -> URL {
        let dir: URL
        if let override = supportDirectoryOverride {
            dir = override
        } else if let env = ProcessInfo.processInfo.environment["MEMOIR_SUPPORT_DIR"], !env.isEmpty {
            // The task local only reaches code that can bind it, which means tests. Anything
            // launched from a shell had no way to redirect itself at all.
            //
            // That gap has already cost us once: an agent trying to isolate an end-to-end
            // check set HOME to a temp directory, which cannot work here because
            // `FileManager.urls(for: .applicationSupportDirectory)` reads the real home from
            // the password database and ignores the environment entirely. The override
            // silently did nothing and the run migrated the user's live memory.
            //
            // An isolation mechanism that fails silently is worse than none, because it is
            // trusted.
            dir = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            dir = base.appendingPathComponent(appFolderName, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func databaseURL() -> URL {
        // Inside the encrypted vault when it is mounted, at the old plaintext path when it is
        // not. Every binary has to agree on this: the app resolves it through
        // `EncryptedVault.open()`, and `memoir-mcp`, `memoir-ask` and `--doctor` all arrive
        // here instead. They disagreed for one commit, and the symptom was every agent tool
        // reporting an empty memory while the app itself was working perfectly.
        //
        // The fallback is not a guess. The vault is only mounted while Memoir is running, so
        // a missing file here means either a machine that predates encryption or an app that
        // is not open, and in both cases the plaintext path is the correct answer, the second
        // one correctly finding nothing.
        let inVault = supportDirectory()
            .appendingPathComponent("vault", isDirectory: true)
            .appendingPathComponent("memoir.sqlite")
        if FileManager.default.fileExists(atPath: inVault.path) { return inVault }
        return supportDirectory().appendingPathComponent("memoir.sqlite")
    }

    public static func configURL() -> URL {
        supportDirectory().appendingPathComponent("config.json")
    }

    public static func logsDirectory() -> URL {
        let dir = supportDirectory().appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Minimal file+stderr logger. No third-party dependency, no network, ever.
public struct Log: Sendable {
    public enum Level: String, Sendable { case debug, info, warn, error }

    public static let shared = Log()
    private init() {}

    public func log(_ level: Level, _ message: @autoclosure () -> String, file: String = #fileID) {
        let line = "[\(Self.stamp())] [\(level.rawValue.uppercased())] [\(file)] \(message())"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        Self.appendToFile(line)
    }

    public func debug(_ m: @autoclosure () -> String, file: String = #fileID) { log(.debug, m(), file: file) }
    public func info(_ m: @autoclosure () -> String, file: String = #fileID) { log(.info, m(), file: file) }
    public func warn(_ m: @autoclosure () -> String, file: String = #fileID) { log(.warn, m(), file: file) }
    public func error(_ m: @autoclosure () -> String, file: String = #fileID) { log(.error, m(), file: file) }

    /// Where the log file lives.
    public static func fileURL() -> URL {
        Paths.logsDirectory().appendingPathComponent("memoir.log")
    }

    /// Empties the log.
    ///
    /// Part of "Delete everything", because the log is Memoir data too. It records which apps
    /// were frontmost and when, every window Memoir looked at, and, when the `ax-dump` marker
    /// is present, the geometry of what was on screen. A wipe that leaves a timestamped
    /// record of the user's day behind is not the wipe the button describes.
    public func purge() {
        try? Data().write(to: Self.fileURL())
    }

    /// The point at which the log stops being a diagnostic and starts being a second record
    /// of the user's day. Matches `AskLog`'s ceiling.
    public static let maxBytes = 4 * 1_024 * 1_024

    /// Halves the log when it exceeds ``maxBytes``, keeping the recent end.
    ///
    /// There was no rotation and no cap at all: on a real installation this file had reached
    /// 5.8 MB across 68,000 lines in ten days, and it is `0644` on a directory nothing sets
    /// permissions on. Dropping the oldest half rather than truncating outright keeps the
    /// window that `--doctor` actually reads.
    public func trimIfOversized() {
        let url = Self.fileURL()
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
              size > Int64(Self.maxBytes) else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let keep = data.suffix(Self.maxBytes / 2)
        // Resume at a line boundary so the first surviving entry is not a fragment.
        let newline = UInt8(ascii: "\n")
        let trimmed = keep.firstIndex(of: newline).map { keep[keep.index(after: $0)...] } ?? keep
        try? Data(trimmed).write(to: url)
        Log.shared.info("trimmed memoir.log from \(size) bytes")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func appendToFile(_ line: String) {
        let url = Paths.logsDirectory().appendingPathComponent("memoir.log")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
