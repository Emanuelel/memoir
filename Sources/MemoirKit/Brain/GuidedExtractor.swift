import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Extracts memories from screen activity using the on-device model, constrained so it
/// *cannot* return anything but valid rows.
///
/// ## Why this exists
///
/// ``LLMExtractor`` asked for a JSON array in a prompt and parsed whatever came back. Measured
/// against the real on-device model over two days of captures, that failed to parse on two runs
/// in six; before the batch size was cut to fit the context window, on six in six. A
/// discarded batch is silent: an extractor failing every time and one finding nothing produce
/// the same empty result.
///
/// Retrying would be detecting the result. This removes the possibility instead, exactly as
/// ``GuidedClassifier`` does for routing: `@Generable` compiles the Swift type into a schema and
/// decoding is constrained, so no token sequence outside that schema can be produced. There is
/// no malformed output to parse, because malformed output cannot be generated.
///
/// *Anything you put in a prompt is a suggestion. Anything you check after generation is a
/// guarantee*. And anything the decoder cannot emit is not even a risk.
///
/// ## Why it runs before the brain, even when a better brain exists
///
/// A frontier model would extract better and is reliable at JSON. It is still second here, and
/// the reason is not quality:
///
/// - **Extraction reads more than anything else in Memoir.** It is handed raw screen text, not
///   a question and a curated packet. Keeping that on-device by default means the stage with the
///   widest view is the stage that never leaves the machine, whatever `allowCloud` says.
/// - **It no longer depends on the brain chain at all.** This path talks to `FoundationModels`
///   directly, so extraction works on a machine whose only brain is `RulesOnlyBrain` (which,
///   before this, silently answered extraction prompts as though they were questions).
///
/// The JSON path in ``LLMExtractor`` remains for machines without `FoundationModels`, where a
/// configured cloud or local-network brain is the only model there is.
///
/// ## What it deliberately does not ask for
///
/// The schema carries kind, title, evidence and the line it came from. No due date, no detail,
/// no confidence. Every field costs tokens and reliability on a 3B model, and the rule pass
/// already resolves dates properly against an injected reference date: a model guessing
/// "Friday" into an ISO-8601 string is a worse answer than `RuleExtractor`'s, arrived at more
/// expensively. Dated commitments are the rules' job; this pass is for what they missed.
public enum GuidedExtractor {

    /// One extracted row, in the shape ``LLMExtractor`` can commit.
    public struct Item: Sendable, Equatable {
        public let kind: EntityKind
        public let title: String
        public let evidence: String
        public let source: Int
    }

    /// Whether guided extraction can run on this machine.
    public static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Whether it may run. See ``ModelGate``.
    public static func isPermitted() -> Bool { !ModelGate.modelsDisabled && isAvailable() }

    /// Extracts from already-numbered activity lines.
    ///
    /// Returns `nil` when the model is unavailable or the call fails, distinct from an empty
    /// array, which means it ran and found nothing worth keeping. The caller needs to tell
    /// those apart: one is a reason to try the brain instead, the other is an answer.
    public static func extract(lines: [String]) async -> [Item]? {
        guard isPermitted(), !lines.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let reply = try await session.respond(
                    to: lines.joined(separator: "\n"), generating: GeneratedMemories.self)
                return reply.content.items.compactMap { row in
                    let title = MemoryText.clean(row.title)
                    guard title.count >= 2, title.count <= 200 else { return nil }
                    guard let kind = row.kind.asEntityKind else { return nil }
                    return Item(
                        kind: kind,
                        title: title,
                        evidence: MemoryText.collapseWhitespace(row.evidence),
                        source: row.source
                    )
                }
            } catch {
                // Same posture as every other model stage here: a model that cannot run must
                // cost nothing, not break consolidation. The rule pass has already committed.
                Log.shared.debug("guided extraction failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    static let instructions = """
    You are reading numbered lines of a person's on-screen activity. Each line starts with \
    its index in brackets, then a timestamp and an app name.

    Return the things worth remembering. Prefer very few, high-confidence rows over many weak \
    ones. Return nothing at all if nothing stands out. That is a normal and correct answer.

    kind:
      person      a human being the user deals with, named
      project     a piece of work with a name
      thread      an ongoing conversation or topic
      decision    something settled
      commitment  something the USER owes someone, or owes themselves
      note        anything else worth keeping

    A commitment is only a commitment if the user made it. Text on a page, someone else's \
    message, marketing copy and a model's own suggestions are not the user's promises.

    title must be a short noun phrase, under 80 characters.
    evidence must be copied exactly from the line it came from, not paraphrased.
    source must be the bracketed index of that line.
    """
}

#if canImport(FoundationModels)

/// The constrained kind.
///
/// Mirrors ``EntityKind`` rather than using it: `@Generable` is a macOS 26 macro and
/// `EntityKind` is public API on macOS 15, so the shared type stays unconditional. Same
/// reasoning as ``GuidedClassifier``'s category.
@available(macOS 26.0, *)
@Generable
enum GeneratedKind: String, CaseIterable {
    case person
    case project
    case thread
    case decision
    case commitment
    case note

    var asEntityKind: EntityKind? { EntityKind(rawValue: rawValue) }
}

@available(macOS 26.0, *)
@Generable
struct GeneratedMemory {
    @Guide(description: "what kind of thing this is")
    let kind: GeneratedKind
    @Guide(description: "a short noun phrase naming it, under 80 characters")
    let title: String
    @Guide(description: "text copied exactly from the line this came from")
    let evidence: String
    @Guide(description: "the bracketed index of the line this came from")
    let source: Int
}

@available(macOS 26.0, *)
@Generable
struct GeneratedMemories {
    @Guide(description: "the things worth remembering; empty when nothing stands out")
    let items: [GeneratedMemory]
}

#endif
