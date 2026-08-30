import Foundation
import MemoirFixtures
import MemoirKit

// memoir-eval-seed: build the synthetic database `Scripts/eval.sh` grades against.
//
//   memoir-eval-seed <directory>
//
// Writes `<directory>/memoir.sqlite` and `<directory>/facts.json`, and leaves the directory
// laid out as a complete Memoir support folder so `memoir-ask` can be pointed at it with
// MEMOIR_SUPPORT_DIR and never touch the real one.
//
// ## Regenerated, never committed
//
// `.gitignore` excludes `*.sqlite`, so the database cannot be checked in, and that is the
// right answer anyway. A committed database rots against schema migrations: it would open,
// migrate silently, and start answering questions from a shape nobody wrote. Seeding takes a
// second or two and always produces the current schema.
//
// ## The trap this binary exists to avoid
//
// `MemoryService.consolidate` calls `recentAnswerFingerprints()`, which reads `asks.jsonl`
// from the support directory and drops any capture whose first 50 collapsed characters match
// a logged question or answer. That guard is correct (Memoir must never learn from its own
// output), and against the REAL support directory it silently deletes fixture captures,
// differently on every machine, with no error anywhere.
//
// So everything below runs inside `Paths.$supportDirectoryOverride`. Not for tidiness: it is
// the difference between a deterministic world and one that quietly depends on what the person
// running it asked Memoir last week.

let arguments = CommandLine.arguments.dropFirst()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let target = arguments.first(where: { !$0.hasPrefix("--") }) else {
    fail("""
    usage: memoir-eval-seed <directory>

    Builds the fixture memory the answer evals are graded against:
      <directory>/memoir.sqlite   the database
      <directory>/facts.json      what was seeded, measured rather than asserted

    Wipes and rebuilds the directory every run.
    """)
}

let root = URL(fileURLWithPath: (target as NSString).expandingTildeInPath, isDirectory: true)

// Refusing to wipe anything that is not ours.
//
// This deletes the directory before rebuilding, and a mistyped path would otherwise take
// whatever is there with it. A folder that exists and holds no `memoir.sqlite` is somebody
// else's folder until proven otherwise.
if FileManager.default.fileExists(atPath: root.path) {
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    let ours = contents.isEmpty || contents.contains("memoir.sqlite") || contents.contains("facts.json")
    guard ours else {
        fail("""
        refusing to rebuild \(root.path)

        It exists, it is not empty, and it holds no memoir.sqlite, so it does not look like a
        seeded eval directory. Name an empty directory or one this tool made.
        """)
    }
    try FileManager.default.removeItem(at: root)
}
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

let facts = try await Paths.$supportDirectoryOverride.withValue(root) {
    let databaseURL = Paths.databaseURL()
    let store = try Store(path: databaseURL)
    let facts = try await EvalWorld.seed(into: store)

    // Passage vectors, up front. Search derives them on demand when they are missing, which is
    // correct and slow: measured at 3838ms a search against 15ms once stored. Seventy-eight
    // questions times three runs is not the place to pay that.
    let index = SemanticIndex(store: store)
    while try await index.backfill(limit: 500) > 0 {}
    while try await index.backfillPassages(limit: 200) > 0 {}

    await store.close()
    return facts
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601
try encoder.encode(facts).write(to: root.appendingPathComponent("facts.json"), options: .atomic)

let iso = ISO8601DateFormatter()
print("seeded \(root.path)")
print("  \(facts.captureCount) captures, \(facts.entityCount) entities")
print("  reference date \(iso.string(from: facts.reference))")
print("  \(facts.totalMinutes) min tracked, most in \(facts.topApp) (\(facts.topAppMinutes) min)")
print("  \(facts.openCommitments.count) open commitment(s), \(facts.overdueCommitments.count) past due")
