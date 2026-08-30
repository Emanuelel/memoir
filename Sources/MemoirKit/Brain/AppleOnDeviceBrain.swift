import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model, via the `FoundationModels` framework.
///
/// Nothing leaves the machine. This is the preferred brain whenever it is usable.
///
/// It requires macOS 26 **and** Apple Intelligence switched on **and** the model downloaded.
/// On any machine where one of those is missing, ``isAvailable()`` returns `false` and
/// ``availabilityDetail()`` explains which one. It never traps, never crashes, and never
/// touches `FoundationModels` symbols at runtime on an OS that does not have them: the whole
/// implementation sits behind `#if canImport(FoundationModels)` for compile time and
/// `if #available(macOS 26.0, *)` for runtime.
public struct AppleOnDeviceBrain: Brain {
    /// Creates the brain. Construction is free and always succeeds; availability is checked lazily.
    public init() {}

    /// Always `.appleOnDevice`.
    public var kind: BrainKind { .appleOnDevice }

    /// Soft ceiling applied when the caller does not care.
    private static let defaultMaxTokens = 700

    /// How long to wait for the on-device model before giving up and letting the
    /// router fall back. Deliberately short: a companion that freezes is worse than
    /// one that answers plainly.
    // Cold-start on this model is slow: the first request after launch pays session
    // setup and model residency on top of generation. 12s was tuned against an already
    // warm model and made every first ask fall through to the rules brain.
    ///
    /// Overridable via `MEMOIR_GENERATION_TIMEOUT` so the test suite does not sit through a
    /// real 60s cold start, and more importantly so a generation cannot outlive the
    /// temp database a test is about to delete underneath it.
    public static var effectiveTimeout: Double { generationTimeout }

    private static let generationTimeout: Double = {
        if let raw = ProcessInfo.processInfo.environment["MEMOIR_GENERATION_TIMEOUT"],
           let value = Double(raw), value > 0 {
            return value
        }
        return 60
    }()

    // MARK: - Availability

    /// When the on-device model was last refused, and why.
    ///
    /// Three wrong diagnoses were written before this one, so the evidence is worth keeping.
    /// `SystemLanguageModel.availability` says `.available`, and every request fails instantly:
    ///
    ///     GenerationError -1
    ///       └ GenerationError -1
    ///           └ com.apple.SensitiveContentAnalysisML 15
    ///               └ ModelManagerServices.ModelManagerError 1013
    ///
    /// The sensitive-content frame is a red herring: `.permissiveContentTransformations` drops
    /// it and leaves 1013 untouched. So is the idea that the model is missing. `modelmanagerd`
    /// finds all four assets, locks them, resolves the session, and only then says no:
    ///
    ///     ModelCatalog  Found asset bundle com.apple.fm.language.instruct_3b.fm_api_generic
    ///     RequestManager  Request denied due to policy CriticalMemoryPressure (background)
    ///     Model XPC Request  Not executed due to current system state, try again later
    ///
    /// macOS will not page in a 3B model on a machine already swapping. That is what 1013 means
    /// here, and the API says none of it: the error arrives with no reason and no message, and
    /// only the system log carries `CriticalMemoryPressure`.
    ///
    /// Which makes this weather, not climate. The brain is fine and the Mac is full, so the
    /// answer is to stop asking for a few minutes rather than to give up: a refusal caused by
    /// memory pressure would otherwise disable a perfectly good model until relaunch. Backing
    /// off still buys back the three seconds per question that were being spent on a request
    /// that could not be served.
    private static let refusal = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// How long to leave it alone after a refusal. Long enough that a busy Mac gets a chance to
    /// breathe, short enough that closing a few windows makes Memoir clever again quite soon.
    static let backoff: TimeInterval = 5 * 60

    /// Records a refusal from the model service, which means the request never reached the
    /// model. A timeout or a cancelled request is an ordinary failure and is not recorded.
    static func noteFailure(_ error: Error, now: Date = Date()) {
        let chain = rootDomains(of: error as NSError)
        guard chain.contains(where: { $0.contains("ModelManager") }) else { return }
        refusal.withLock { $0 = now }
        Log.shared.warn("on-device model refused the request, resting it for \(Int(backoff / 60)) minutes")
    }

    /// Forgets any refusal. For tests, and for the moment a generation succeeds.
    static func clearRefusal() { refusal.withLock { $0 = nil } }

    /// Whether the brain is resting after a refusal.
    static func isResting(now: Date = Date()) -> Bool {
        guard let last = refusal.withLock({ $0 }) else { return false }
        return now.timeIntervalSince(last) < backoff
    }

    /// Every error domain in a nested chain, which is where the real cause hides.
    static func rootDomains(of error: NSError, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        var out = [error.domain]
        if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            out += rootDomains(of: under, depth: depth + 1)
        }
        if let many = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] {
            for e in many { out += rootDomains(of: e as NSError, depth: depth + 1) }
        }
        return out
    }

    /// Whether the system model can answer right now.
    ///
    /// Returns `false` (never throws) when the OS is older than macOS 26, when the framework is
    /// absent from the SDK, when the device is not eligible, when Apple Intelligence is off,
    /// when the model is still downloading, or when the model service refused a request in the
    /// last few minutes.
    public func isAvailable() async -> Bool {
        // `MEMOIR_NO_MODEL` means no model anywhere, not "no model except the one you asked
        // for". Reporting unavailable here sends `BrainRouter` down the fallback chain it
        // already has, and the last link (`RulesOnlyBrain`) is deterministic by construction,
        // which is the whole reason a gate wants this.
        guard !ModelGate.modelsDisabled else { return false }
        // Then the softer one. The gate is a standing instruction and outranks a refusal that
        // will have expired in five minutes.
        if Self.isResting() { return false }
        switch Self.status() {
        case .available: return true
        case .unavailable: return false
        }
    }

    /// A sentence the settings UI can show verbatim explaining the current state.
    public func availabilityDetail() async -> String {
        if Self.isResting() {
            return """
            Apple's on-device model turned the last request down. That normally means this Mac \
            is short on memory, because macOS will not load the model while it is swapping. \
            Memoir will try it again in a few minutes.
            """
        }
        switch Self.status() {
        case .available:
            return "Apple's on-device model is ready. Nothing leaves this Mac."
        case .unavailable(let reason):
            return reason
        }
    }

    /// Internal availability result: either usable, or unusable with a human readable reason.
    enum Status {
        case available
        case unavailable(String)
    }

    /// Probes `SystemLanguageModel.default` defensively.
    static func status() -> Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable("This Mac does not support Apple Intelligence, so the on-device model is not available.")
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri to use the on-device model.")
                case .modelNotReady:
                    return .unavailable("The on-device model is still downloading. Try again once Apple Intelligence has finished setting up.")
                @unknown default:
                    return .unavailable("The on-device model is unavailable for an unknown reason.")
                }
            @unknown default:
                return .unavailable("The on-device model reported an availability state Memoir does not recognise.")
            }
        } else {
            return .unavailable("The on-device model needs macOS 26 or later. Memoir will use its no-model answers instead.")
        }
        #else
        return .unavailable("This build of Memoir was compiled without the FoundationModels framework, so the on-device model is not available.")
        #endif
    }

    // MARK: - Brain

    /// Answers a question against the context packet using the on-device model.
    /// - Throws: `MemoirError.brainUnavailable(.appleOnDevice, _)` when the model is off, missing, or errors.
    public func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
        let started = Date()
        let text = try await generate(
            instructions: BrainPrompt.system,
            prompt: BrainPrompt.user(question: question, context: context),
            maxTokens: Self.defaultMaxTokens
        )
        return BrainAnswer(
            text: BrainPrompt.clean(text),
            brain: .appleOnDevice,
            citedCaptureIDs: context.captureIDs,
            latency: Date().timeIntervalSince(started)
        )
    }

    /// Raw completion used by the extraction pipeline.
    /// - Throws: `MemoirError.brainUnavailable(.appleOnDevice, _)` when the model is unusable.
    public func complete(prompt: String, maxTokens: Int) async throws -> String {
        let text = try await generate(instructions: nil, prompt: prompt, maxTokens: maxTokens)
        return BrainPrompt.clean(text, fallback: "")
    }

    // MARK: - Generation

    #if canImport(FoundationModels)
    /// Holds the one session ``prewarm()`` warmed at launch, and builds a fresh one for
    /// every request after it. Read ``WarmSession`` before changing any of this: the
    /// numbers there say warming is worth about 1.6s once, and nothing thereafter.
    @available(macOS 26.0, *)
    private static let sessionBox = WarmSession()

    @available(macOS 26.0, *)
    actor WarmSession {
        /// A session built and prewarmed ahead of time, waiting for the next request.
        /// Nil once it has been handed out, and never rebuilt in the background (see below).
        private var staged: LanguageModelSession?

        /// The instructions `staged` was built with. A request asking for different ones
        /// cannot use it: `complete` passes nil where `answer` passes the persona.
        private var stagedInstructions: String?

        /// A FRESH session per request, deliberately.
        ///
        /// Reusing one looked like an optimisation and was a bug: `LanguageModelSession`
        /// accumulates the transcript, so the second question carried the first question's
        /// context too and blew the model's window: "the question plus its context was too
        /// large". Memoir keeps its state in SQLite, not in a transcript, so there is nothing
        /// to preserve between asks.
        ///
        /// The one exception is the session ``prewarm()`` already built and warmed at launch:
        /// it has an empty transcript, so handing it to the first request is free. It used to
        /// be built and thrown away, which made `prewarm()` a no-op by construction.
        ///
        /// MEASURED, macOS 26.5, 8 000-char context, streamed so prefill and decode separate,
        /// three paired rounds alternating prewarmed and fresh:
        ///
        ///     prewarmed session   mean time to first token 19 301ms  (26 935, 16 803, 14 166)
        ///     fresh session       mean time to first token 18 983ms  (16 905, 26 299, 13 744)
        ///
        /// The difference is inside the run-to-run noise. Warming buys nothing measurable
        /// because the model is already resident process-wide; what the user waits for is
        /// prefill of the CONTEXT, which no session can cache because it is different every
        /// time. Same rig, same session, context alone varied:
        ///
        ///     empty context (   85 chars)   time to first token  1 582ms
        ///     5 lines       ( 1 184 chars)                       7 367ms
        ///     20 lines      ( 4 482 chars)                      11 606ms
        ///     40 lines      ( 8 880 chars)                      17 252ms
        ///
        /// Roughly 1.9s per thousand characters of prompt, on a 1.6s floor. So at most 1.6s
        /// of a twenty second answer is session and model setup, and the rest is the size of
        /// the packet. Shrink the packet to make generation faster; do not come back here.
        ///
        /// Restaging a replacement in the background was tried and is WORSE, because the
        /// prewarm competes with the live request for the same silicon: 21 184 / 27 455 /
        /// 25 254ms against 18 393 / 15 368 / 21 030ms for the same three questions with no
        /// background warming at all. So exactly one session is ever staged, at launch.
        func session(instructions: String?) -> LanguageModelSession {
            if let staged, stagedInstructions == instructions {
                self.staged = nil
                self.stagedInstructions = nil
                return staged
            }
            return LanguageModelSession(instructions: instructions)
        }

        /// Builds and warms the session the next matching request will use.
        func stage(instructions: String?) {
            let fresh = LanguageModelSession(instructions: instructions)
            fresh.prewarm()
            staged = fresh
            stagedInstructions = instructions
        }

        /// Drops the staged session after a failure, so a stalled one is never handed out.
        func reset() {
            staged = nil
            stagedInstructions = nil
        }
    }
    #endif

    /// Pays session setup at launch so the user's first question is not the one that waits.
    ///
    /// Worth roughly 1.6s on the first ask and nothing after it (see ``WarmSession`` for the
    /// measurements). It is cheap and it is honest now: the warmed session is kept and handed
    /// to the first request rather than built and dropped on the floor.
    public func prewarm() async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = Self.status() else { return }
            await Self.sessionBox.stage(instructions: BrainPrompt.system)
        }
        #endif
    }

    /// Generation against the staged warm session when one is waiting, a fresh one otherwise.
    private func generate(instructions: String?, prompt: String, maxTokens: Int) async throws -> String {
        if case .unavailable(let reason) = Self.status() {
            throw MemoirError.brainUnavailable(.appleOnDevice, reason)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = await Self.sessionBox.session(instructions: instructions)
            let options = GenerationOptions(
                temperature: 0.3,
                maximumResponseTokens: max(32, maxTokens)
            )
            do {
                // The framework can report itself available and then stall. Observed on
                // machines where Apple Intelligence is mid-download or half-enabled. A
                // desk companion that freezes for a minute reads as broken, so cap it and
                // let the router fall through to the rules brain instead.
                // `respond` does not honour cancellation, so a task group would still
                // block on the abandoned child. Race two unstructured tasks through a
                // one-shot box instead and simply walk away from the slow one.
                let box = ResultBox()
                let work = Task {
                    do {
                        let content = try await session.respond(to: prompt, options: options).content
                        await box.offer(.success(content))
                    } catch {
                        await box.offer(.failure(error))
                    }
                }
                let timer = Task {
                    try? await Task.sleep(for: .seconds(Self.generationTimeout))
                    await box.offer(.failure(MemoirError.brainUnavailable(
                        .appleOnDevice,
                        "The on-device model did not respond within \(Int(Self.generationTimeout))s."
                    )))
                }
                let outcome = await box.wait()
                timer.cancel()
                if case .failure = outcome {
                    // Never reuse a session that just stalled or errored.
                    work.cancel()
                    await Self.sessionBox.reset()
                }
                switch outcome {
                case .success(let content):
                    // Proof the Mac has room again, which outranks any earlier refusal.
                    Self.clearRefusal()
                    return content
                case .failure(let error):
                    // Leave `work` running; it is harmless and will finish on its own.
                    _ = work
                    throw error
                }
            } catch {
                // Records a refusal so the router rests the brain instead of paying three
                // seconds a question to be turned down again.
                Self.noteFailure(error)
                let detail = Self.describe(error)
                Log.shared.warn("On-device generation failed: \(detail)")
                throw MemoirError.brainUnavailable(.appleOnDevice, detail)
            }
        } else {
            throw MemoirError.brainUnavailable(.appleOnDevice, "The on-device model needs macOS 26 or later.")
        }
        #else
        throw MemoirError.brainUnavailable(
            .appleOnDevice,
            "This build of Memoir was compiled without the FoundationModels framework."
        )
        #endif
    }

    /// Turns a generation error into something a person can act on.
    private static func describe(_ error: any Error) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let genError = error as? LanguageModelSession.GenerationError {
                switch genError {
                case .exceededContextWindowSize:
                    return "The question plus its context was too large for the on-device model."
                case .guardrailViolation:
                    return "The on-device model declined to answer this one."
                case .unsupportedLanguageOrLocale:
                    return "The on-device model does not support this language yet."
                case .assetsUnavailable:
                    return "The on-device model assets are not installed yet."
                case .rateLimited:
                    return "The on-device model is busy. Try again in a moment."
                default:
                    return "On-device generation failed: \(genError.localizedDescription)"
                }
            }
        }
        #endif
        return "On-device generation failed: \(error.localizedDescription)"
    }
}

/// A one-shot mailbox: the first result offered wins, later ones are dropped.
///
/// Used to race the on-device model against a timeout without waiting on the loser,
/// which matters because `FoundationModels` generation does not honour cancellation.
actor ResultBox {
    private var value: Result<String, any Error>?
    private var waiters: [CheckedContinuation<Result<String, any Error>, Never>] = []

    func offer(_ result: Result<String, any Error>) {
        guard value == nil else { return }
        value = result
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume(returning: result) }
    }

    func wait() async -> Result<String, any Error> {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
