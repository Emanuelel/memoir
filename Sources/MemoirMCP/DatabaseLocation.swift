import Foundation
import MemoirKit

// MARK: - Database location

/// Where to read the memory from, in order of precedence:
///
/// 1. `--db <path>` (or `--database <path>`) on the command line
/// 2. the `MEMOIR_DB_PATH` environment variable
/// 3. the standard location, `~/Library/Application Support/Memoir/memoir.sqlite`
///
/// Without 1 or 2 the server could only ever be pointed at the user's real database, which
/// makes the MCP contract (CF-30 … CF-34) untestable: those flows run this binary as a
/// subprocess against a throwaway file, including one that deliberately does not exist.
/// The path is never created and never written to: the connection is `SQLITE_OPEN_READONLY`.
func resolveDatabaseURL() -> URL {
    let args = CommandLine.arguments
    if let flag = args.firstIndex(where: { $0 == "--db" || $0 == "--database" }), flag + 1 < args.count {
        return URL(fileURLWithPath: args[flag + 1])
    }
    let environment = ProcessInfo.processInfo.environment["MEMOIR_DB_PATH"] ?? ""
    if !environment.isEmpty {
        return URL(fileURLWithPath: environment)
    }
    return Paths.databaseURL()
}
