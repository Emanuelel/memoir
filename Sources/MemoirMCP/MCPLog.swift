import Foundation

/// stderr-only logger for the MCP server.
///
/// Two rules drive this type:
/// 1. **stdout is sacred.** It carries JSON-RPC frames and nothing else; a single
///    stray byte corrupts the stream and disconnects the client. Nothing here ever
///    touches stdout.
/// 2. **The server has no side effects.** `MemoirKit.Log` also appends to
///    `~/Library/Application Support/Memoir/logs/memoir.log` and creates that directory
///    on demand. A read-only server should not create or write files, and two
///    processes interleaving writes into one log helps nobody, so the MCP binary
///    keeps its diagnostics on stderr where the host client collects them.
public enum MCPLog {
    /// Log levels, filtered by `MEMOIR_MCP_LOG_LEVEL` (debug|info|warn|error|off).
    public enum Level: Int, Sendable, Comparable {
        case debug = 0, info = 1, warn = 2, error = 3, off = 4
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// The active threshold. Defaults to `.info`.
    public static let threshold: Level = {
        switch ProcessInfo.processInfo.environment["MEMOIR_MCP_LOG_LEVEL"]?.lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "warn", "warning": return .warn
        case "error": return .error
        case "off", "none", "silent": return .off
        default: return .info
        }
    }()

    /// Writes a line to stderr, unconditionally. Used by `--selftest` output.
    public static func raw(_ message: String) {
        var data = Data(message.utf8)
        data.append(0x0A)
        FileHandle.standardError.write(data)
    }

    /// Writes a timestamped, level-tagged line to stderr.
    public static func log(_ level: Level, _ message: @autoclosure () -> String) {
        guard level >= threshold, threshold != .off else { return }
        raw("[memoir-mcp] [\(Fmt.iso(Date()))] [\(label(level))] \(message())")
    }

    public static func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public static func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public static func warn(_ message: @autoclosure () -> String) { log(.warn, message()) }
    public static func error(_ message: @autoclosure () -> String) { log(.error, message()) }

    private static func label(_ level: Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        case .off: return "OFF"
        }
    }
}
