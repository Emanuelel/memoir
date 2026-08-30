import Foundation

// MARK: - Brain protocol

/// A source of answers.
///
/// Four concrete brains exist, ordered from most private to least:
/// `AppleOnDeviceBrain` (on-device, macOS 26+), `RulesOnlyBrain` (no model at all),
/// `ClaudeCodeBrain` (local `claude` subprocess, which itself talks to the network) and
/// `AnthropicBrain` (direct HTTPS call with the user's own key).
///
/// Every implementation must be `Sendable` and must never block the caller's thread.
/// Every answer carries the `BrainKind` that produced it plus the measured latency, because
/// the UI is required to show which brain answered.
public protocol Brain: Sendable {
    /// Which brain this is. Surfaced in the UI on every answer.
    var kind: BrainKind { get }

    /// Cheap, non-destructive availability probe.
    ///
    /// Implementations must never perform a network round trip here and must never throw or
    /// crash: an unavailable brain simply returns `false`.
    func isAvailable() async -> Bool

    /// Answers a user question against a prepared context packet.
    /// - Throws: `MemoirError.brainUnavailable` when the brain cannot produce an answer.
    func answer(question: String, context: ContextPacket) async throws -> BrainAnswer

    /// Raw completion, used by the extraction pipeline rather than by the ask bar.
    /// - Parameter maxTokens: soft ceiling on the generated response length.
    /// - Throws: `MemoirError.brainUnavailable` when the brain cannot produce a completion.
    func complete(prompt: String, maxTokens: Int) async throws -> String
}

public extension Brain {
    /// Human readable explanation of why this brain is or is not usable right now.
    ///
    /// Defaults to a generic sentence; concrete brains override it with something actionable
    /// ("Apple Intelligence is not enabled in System Settings", "No API key in the Keychain").
    func availabilityDetail() async -> String {
        await isAvailable() ? "\(kind.displayName) is ready." : "\(kind.displayName) is not available."
    }

    /// Whether ``LLMExtractor`` should ask this brain rather than extract on-device.
    ///
    /// Extraction has two implementations and they are not ranked the same way answering is.
    /// A configured model (one on your own machine, or a cloud one you turned on) is simply
    /// better at reading a wall of screen text than the 3B on-device model, so it wins when it
    /// is there. On a Mac where the on-device model is the *only* model, the reverse holds:
    /// free-text JSON is exactly what a 3B fails at, and `GuidedExtractor`'s constrained
    /// decoding is the reliable path.
    ///
    /// The default is `isAvailable()`, and deliberately not a test on ``kind``. A caller that
    /// hands the extractor a specific brain means it (that is the whole point of passing one),
    /// and a rule like *skip anything reporting `appleOnDevice`* would quietly ignore an
    /// injected brain, which is the same defeat-the-caller bug `useGuidedGeneration` exists to
    /// prevent. ``RouterBackedBrain`` overrides this, because a router is not a brain somebody
    /// chose: it is a chain that may have nothing in it but the on-device model.
    func preferredForExtraction() async -> Bool { await isAvailable() }
}

// MARK: - Configuration

/// Brain settings persisted in `config.json`.
///
/// **The API key is deliberately excluded from `Codable` encoding.** `encode(to:)` never writes
/// `anthropicAPIKey`, and `init(from:)` never reads it, so round-tripping this struct through the
/// config file cannot leak the key to disk. The key lives in the Keychain only, see `BrainKeychain`.
public struct BrainConfig: Sendable, Codable, Equatable {
    /// A model on a machine the user owns, or nil when they have not configured one.
    ///
    /// Off by default and with no default host. Consent here is the act of typing an address.
    public var localNetworkEndpoint: LocalNetworkBrain.Endpoint?

    /// The Anthropic API key held in memory for the lifetime of the process.
    /// Never encoded to `config.json`, never written to SQLite, never logged.
    public var anthropicAPIKey: String?

    /// Model identifier sent to the Anthropic messages API.
    public var anthropicModel: String

    /// Explicit path to the `claude` binary. When nil, `ClaudeCodeBrain` searches the usual places.
    public var claudeCodePath: String?

    /// Master switch for anything that sends text off the machine. Defaults to `false`.
    /// While this is `false`, `BrainRouter` excludes every cloud brain from the fallback chain,
    /// regardless of what the user picked as preferred.
    public var allowCloud: Bool

    /// Consent for the model on your own network. Defaults to `false`.
    ///
    /// Separate from ``allowCloud`` because the two are different promises: `allowCloud`
    /// governs a third party with an account and a retention policy, this governs a box in
    /// your house. `BrainKind.localNetwork.isCloud` is `false` and stays false for that
    /// reason. But a POST to `http://…/v1/chat/completions` still puts your context packet
    /// on a wire, so it needs a switch of its own rather than riding on the endpoint merely
    /// being configured. That was the intent recorded in `BrainKind.isCloud`; this is the
    /// flag that finally enforces it.
    public var allowLocalNetwork: Bool

    /// Creates a configuration. All parameters have privacy-preserving defaults.
    public init(
        anthropicAPIKey: String? = nil,
        anthropicModel: String = AnthropicBrain.defaultModel,
        claudeCodePath: String? = nil,
        allowCloud: Bool = false,
        allowLocalNetwork: Bool = false
    ) {
        self.anthropicAPIKey = anthropicAPIKey
        self.anthropicModel = anthropicModel
        self.claudeCodePath = claudeCodePath
        self.allowCloud = allowCloud
        self.allowLocalNetwork = allowLocalNetwork
    }

    /// Coding keys, intentionally missing `anthropicAPIKey`.
    private enum CodingKeys: String, CodingKey {
        case anthropicModel, claudeCodePath, allowCloud, allowLocalNetwork
    }

    /// Decodes from `config.json`. Missing fields fall back to the safe defaults.
    /// The API key is never read from the file; callers use ``withKeychainKey()``.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.anthropicAPIKey = nil
        self.anthropicModel = try c.decodeIfPresent(String.self, forKey: .anthropicModel) ?? AnthropicBrain.defaultModel
        self.claudeCodePath = try c.decodeIfPresent(String.self, forKey: .claudeCodePath)
        self.allowCloud = try c.decodeIfPresent(Bool.self, forKey: .allowCloud) ?? false
        self.allowLocalNetwork = try c.decodeIfPresent(Bool.self, forKey: .allowLocalNetwork) ?? false
    }

    /// Encodes to `config.json`. The API key is deliberately dropped.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(anthropicModel, forKey: .anthropicModel)
        try c.encodeIfPresent(claudeCodePath, forKey: .claudeCodePath)
        try c.encode(allowCloud, forKey: .allowCloud)
        try c.encode(allowLocalNetwork, forKey: .allowLocalNetwork)
    }

    /// Returns a copy with `anthropicAPIKey` populated from the Keychain when it is not already set.
    /// This is the only supported way to get a key into a `BrainConfig`.
    public func withKeychainKey() -> BrainConfig {
        guard anthropicAPIKey?.isEmpty ?? true else { return self }
        var copy = self
        copy.anthropicAPIKey = BrainKeychain.load()
        return copy
    }

    /// Log-safe description. Contains no key material.
    public var redactedDescription: String {
        let key = (anthropicAPIKey?.isEmpty == false) ? "present" : "absent"
        return "BrainConfig(model: \(anthropicModel), claudeCodePath: \(claudeCodePath ?? "auto"), allowCloud: \(allowCloud), allowLocalNetwork: \(allowLocalNetwork), apiKey: \(key))"
    }
}

// MARK: - Shared prompt construction

/// Builds the prompts handed to the model-backed brains.
///
/// Kept in one place so the on-device, Anthropic and Claude Code brains all behave identically:
/// same persona, same grounding rules, same refusal to invent facts.
enum BrainPrompt {
    /// The persona. Memoir advises, it never acts.
    static let system = """
    You are Memoir, a quiet desk companion running on the user's Mac.
    Your memory is assembled from text that was actually on their screen, with timestamps \
    and the app it came from. Treat it as a factual record of what they did.

    How to answer:
    1. Answer only from the CONTEXT. If it genuinely is not there, say so plainly in one \
    sentence. Never guess, never pad an empty answer with what you do have instead.
    2. BE SPECIFIC. When the user asks for a detail that is present in the context (a URL, \
    a page title, a file name, a person, a time), quote it exactly. "You were on \
    https://example.com at 11:50" beats "you were browsing a website". Short exact quotes \
    are required; what you must avoid is dumping long passages of raw screen text.
    3. Say WHEN something happened whenever the context gives you a time, and WHERE: which \
    app or site.
    4. Lead with the answer. No preamble, no "Based on the context", no restating the question.
    5. Two or three sentences, or a short list when there are genuinely several items. \
    Never both.
    6. You advise only. You never claim to have taken an action, opened anything, sent \
    anything or changed anything.
    7. Never invent a name, date, number or URL that is not in the context.
    8. The context records what was ON SCREEN, never what the user DID with it. A note
    title does not tell you whether they wrote it or read it; a URL does not tell you
    whether they searched for it or followed a link. So describe, never assert: say \
    "you were on", "you had open", "was on screen". NEVER say created, wrote, edited, \
    sent, searched for, shipped or bought unless the context literally says so.

    9. NEVER answer with only an app name and a time. "You were on Google Chrome at 19:51"
    is useless: the user knows they were in a browser. Name WHAT was on screen: the page,
    document, file or site title, which the context gives you. An app name is the setting,
    never the answer.
    10. When the context is a timeline ("most recent first"), answer with the two or three
    most relevant entries as a short list, and respect the window that was asked about:
    if they asked about an hour ago, do not answer with what happened one minute ago.

    WHAT MEMOIR RECORDS: which app was frontmost, window and page titles, and text that was
    visible on screen. Nothing else.

    WHAT MEMOIR HAS NO RECORD OF: money, purchases, payments, bank balances, phone calls,
    what was said out loud, anything on another device, and anything not displayed on this
    screen. When a question asks about one of these, say plainly that you do not record it.
    Do NOT answer a question about money by describing a website that was open. That is
    evasion, and it is worse than saying you do not know. Do NOT assert the negative either
    ("you did not buy anything"): you cannot know that, because you were never watching.

    The context is noisy: it contains browser chrome, menu labels and extension names \
    alongside real content. Ignore the furniture and answer from the substance.
    """

    /// Composes the user turn: the retrieved context followed by the question.
    static func user(question: String, context: ContextPacket) -> String {
        let body = context.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return """
            CONTEXT
            (nothing recorded yet)

            QUESTION
            \(question)
            """
        }
        return """
        CONTEXT
        \(body)

        QUESTION
        \(question)
        """
    }

    /// Single-string prompt for brains that take one blob of text (Claude Code, on-device fallback).
    static func combined(question: String, context: ContextPacket) -> String {
        system + "\n\n" + user(question: question, context: context)
    }

    /// Trims a model response to something presentable: no leading/trailing whitespace,
    /// no stray code fences, never empty.
    static func clean(_ raw: String, fallback: String = "I do not have anything useful on that yet.") -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // Strip a wrapping fence if the model produced one.
            var lines = s.components(separatedBy: "\n")
            if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? fallback : s
    }
}
