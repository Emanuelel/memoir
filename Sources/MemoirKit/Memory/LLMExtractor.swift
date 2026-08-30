import Foundation

/// A second extraction pass that asks a model for what the rules missed.
///
/// This runs *on top of* `RuleExtractor`, never instead of it. The rule pass is
/// deterministic and free; this one is best-effort. Anything the model returns that
/// does not parse cleanly is discarded rather than thrown, because a bad model
/// response must never cost the user the entities the rules already found.
///
/// ## How much it reads, stated plainly
///
/// Two shapes, chosen by `maxCalls`, and the difference between them is the whole design.
///
/// **Live (`maxCalls: 1`, the default).** One call over the newest window: `maxCapturesPerCall`
/// captures cut to `maxCharsPerCall`, which against the real on-device model is about **three
/// captures per consolidation**. That is a ceiling, not a bug to file. The on-device model
/// costs a double-digit number of seconds per call, and consolidation runs while somebody is
/// using the app, so sweeping a corpus here is not a slower version of this: it is a thing
/// nobody would ever wait for. The rules do the bulk; this adds a row or two they missed from
/// the most recent thing on screen.
///
/// **Batch (`maxCalls` large).** The captures are cut into windows and the model is asked about
/// every one of them, oldest first. Nobody is waiting, so the ceiling that protects the live
/// path is the wrong ceiling: a night pass over a day of activity should see the day, not the
/// last three rows of it. See ``batch(brain:)``.
///
/// Anyone raising the *live* limits should read the git history first: they used to be forty
/// captures and 12,000 characters, which overflowed the on-device context window on every
/// single call, failed, fell through to a brain that answered the extraction prompt as though
/// it were a question, and discarded the prose. Silently, for months. That is why the batch
/// shape exists as its own constructor rather than as bigger numbers here: the sizes that suit
/// a 30B model on your own network are the sizes that break Apple's 3B, and the guided fallback
/// re-cuts every window to a size the small model can survive (``guidedSafeChars``).
public struct LLMExtractor: Extractor {

    private let brain: any Brain
    private let useGuidedGeneration: Bool
    private let maxCapturesPerCall: Int
    private let maxCharsPerCall: Int
    private let maxCalls: Int
    private let telemetry: ExtractionTelemetry?

    /// The largest window the on-device model can be handed without overflowing.
    ///
    /// The guided fallback re-cuts to this before asking, because a batch window is sized for
    /// a model on your own network and Apple's 3B is not that model. Without this, switching
    /// the batch pass to the fallback would reproduce the context overflow the live limits
    /// exist to prevent: the same failure, arrived at by a new road.
    static let guidedSafeChars = 2_000

    /// Creates an extractor over a brain.
    ///
    /// - Parameters:
    ///   - brain: the model to ask. If it is unavailable, extraction returns empty.
    ///   - maxCapturesPerCall: how many captures to summarise in one prompt.
    ///   - maxCharsPerCall: hard ceiling on prompt size.
    /// - Parameter useGuidedGeneration: whether the on-device guided path may run when `brain`
    ///   does not extract, either because it is not preferred for extraction, or because it
    ///   answered with something unparseable. True in production.
    ///
    ///   **A caller that injected a brain in order to control what the model does should pass
    ///   false.** It is no longer strictly required, since the brain now goes first, but a test
    ///   asserting what the extractor produced still wants the guided path out of the way: it
    ///   reaches the real on-device model and varies run to run, so leaving it on makes the
    ///   result depend on whether the machine has Apple Intelligence.
    /// - Parameter maxCalls: how many windows to ask about. **1 is the live shape**: one call
    ///   over the newest window, which is what consolidation during a session can afford. A
    ///   large value sweeps the whole batch. It is a ceiling and not a promise: a batch that
    ///   cuts into fewer windows than this asks fewer times.
    public init(
        brain: any Brain,
        useGuidedGeneration: Bool = true,
        maxCapturesPerCall: Int = 8,
        maxCharsPerCall: Int = 2_000,
        maxCalls: Int = 1,
        telemetry: ExtractionTelemetry? = nil
    ) {
        self.useGuidedGeneration = useGuidedGeneration
        self.brain = brain
        self.maxCapturesPerCall = maxCapturesPerCall
        self.maxCharsPerCall = maxCharsPerCall
        self.maxCalls = max(1, maxCalls)
        self.telemetry = telemetry
    }

    /// The overnight shape: big windows, all of them, sized for a model on your own network.
    ///
    /// Forty captures and 12,000 characters are the numbers that overflowed Apple's on-device
    /// model and had to be cut to eight and 2,000. They are unremarkable for a 30B with a long
    /// context, and this constructor exists so that raising them is a decision about *which
    /// pass* rather than an edit to the live path's ceiling.
    ///
    /// - Parameter maxCalls: the stop. A day of dense capture cuts into a lot of windows and
    ///   each one costs the model real seconds, so an unbounded sweep is a job that might not
    ///   finish before morning. The caller decides how long the night is.
    public static func batch(
        brain: any Brain,
        maxCalls: Int = 200,
        telemetry: ExtractionTelemetry? = nil
    ) -> LLMExtractor {
        LLMExtractor(
            brain: brain,
            maxCapturesPerCall: 40,
            maxCharsPerCall: 12_000,
            maxCalls: maxCalls,
            telemetry: telemetry
        )
    }

    public func extract(from captures: [CaptureEvent]) async throws -> ExtractionResult {
        guard !captures.isEmpty else { return .empty }

        // Every window the batch cuts into, oldest first, then the last `maxCalls` of them.
        //
        // Taking the *end* rather than the start is what makes `maxCalls: 1` identical to the
        // old `captures.suffix(maxCapturesPerCall)`: the live pass still reads the newest thing
        // on screen, which is the only window it can afford and the one that matters most.
        let windows = buildWindows(captures)
        guard !windows.isEmpty else { return .empty }
        let selected = Array(windows.suffix(maxCalls))

        if selected.count > 1 {
            Log.shared.info(
                "extraction sweeping \(selected.count) window(s) of \(windows.count) "
                + "over \(captures.count) capture(s)")
        }

        var result = ExtractionResult.empty
        var asked = 0
        for window in selected {
            let pass = await extractOne(lines: window.lines, index: window.index)
            asked += 1
            guard let pass else { continue }
            result = result.merging(pass)
            // A sweep can run for an hour. Saying so as it goes is the difference between a
            // job you can watch and a job you can only find out about afterwards.
            if selected.count > 1, asked % 10 == 0 {
                Log.shared.info(
                    "extraction \(asked)/\(selected.count) windows, "
                    + "\(result.entities.count) row(s) so far")
            }
        }
        return result
    }

    /// Asks about one window: the configured brain first, the on-device model as the fallback.
    ///
    /// Returns nil when neither could answer. That is distinct from an empty result, which means a
    /// model ran and found nothing. The sweep does not stop on nil: one unreachable moment
    /// mid-night must not throw away the windows that already succeeded, and the run record is
    /// what tells you the pass was thin.
    private func extractOne(lines: [String], index: [Int: CaptureEvent]) async -> ExtractionResult? {
        // The configured brain first, when there is one. A model on your own machine or a
        // cloud one you turned on reads a wall of screen text better than the 3B on-device
        // model does, and it is reliable at JSON, so the reason guided generation exists does
        // not apply to it. `preferredForExtraction()` is what decides. See `RouterBackedBrain`
        // for why that is not the same question as `isAvailable()`.
        if await brain.preferredForExtraction() {
            do {
                let raw = try await brain.complete(prompt: jsonPrompt(lines), maxTokens: 600)
                if let items = parse(raw) {
                    await telemetry?.record(.brain)
                    return commit(items, index: index)
                }
                // Fall through to guided rather than returning empty. A brain that answered
                // unparseably has told us nothing about the on-device model, which may be
                // sitting right there able to do this properly.
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.shared.debug(
                    "LLM extraction returned unparseable output "
                    + "(\(raw.count) chars, starts: \(trimmed.prefix(120)) … ends: \(trimmed.suffix(120)))")
            } catch {
                Log.shared.warn("LLM extraction call failed: \(error)")
            }
        }

        // Guided generation: the fallback in general, and the *only* good path on a Mac whose
        // one model is Apple's. Nothing here can come back malformed, so there is no parse to
        // fail. See `GuidedExtractor` for why that beats retrying.
        //
        // Re-cut first. A batch window is sized for a model on your own network, and handing
        // that to Apple's 3B is the context overflow this file's history is about.
        guard useGuidedGeneration else {
            await telemetry?.record(.failed)
            return nil
        }
        guard let guided = await GuidedExtractor.extract(lines: Self.fitForGuided(lines)) else {
            await telemetry?.record(.failed)
            return nil
        }
        await telemetry?.record(.guided)
        // Say which of the two empty outcomes this was. "Ran and found nothing" and "could
        // not run" are the same zero in the entity count, and telling them apart by
        // subtracting yesterday's number is how the overflow went unnoticed for months.
        Log.shared.debug(
            "guided extraction returned \(guided.count) row(s) from \(lines.count) line(s)")
        var builder = ExtractionBuilder()
        builder.extractor = .modelGuided
        for item in guided {
            guard let capture = index[item.source] ?? index.values.first else { continue }
            builder.add(
                kind: item.kind,
                title: item.title,
                detail: nil,
                dueAt: nil,
                confidence: 0.5,
                capture: capture,
                snippet: MemoryText.truncate(
                    item.evidence.isEmpty ? item.title : item.evidence, max: 240)
            )
        }
        return builder.build()
    }

    /// The tail of `lines` that fits ``guidedSafeChars``.
    ///
    /// The *tail*, so the newest activity in the window survives the cut. Bracket numbers are
    /// carried in the line text and are never renumbered, so dropping the head leaves every
    /// surviving `source: n` pointing at the same capture it always did.
    static func fitForGuided(_ lines: [String]) -> [String] {
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            guard used + line.count < guidedSafeChars else { break }
            kept.append(line)
            used += line.count
        }
        return Array(kept.reversed())
    }

    /// Turns parsed JSON rows into an extraction result.
    ///
    /// Shared so the brain path has exactly one place that decides what a valid row is. It
    /// used to be inline, which is survivable with one caller and a trap with two.
    private func commit(_ items: [Item], index: [Int: CaptureEvent]) -> ExtractionResult {
        var builder = ExtractionBuilder()
        builder.extractor = .modelJSON
        for item in items {
            guard let kind = EntityKind(rawValue: item.kind.lowercased()) else { continue }
            let title = MemoryText.clean(item.title)
            guard title.count >= 2, title.count <= 200 else { continue }
            guard let capture = index[item.source ?? 0] ?? index.values.first else { continue }

            builder.add(
                kind: kind,
                title: title,
                detail: item.detail.map { MemoryText.truncate(MemoryText.clean($0), max: 400) },
                dueAt: item.due.flatMap(Self.parseDate),
                confidence: min(max(item.confidence ?? 0.5, 0.1), 0.9),
                capture: capture,
                snippet: MemoryText.truncate(
                    MemoryText.collapseWhitespace(item.evidence ?? title),
                    max: 240
                )
            )
        }
        return builder.build()
    }

    // MARK: - Prompt

    /// One window of activity: the numbered lines, and what each number points back at.
    struct Window {
        let lines: [String]
        let index: [Int: CaptureEvent]
    }

    /// Cuts the captures into windows, each within both ceilings.
    ///
    /// Numbering restarts at `[0]` in every window, because the number is an index into *this
    /// prompt* and a model told to return "the bracketed index of that line" can only mean the
    /// lines it was shown. Carrying a global number across windows would put `source: 412` in
    /// front of a model that was handed forty lines.
    ///
    /// Empty-text captures are skipped rather than counted, so a window is forty captures the
    /// model can actually read and not forty rows of which thirty were blank.
    func buildWindows(_ captures: [CaptureEvent]) -> [Window] {
        var windows: [Window] = []
        var lines: [String] = []
        var index: [Int: CaptureEvent] = [:]
        var used = 0
        let fmt = ISO8601DateFormatter()

        for capture in captures {
            let text = MemoryText.truncate(MemoryText.collapseWhitespace(capture.text), max: 600)
            guard !text.isEmpty else { continue }

            // Close before adding, not after, so a window never exceeds either ceiling. A line
            // longer than the whole char budget still gets a window of its own rather than
            // being dropped: truncation at 600 makes that nearly impossible, and silently
            // losing a capture is worse than one oversized prompt.
            if !lines.isEmpty {
                let wouldBe = "[\(lines.count)] \(fmt.string(from: capture.ts)) \(capture.appName): \(text)"
                if lines.count >= maxCapturesPerCall || used + wouldBe.count >= maxCharsPerCall {
                    windows.append(Window(lines: lines, index: index))
                    lines = []
                    index = [:]
                    used = 0
                }
            }

            let n = lines.count
            let line = "[\(n)] \(fmt.string(from: capture.ts)) \(capture.appName): \(text)"
            lines.append(line)
            index[n] = capture
            used += line.count
        }

        if !index.isEmpty {
            windows.append(Window(lines: lines, index: index))
        }
        return windows
    }

    /// The JSON instruction wrapped around those lines, for brains without guided generation.
    private func jsonPrompt(_ lines: [String]) -> String {
        """
        You are extracting structured memory from a person's on-screen activity.

        Return ONLY a JSON array. No prose, no markdown fence, no explanation.
        Each element must be an object with these keys:
          "kind": one of "person","project","thread","decision","commitment","note"
          "title": a short noun phrase, under 80 characters
          "detail": optional one-sentence elaboration, or null
          "due": optional ISO-8601 date for commitments, or null
          "confidence": number between 0 and 1
          "source": the [n] index of the line this came from
          "evidence": the exact substring that supports it

        Rules:
        - Extract only what is clearly supported by the text. Do not speculate.
        - A commitment is something the person owes someone or owes themselves.
        - Prefer few high-confidence items over many weak ones.
        - If nothing is worth extracting, return [].

        Activity:
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: - Parsing

    private struct Item: Decodable {
        let kind: String
        let title: String
        let detail: String?
        let due: String?
        let confidence: Double?
        let source: Int?
        let evidence: String?
    }

    /// Defensively pulls a JSON array out of a model response.
    ///
    /// Models add fences, preambles and trailing commentary. This finds the outermost
    /// bracketed array and decodes that, returning nil rather than throwing on failure.
    private func parse(_ raw: String) -> [Item]? {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end else {
            return nil
        }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Item].self, from: data)
    }

    private static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withFullDate]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
