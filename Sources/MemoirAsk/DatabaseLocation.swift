import Foundation
import MemoirKit

// MARK: - Database location

/// Where to read the memory from, in order of precedence:
///
/// 1. `--db <path>` (or `--database <path>`) on the command line
/// 2. the `MEMOIR_DB_PATH` environment variable
/// 3. the standard location, `~/Library/Application Support/Memoir/memoir.sqlite`
///
/// Deliberately identical to `MemoirMCP`'s `resolveDatabaseURL()`, down to the flag spellings
/// and the precedence, because two binaries in one repo disagreeing about where a database
/// lives is a bug waiting for someone to hit it at the worst moment.
///
/// Both forms, not one: the flag for a person running a single question by hand, the
/// environment variable because `Scripts/eval.sh` drives this binary as a subprocess and would
/// otherwise have to thread a flag through every invocation. `main.swift` already makes that
/// argument for `MEMOIR_LOCAL_URL`.
///
/// Without either, the answer suite could only ever be pointed at the author's real database,
/// which is exactly why `EVALS.md` promised a fixture gate that did not exist.
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

/// True when the caller named a database explicitly rather than taking the default.
func databaseWasNamedExplicitly() -> Bool {
    let args = CommandLine.arguments
    if args.contains("--db") || args.contains("--database") { return true }
    return !(ProcessInfo.processInfo.environment["MEMOIR_DB_PATH"] ?? "").isEmpty
}

/// Refuses to answer questions against a database that is not there.
///
/// `Store.init(path:)` opens with `SQLITE_OPEN_CREATE` and makes the parent directory, so a
/// mistyped `--db` does not fail: it succeeds, produces an empty memory, and every answer
/// becomes a confident "nothing recorded". That is the worst failure this binary has: a false
/// negative that reads exactly like a true one, and in an eval run it would be thirty of them
/// in a row scored as honest refusals.
///
/// Only for explicitly named paths. The default location genuinely may not exist yet on a
/// first run, and creating it there is correct.
func requireExistingDatabase(at url: URL) {
    guard databaseWasNamedExplicitly() else { return }
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    stderrLine("""
    no database at \(url.path)

    Refusing to create one. An empty memory answers every question with "nothing
    recorded", which is indistinguishable from a real answer and scores as one.
    """)
    exit(1)
}
