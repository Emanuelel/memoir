import Foundation
import MemoirKit

// memoir-ask: run questions through Memoir's real answering pipeline from the terminal.
//
// This exists so answer quality can be measured instead of guessed at. It uses the same
// Store, the same MemoryService context builder and the same BrainRouter as the app, so
// what you see here is exactly what the ask bar would show.
//
//   memoir-ask "what did I work on today"          one question, with the context it used
//   memoir-ask --batch questions.txt               one per line, summarised
//   memoir-ask --brain rulesOnly "..."             force a specific brain
//   memoir-ask --quiet "..."                       answer only, no diagnostics
//   memoir-ask --context "..."                     show the full context packet
//   memoir-ask --recent 10                         replay the last N logged asks
//   memoir-ask --now 2026-03-16T12:00:00Z "..."    answer as if it were that instant

let args = CommandLine.arguments.dropFirst()

func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), args.index(after: i) < args.endIndex else { return nil }
    return args[args.index(after: i)]
}
let quiet = args.contains("--quiet")
let showContext = args.contains("--context")
let budget = Int(flagValue("--budget") ?? "") ?? 2_000

func stderrLine(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// Resolved once, before any mode runs, so every path below reads the same database.
// See DatabaseLocation.swift for the precedence and for why a named path that does not
// exist is refused rather than created.
let databaseURL = resolveDatabaseURL()
requireExistingDatabase(at: databaseURL)

// MARK: - Reference date
//
// What "now" means for the answer. Nil is the wall clock, which is what a person at a
// terminal wants and what every mode below except the graded question path uses.
//
// A fixture database is a fixed day, so a run against it has to be told which day that is
// or it drifts: the retrieved captures stay at 16 March while "today", "overdue" and "due
// Friday" are all rendered from whenever the run happens. The output still looks
// deterministic. It just quietly means something different tomorrow.
//
// Deliberately NOT applied to `--live` or `--doctor`. Both are probes of the real machine
// at the real moment, and `--live`'s latency ceiling is a measurement of elapsed time: a
// clock that can be moved is exactly the wrong thing to measure a duration against.
let referenceDate: Date? = resolveReferenceDate()

// MARK: - Recent

if let n = flagValue("--recent") {
    let limit = Int(n) ?? 10
    let entries = AskLog.shared.recent(limit: limit)
    guard !entries.isEmpty else {
        print("No asks logged yet at \(AskLog.url().path)")
        exit(0)
    }
    for e in entries.reversed() {
        let stamp = e.ts.formatted(.dateTime.hour().minute().second())
        print("──────────────────────────────────────────────────────────────")
        print("[\(stamp)] \(e.brain) · \(String(format: "%.1f", e.latency))s · ctx \(e.contextTokens) tok")
        print("Q: \(e.question)")
        print("A: \(e.answer)")
        if showContext {
            print("--- context shown to the brain ---")
            print(e.contextSummary)
        }
    }
    exit(0)
}

// MARK: - Reindex

if args.contains("--sweep") {
    // Retire entities that today's guards would refuse. Dry run unless --apply is given:
    // a sweep that deletes the wrong thing is exactly the failure it exists to fix.
    let store = try Store(path: databaseURL)
    let memory = MemoryService(store: store, extractors: [RuleExtractor()])
    let apply = args.contains("--apply")
    let retired = try await memory.sweepJunk(dryRun: !apply)
    // The extractor's guard protects what has not been written yet; these two clean up
    // behind it. Demotion runs first so a row is judged as junk before it is judged as
    // merely unowned.
    let demoted = try await memory.demoteUnownedCommitments(dryRun: !apply)
    // A person the timeline promoted is nobody the user deals with (CF-97).
    let feedPeople = try await memory.retireFeedOnlyPeople(dryRun: !apply)
    if !feedPeople.isEmpty {
        print("\(feedPeople.count) person(s) \(apply ? "retired" : "would be retired") (only ever seen on a feed):")
        for e in feedPeople.prefix(20) { print("  ~ \(String(e.title.prefix(100)))") }
    }
    if !demoted.isEmpty {
        print("\(demoted.count) commitment(s) \(apply ? "demoted" : "would be demoted") (read off a page, never written by you):")
        for e in demoted.prefix(20) { print("  ~ \(String(e.title.prefix(100)))") }
    }
    if retired.isEmpty {
        print("nothing to sweep")
    } else {
        print("\(retired.count) junk entities \(apply ? "retired" : "found (dry run; pass --apply)"):")
        for e in retired { print("- [\(e.kind.rawValue)] \(String(e.title.prefix(110)))") }
    }
    exit(0)
}

// The live probe: real questions, real database, structural grading.
//
// `EVALS.md` has described this mode since the beginning and nothing implemented it, so
// every eval that ever ran did so against a synthetic world that agrees with the code by
// construction. Content here is unknowable (tomorrow's answer differs from today's), so
// nothing below asserts what an answer should SAY. It asserts properties that must hold
// whatever is in the record, and those are exactly the properties that broke in practice:
// a citation that resolves to nothing, a URL never seen, an answer about now from a record
// that stopped yesterday, a false claim vouched for.
//
// Never a gate. The environment is a person's actual Mac and it changes hourly; failing a
// build on it would train everyone to ignore the result. It is the probe, and it is the
// thing to run before believing any answer-quality work.
if args.contains("--live") {
    let store = try Store(path: databaseURL)
    let memory = MemoryService(store: store, extractors: [RuleExtractor()])
    let preferred = BrainKind(rawValue: flagValue("--brain") ?? "") ?? .rulesOnly
    // Same rule as --reindex: your own box yes, a third party no. See BrainConfiguration.swift.
    var liveConfig = brainConfiguration(preferred: preferred)
    liveConfig.allowCloud = false
    let router = BrainRouter(preferred: preferred, store: store, config: liveConfig)
    let questionRouter = QuestionRouter()
    let latencyCeiling = Double(flagValue("--ceiling") ?? "") ?? 30

    let listPath = flagValue("--questions") ?? "Evals/live-questions.txt"
    guard let raw = try? String(contentsOfFile: listPath, encoding: .utf8) else {
        stderrLine("cannot read \(listPath)"); exit(1)
    }
    let lines = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }

    // What the record actually contains, for the checks that need to know.
    let stats = try await store.stats()
    let newestEvidence = [stats.newestCapture, stats.newestSession].compactMap { $0 }.max()
    let corpus = try await store.captures(since: .distantPast, limit: 20_000)
    let corpusText = corpus.map { ($0.text + " " + ($0.windowTitle ?? "")).lowercased() }
    let knownIDs = Set(corpus.map(\.id))

    var failures: [String] = []
    var checked = 0

    func fail(_ question: String, _ what: String, _ detail: String) {
        failures.append("  \(what)\n    Q: \(question)\n    \(detail)")
    }

    print("Live probe: \(databaseURL.path)")
    print("\(stats.captureCount) captures, record reaches "
          + (newestEvidence.map { RulesOnlyBrain.formatDuration(Date().timeIntervalSince($0)) + " ago" } ?? "nowhere")
          + "\n")

    for line in lines {
        var question = line
        var mustRefuse = false
        var mustBeAbsent = false
        if question.hasPrefix("!refuse ") {
            mustRefuse = true; question = String(question.dropFirst("!refuse ".count))
        } else if question.hasPrefix("!verify-absent ") {
            mustBeAbsent = true; question = String(question.dropFirst("!verify-absent ".count))
        }

        // The claim checks go through the same tool an agent would call.
        if mustBeAbsent {
            checked += 1
            let terms = question.lowercased().split(separator: " ").map(String.init)
                .filter { $0.count >= 4 }
            let supported = corpusText.contains { hay in terms.allSatisfy { hay.contains($0) } }
            if supported {
                print("  skip   \(question): the record genuinely contains this")
            } else {
                print("  ok     absent from the record: \(question)")
            }
            continue
        }

        let started = Date()
        let routing = await questionRouter.route(question)
        let packet = try await memory.context(for: question, budget: 2_000, category: routing.category)
        let answer = try await router.answer(question: question, context: packet, category: routing.category)
        let elapsed = Date().timeIntervalSince(started)
        checked += 1

        let text = answer.text
        let lower = text.lowercased()
        var problems: [String] = []

        // 1. Something was said.
        let withoutFooter = text.replacingOccurrences(of: RulesOnlyBrain.footer, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if withoutFooter.count < 10 { problems.append("answered with nothing but the footer") }

        // 2. Refusals actually refuse.
        if mustRefuse {
            let refused = ["cannot", "can't", "no record", "not in the record", "do not", "don't",
                           "nothing", "never", "unable"].contains { lower.contains($0) }
            if !refused { problems.append("must refuse a question the record cannot answer, and did not") }
        }

        // 3. Every citation resolves to a capture that exists.
        for id in answer.citedCaptureIDs where !knownIDs.contains(id) {
            problems.append("cited a capture that is not in the database: \(id)")
        }

        // 4. No URL that was never on screen.
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let candidate = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>,.\"'`*"))
            guard candidate.contains("http") || candidate.contains(".com") || candidate.contains(".ai") else { continue }
            guard candidate.count > 8 else { continue }
            let bare = candidate.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            if !corpusText.contains(where: { $0.contains(bare) }) {
                problems.append("named a URL that appears nowhere in the record: \(bare)")
            }
        }

        // 5. A status report must not stand in for an answer.
        //
        // This replaced a self-echo check that compared the answer against Memoir's own
        // earlier replies. It could not work: the same question over the same record
        // produces the same words, and that is determinism rather than a defect. Worse, it
        // flagged the right answers and buried the wrong one. CF-81 guards actual self-echo
        // (Memoir citing its own output as evidence) where it belongs, in the server.
        //
        // What matters here is the failure the general brief was built to avoid: asked for
        // a specific thing, replying "3 open commitments, 1 past due. Recently in play: …",
        // which is true, useless, and an answer to no question.
        let briefMarkers = ["recently in play:", "closest things i have to that:",
                            "open commitments, ", "ask about your commitments"]
        let asksForSomethingSpecific = !RulesOnlyBrain.questionIsAboutNow(question)
            && !mustRefuse
        if asksForSomethingSpecific, briefMarkers.contains(where: { lower.contains($0) }) {
            problems.append("answered a specific question with the general status brief")
        }

        // 6. A claim about now, from a record that stopped, must say so.
        if let newest = newestEvidence,
           Date().timeIntervalSince(newest) > RulesOnlyBrain.stalenessThreshold,
           RulesOnlyBrain.questionIsAboutNow(question),
           !lower.contains("nothing has been captured since") {
            problems.append("answered about the present from a stale record without saying so")
        }

        // 7. Latency a person would accept.
        if elapsed > latencyCeiling {
            problems.append(String(format: "took %.1fs, over the %.0fs ceiling", elapsed, latencyCeiling))
        }

        if problems.isEmpty {
            print(String(format: "  ok     [%5.1fs] %@", elapsed, question))
        } else {
            print(String(format: "  FAIL   [%5.1fs] %@", elapsed, question))
            for p in problems { fail(question, p, String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ")) }
        }
    }

    print("\n\(checked) checked, \(failures.count) structural violation(s)")
    if !failures.isEmpty {
        print("\nViolations:")
        for f in failures { print(f) }
    }
    print("\nStructural only: nothing here asserts what an answer should say, because the")
    print("content of a real memory is not knowable in advance. Informational, never a gate.")
    exit(failures.isEmpty ? 0 : 1)
}

// Getting everything out, without the app.
//
// The GUI has the same two exports in Settings → Data. This exists because the app is not
// always the answer: a user whose Memoir will not launch, or who wants this on a schedule,
// or who is migrating machines, should not have to open a window to retrieve their own
// memory. Format follows the extension: `.md` for the reading copy, anything else for the
// archive.
if args.contains("--export") {
    guard let path = flagValue("--export") else {
        stderrLine("usage: memoir-ask --export <path.json|path.md>")
        exit(1)
    }
    let destination = URL(fileURLWithPath: path)
    let store = try Store(path: databaseURL)
    do {
        let bytes = try await MemoryExport.write(from: store, to: destination)
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        print("exported \(size) to \(destination.path)")
        exit(0)
    } catch {
        stderrLine("export failed: \(error)")
        exit(1)
    }
}

// Is the product actually working on THIS machine, right now?
//
// The test suite seeds its own world and asserts on it, so it proves the code does what
// the code says and can never notice that capture died eighteen hours ago, that the app
// is not running, or that an app the user lives in reads as nothing. Every one of those
// was found by a person asking a question and getting a confident, stale answer. This is
// the instrument for that class of failure; `swift test` is the wrong one.
if args.contains("--doctor") {
    // Read-only, because a diagnostic that writes is not a diagnostic. `Store(path:)` opens
    // with SQLITE_OPEN_CREATE, sets WAL and can rebuild the FTS tables, so asking Memoir
    // whether it is healthy could create the very database it was reporting on.
    let store: Store
    do {
        store = try Store(readOnlyPath: databaseURL)
    } catch {
        stderrLine("Memoir doctor: cannot read \(databaseURL.path)\n\n\(error)")
        stderrLine("If Memoir has never run on this Mac, there is nothing to check yet.")
        exit(1)
    }
    let stats = try await store.stats()
    let now = Date()
    var problems = 0

    func check(_ ok: Bool, _ good: String, _ bad: String) {
        print(ok ? "  ok    \(good)" : "  PROBLEM  \(bad)")
        if !ok { problems += 1 }
    }

    print("Memoir doctor: \(databaseURL.path)\n")

    // 1. Is the record reaching the present?
    if let newest = stats.newestCapture {
        let gap = now.timeIntervalSince(newest)
        check(gap <= RulesOnlyBrain.stalenessThreshold,
              "capture is current (last seen \(RulesOnlyBrain.formatDuration(gap)) ago)",
              """
              nothing captured for \(RulesOnlyBrain.formatDuration(gap)) - every answer about \
              recent activity is blind. Check Memoir is running, capture is not paused, and \
              Accessibility is granted (System Settings > Privacy & Security > Accessibility).
              """)
    } else {
        check(false, "", "no captures at all. Memoir has never successfully read the screen.")
    }

    // 2. Is anything in memory to answer from?
    check(stats.captureCount > 0, "\(stats.captureCount) captures on file", "no captures on file")
    check(stats.entityCount > 0, "\(stats.entityCount) things remembered", "nothing structured out of the captures yet")

    // 3. Which apps are being read, and which are silent?
    let coverage = try await store.captureQuality(since: now.addingTimeInterval(-7 * 86_400))
    let blind = coverage.filter { $0.grade == .nothing || $0.grade == .poor }
    if coverage.isEmpty {
        check(false, "", "no per-app coverage in the last week")
    } else {
        check(blind.isEmpty,
              "all \(coverage.count) apps in the last week read at least partially",
              "\(blind.count) of \(coverage.count) apps read poorly or not at all: "
                + blind.prefix(5).map(\.appName).joined(separator: ", "))
    }

    // 4. Is the deep pass still running, and is it reaching a model?
    //
    // The check that exists because its absence is invisible. Every other failure here shows
    // up as a thin answer somebody notices; a nightly pass that stopped months ago produces a
    // memory that is merely a little worse than it should be, forever, with nothing anywhere
    // saying so. Two separate questions, because a job that runs every night and reaches
    // nothing every night has a fresh last run and a broken pass.
    let passes = PassRecordStore.url(alongsideDatabase: databaseURL)
    if let last = PassRecordStore.latest(at: passes) {
        print("\n  last deep pass: \(last.summary(now: now))")
        let lastGood = PassRecordStore.latestReachingModel(at: passes)
        if let lastGood {
            let age = now.timeIntervalSince(lastGood.finishedAt)
            check(age <= PassRecordStore.staleAfter,
                  "deep pass is current",
                  """
                  no deep pass has reached a model for \(RulesOnlyBrain.formatDuration(age)). \
                  Memories from that window are whatever the rules alone could find. Check the \
                  machine running the model is awake and reachable, then run: memoir-ask --overnight
                  """)
        } else {
            check(false, "",
                  """
                  the deep pass has run \(PassRecordStore.load(at: passes).count) time(s) and a \
                  model has never answered. The pass is falling through to the rules every time - \
                  check MEMOIR_LOCAL_URL and that the model host is awake.
                  """)
        }
    } else {
        // Not a problem. Somebody who has never set up a second model should not be told their
        // memory is broken because they declined a thing they never asked for.
        print("\n  no deep pass has ever run (memoir-ask --overnight sets one going)")
    }

    // 5. Is anything being asserted that was never the user's?
    let commitments = try await store.entities(kind: .commitment, includeDeleted: false)
    let asserted = commitments.filter { !$0.provisional && $0.completedAt == nil }
    print("\n  \(asserted.count) commitment(s) asserted as owed, "
          + "\(commitments.count - asserted.count) kept but not asserted")

    // Is the model pass contributing anything?
    //
    // This check exists because nothing measured it, and two separate failures hid in that
    // gap: LLMExtractor was never wired into a MemoryService for months, and once wired it
    // failed on every call because its prompt overflowed the on-device context window. Both
    // looked exactly like a quiet day.
    //
    // It counts evidence actually WRITTEN, not rows the extractor proposed. A model can return
    // perfectly valid rows that the merge laws then discard (matching an entity the user
    // deleted, say), and a check reading the extractor's own output would call that healthy.
    let maybeYield = try await store.extractionYield()
    let maybeRecent = try await store.extractionYield(since: now.addingTimeInterval(-14 * 86_400))

    // Local probes only, no network: every isAvailable() is a key or a file or a framework
    // check. `nil` endpoint plus no FoundationModels is a legitimate configuration, not a fault.
    let doctorPreferred = BrainKind(rawValue: flagValue("--brain") ?? "") ?? .appleOnDevice
    let doctorRouter = BrainRouter(
        preferred: doctorPreferred, store: store,
        config: brainConfiguration(preferred: doctorPreferred))
    // The same question `RouterBackedBrain.preferredForExtraction()` asks, plus the on-device
    // guided path, which reaches FoundationModels directly and needs no brain at all.
    let reachable = await doctorRouter.available()
        .filter { $0 != .rulesOnly && $0 != .appleOnDevice }
    let modelPathOpen = GuidedExtractor.isAvailable() || !reachable.isEmpty

    if let yield = maybeYield, let recentYield = maybeRecent {
    if !modelPathOpen {
        print("  ok    no model configured for extraction; the rules run alone (this is a valid setup)")
    } else if yield.model == 0 && yield.attributed > 0 {
        check(false, "", "the model pass has never contributed a single piece of evidence, "
              + "across \(yield.attributed) attributed rows. Either it has not run against this "
              + "memory, or it is wired to a model that cannot extract. This check cannot tell "
              + "which. Run: memoir-ask --reindex --days 1 and read the log.")
    } else if yield.model == 0 {
        print("  note  nothing attributed yet: this memory predates extractor attribution "
              + "(\(yield.unattributed) rows). Consolidate once and check again.")
    } else if recentYield.model == 0 {
        check(false, "", "the model pass contributed \(yield.model) rows historically and "
              + "nothing in the last 14 days. It has stopped working.")
    } else {
        let via = yield.modelGuided > 0 && yield.modelJSON > 0
            ? "\(yield.modelJSON) via a brain, \(yield.modelGuided) on-device"
            : (yield.modelGuided > 0 ? "on-device guided generation" : "the configured brain")
        print("  ok    the model pass contributed \(recentYield.model) of "
              + "\(recentYield.attributed) evidence rows in the last 14 days (\(via))")
    }
    } else {
        // Read-only, so this cannot migrate the database it is inspecting, and should not.
        print("  note  this memory predates extractor attribution (schema v9). "
              + "Open Memoir once to upgrade it, then this check has something to read.")
    }

    print(problems == 0
          ? "\nHealthy."
          : "\n\(problems) problem(s). Answers will be wrong or thin until these are fixed.")
    exit(problems == 0 ? 0 : 1)
}

// Prints what the Vault settings pane would offer, without opening the app. The file
// dialog cannot reach an iCloud vault, so checking discovery from a terminal is the
// difference between "it does not work" and a fixable report.
if args.contains("--vaults") {
    let found = VaultDiscovery.discover()
    if found.isEmpty {
        print("No Obsidian vaults found. Memoir looks at Obsidian's own vault list, any")
        print("Obsidian MCP server configured for Claude, and the usual folders.")
    } else {
        print("\(found.count) vault\(found.count == 1 ? "" : "s") found:")
        for v in found {
            print("- \(v.name): \(v.noteCount) note\(v.noteCount == 1 ? "" : "s") \(v.source.label)")
            print("  \(v.url.path)")
        }
    }
    exit(0)
}

if args.contains("--embed") {
    let store = try Store(path: databaseURL)
    let index = SemanticIndex(store: store)
    var total = 0
    while true {
        let n = try await index.backfill(limit: 500)
        total += n
        if n == 0 { break }
        print("  embedded \(total)…")
    }
    print("embedded \(total) captures")

    // Then the passages, which are what search actually ranks on. A database indexed before
    // schema v4 has whole-capture vectors and no passage vectors, and every search re-derives
    // them: 3838ms a search on the 482-vector corpus, against 15ms once this has run. Costs
    // ~50ms per capture here, once.
    var passages = 0
    while true {
        let n = try await index.backfillPassages(limit: 200)
        passages += n
        if n == 0 { break }
        print("  passages for \(passages) captures…")
    }
    print("embedded passages for \(passages) captures")
    exit(0)
}

// The overnight pass: a big model on your own network, reading a whole day properly.
//
// This is the same machinery as `--reindex` with two differences that are the entire point.
//
// **It reads everything, not the tail.** `LLMExtractor` in its live shape asks the model about
// one window (the newest thing on screen) because consolidation runs while somebody is using
// the app and a sweep is not a slower version of that, it is a job nobody would wait for. Here
// nobody is waiting, so `LLMExtractor.batch` cuts the day into forty-capture windows and asks
// about all of them. A day of activity should be read as a day.
//
// **It writes down that it ran.** A model pass that fails and a model pass that finds nothing
// both produce no new rows, and a nightly job against a Mac mini that is asleep would print an
// honest-looking "0 new memories" every night until somebody happened to read a log file. So
// every run appends a `PassRecord`, and `--doctor` reads it. Silence is no longer an outcome.
//
// Cloud is off here for the same reason it is off in `--reindex`, and more so: this is a whole
// day of screen text in a batch nobody is watching, which is the worst possible thing to put
// one flag away from a third party. Your own box yes, an account with a retention policy no.
if args.contains("--overnight") {
    let startedAt = Date()
    let store = try Store(path: databaseURL)

    // localNetwork by default, because that is what this command is for. Overridable, so the
    // pass can be exercised on a machine that has only Apple's model.
    let nightBrain = BrainKind(rawValue: flagValue("--brain") ?? "") ?? .localNetwork
    var nightConfig = brainConfiguration(preferred: nightBrain)
    nightConfig.allowCloud = false
    let nightRouter = BrainRouter(preferred: nightBrain, store: store, config: nightConfig)

    let days = Double(flagValue("--days") ?? "1") ?? 1
    let since = Date().addingTimeInterval(-days * 86_400)
    // The stop. Each window costs the model real seconds, so a dense day is a job that might
    // not finish before morning; this is how long the night is allowed to be.
    let windowLimit = Int(flagValue("--windows") ?? "200") ?? 200

    let telemetry = ExtractionTelemetry()
    let memory = MemoryService(
        store: store,
        extractors: [
            RuleExtractor(),
            LLMExtractor.batch(
                brain: RouterBackedBrain(router: nightRouter),
                maxCalls: windowLimit,
                telemetry: telemetry
            ),
        ]
    )

    let capturesRead = ((try? await store.captures(since: since, limit: 20_000)) ?? []).count
    let window = days == 1 ? "24 hours" : "\(Int(days)) days"
    print("Deep pass: \(nightBrain.rawValue), last \(window)")
    print("\(capturesRead) capture(s) to read. This is not quick; that is the point.\n")

    let touched = try await memory.consolidate(since: since, captureLimit: 20_000)
    let counts = await telemetry.counts
    let reached = await telemetry.reachedModel

    // Why the pass was thin, when it was, in the record itself rather than only in a log.
    var note: String?
    if counts.asked == 0 {
        note = "no windows to ask about"
    } else if !reached {
        note = "every window failed; the model was configured but nothing answered"
    } else if counts.failed > 0 {
        note = "\(counts.failed) of \(counts.asked) windows failed"
    }

    let record = PassRecord(
        startedAt: startedAt,
        finishedAt: Date(),
        since: since,
        brain: nightBrain.rawValue,
        capturesRead: capturesRead,
        entitiesTouched: touched,
        reachedModel: reached,
        windowsAsked: counts.asked,
        windowsFailed: counts.failed,
        note: note
    )
    try? PassRecordStore.append(record, at: PassRecordStore.url(alongsideDatabase: databaseURL))

    print(record.summary())
    if let note { print("note: \(note)") }

    // Non-zero when the model never answered. A scheduler that only ever looks at exit codes
    // still finds out, which is the difference between a job that reports and a job that runs.
    exit((reached || counts.asked == 0) ? 0 : 1)
}

if args.contains("--reindex") {
    let store = try Store(path: databaseURL)
    // The one path in this binary that consolidates, so the one that needs the model pass.
    //
    // `allowCloud: false`, deliberately and unlike the main ask path. Reindexing walks twenty
    // thousand captures in a batch nobody is watching, and a flag that quietly posted all of
    // them to a third party would be the worst possible place for that to be easy. On-device
    // or nothing; `LLMExtractor` returns empty when no brain is available, so this degrades to
    // exactly the rules-only behaviour it had before.
    let reindexPreferred = BrainKind(rawValue: flagValue("--brain") ?? "") ?? .appleOnDevice
    var reindexConfig = brainConfiguration(preferred: reindexPreferred)
    // Cloud stays off here whatever --brain says, and a model on your own network does not.
    // The distinction is the one `allowLocalNetwork` exists to draw: your box is your box, a
    // third party with an account and a retention policy is not, and this is twenty thousand
    // captures in a batch nobody is watching, which is the worst place for that to be one flag
    // away. So Qwen on the Mac mini reindexes; Anthropic does not.
    reindexConfig.allowCloud = false
    let reindexRouter = BrainRouter(
        preferred: reindexPreferred, store: store, config: reindexConfig)
    let memory = MemoryService(
        store: store,
        extractors: [RuleExtractor(), LLMExtractor(brain: RouterBackedBrain(router: reindexRouter))]
    )
    let days = Double(flagValue("--days") ?? "30") ?? 30
    let since = Date().addingTimeInterval(-days * 86_400)
    let touched = try await memory.consolidate(since: since, captureLimit: 20_000)
    print("consolidated \(touched) entities from the last \(Int(days)) days")
    for kind in EntityKind.allCases {
        let list = try await store.entities(kind: kind, includeDeleted: false)
        guard !list.isEmpty else { continue }
        print("\n\(kind.rawValue) (\(list.count)):")
        for e in list.sorted(by: { $0.confidence > $1.confidence }).prefix(20) {
            print(String(format: "  %.2f  %@", e.confidence, e.title))
        }
    }
    exit(0)
}

// MARK: - Questions

var questions: [String] = []
if let path = flagValue("--batch") {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        stderrLine("cannot read \(path)"); exit(1)
    }
    questions = text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
} else {
    questions = args.filter { !$0.hasPrefix("--") }
    // Drop values that belong to flags.
    //
    // Every flag that takes a value must be listed here. Miss one and its value is silently
    // treated as a question: `memoir-ask --db /tmp/f.sqlite "..."` would ask the memory about
    // "/tmp/f.sqlite" and answer it, with no error anywhere.
    for flag in ["--brain", "--budget", "--batch", "--recent", "--db", "--database",
                 "--questions", "--ceiling", "--days", "--windows", "--now"] {
        if let v = flagValue(flag) { questions.removeAll { $0 == v } }
    }
}

guard !questions.isEmpty else {
    stderrLine("""
    usage: memoir-ask [options] "question" ...
      --batch <file>     one question per line (# comments ignored)
      --brain <kind>     appleOnDevice | localNetwork | anthropicAPI | claudeCode | rulesOnly
      --budget <tokens>  context budget, default 2000
      --context          print the context packet given to the brain
      --db <path>        read a different database (also MEMOIR_DB_PATH)
      --export <path>    write everything out; .md for the reading copy, else JSON
      --now <instant>    answer as if it were then, e.g. 2026-03-16T12:00:00Z
      --quiet            answer only
      --recent <n>       replay the last n logged asks instead of asking
      --overnight        deep pass: read the last day properly with a big model
        --days <n>         how far back, default 1
        --windows <n>      stop after n windows, default 200

    A model on your own network needs its address, and setting it is the consent:
      MEMOIR_LOCAL_URL=http://your-machine.local:1234/v1 MEMOIR_LOCAL_MODEL=qwen3-30b \\
        memoir-ask --brain localNetwork "what did I work on today"
    """)
    exit(1)
}

let store: Store
do {
    store = try Store(path: databaseURL)
} catch {
    stderrLine("cannot open \(databaseURL.path): \(error)")
    exit(1)
}

let memory = MemoryService(store: store, extractors: [RuleExtractor()])
let preferred = BrainKind(rawValue: flagValue("--brain") ?? "") ?? .appleOnDevice
let questionRouter = QuestionRouter()
// One clock, handed to everything downstream that has an opinion about what day it is.
// Nil means the wall clock, so the ordinary path is unchanged.
let clock: @Sendable () -> Date = {
    guard let fixed = referenceDate else { return { Date() } }
    return { fixed }
}()
let rewriter = QueryRewriter(now: clock)
// The comparison this whole brain exists for: same context, same prompt, different model.
// See BrainConfiguration.swift for the environment variables and why setting one is consent.
let brainConfig = brainConfiguration(preferred: preferred)
let router = BrainRouter(
    preferred: preferred,
    store: store,
    config: brainConfig,
    now: clock
)

if !quiet {
    let available = await router.available().map(\.rawValue).joined(separator: ", ")
    stderrLine("db:        \(databaseURL.path)")
    stderrLine("preferred: \(preferred.rawValue)   available: \(available)")
    stderrLine("timeout:   \(AppleOnDeviceBrain.effectiveTimeout)s   budget: \(budget) tok")
    if let referenceDate {
        stderrLine("now:       \(ISO8601DateFormatter().string(from: referenceDate)) (fixed)")
    }
    stderrLine("")
}

var failures = 0
for question in questions {
    let started = Date()
    do {
        // Rewrite first, route the rewritten form.
        //
        // "catch me up", "where was I" and "pick me up where I left off" all mean the same
        // thing and used to land in three different categories. Skipped entirely when a
        // deterministic rule already matched, so the fast path never pays for a model call
        // to learn something it already knew.
        let certain = QuestionRouter.asksAboutCommitments(question)
        let canonical = await rewriter.canonical(for: question, alreadyCertain: certain)
        let forRetrieval = canonical?.rawValue ?? question

        // A canonical form carries its own category, so it is never routed. Routing it cost a
        // full model call to re-derive a decision this code already made.
        let routing: Routing
        if let canonical {
            routing = Routing(category: canonical.category, margin: 1, wasFree: true)
        } else {
            routing = await questionRouter.route(forRetrieval) { await GuidedClassifier().classify($0) }
        }
        // The canonical form is a SEARCH KEY and nothing more. The original question is what
        // reaches the answer prompt and the grounding guards, because the user asked what they
        // asked, and a figure they typed themselves is evidence the rewrite could have dropped.
        let packet = try await memory.context(
            for: forRetrieval, budget: budget, now: clock(), category: routing.category)
        let reply = try await router.answer(
            question: question, context: packet, category: routing.category,
            canonicalQuestion: canonical?.rawValue)
        let wall = Date().timeIntervalSince(started)

        if quiet {
            print(reply.text)
        } else {
            print("══════════════════════════════════════════════════════════════")
            print("Q: \(question)")
            print("")
            print(reply.text)
            print("")
            let how = routing.wasFree ? "free" : "escalated"
            print("── \(routing.category.rawValue) (\(how), margin \(String(format: "%.3f", routing.margin))) · \(reply.brain.rawValue) · \(String(format: "%.1f", wall))s · context \(packet.approxTokens) tok · \(packet.captureIDs.count) captures")
            if reply.brain != preferred {
                print("   NOTE: fell back from \(preferred.rawValue)")
            }
            if showContext {
                print("── context given to the brain ──")
                print(packet.summary)
            }
        }
        AskLog.shared.record(
            question: question,
            answer: reply.text,
            brain: reply.brain,
            latency: reply.latency,
            context: packet
        )
    } catch {
        failures += 1
        stderrLine("FAILED: \(question)\n  \(error)")
    }
}

exit(failures == 0 ? 0 : 1)
