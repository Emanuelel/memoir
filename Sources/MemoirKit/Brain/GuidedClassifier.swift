import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Classifies a question using the on-device model, constrained so it *cannot* answer
/// with anything but a valid category.
///
/// This is the difference between asking and enforcing. Every hallucination guard in
/// `Grounding` exists because the model was allowed to write free prose and then had to be
/// policed afterwards. It invented figures, verbs and hostnames, and each one needed its
/// own detector. Guided generation removes the possibility instead of detecting the result:
/// `@Generable` compiles the Swift type into a schema, and decoding is constrained so no
/// token sequence outside that schema can be produced.
///
/// Used only as the escalation path for ``QuestionRouter``: the embedding stage answers
/// most questions in ~4ms, and this costs ~15s, so it runs only when the margin is thin.
public struct GuidedClassifier: Sendable {
    public init() {}

    /// Whether guided classification can run at all on this machine.
    public static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Whether the guided classifier may run at all.
    ///
    /// Separate from ``isAvailable()`` so the settings UI can still report honestly that the
    /// machine *has* a model while an eval run refuses to use it. See ``ModelGate``.
    static func isPermitted() -> Bool { !ModelGate.modelsDisabled && isAvailable() }

    /// Classifies a question. Returns nil when the model is unavailable or errors: the
    /// caller keeps the embedding result rather than failing the whole question.
    public func classify(_ question: String) async -> QuestionCategory? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard Self.isPermitted() else { return nil }
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let reply = try await session.respond(to: question, generating: GuidedCategory.self)
                return reply.content.category.asQuestionCategory
            } catch {
                Log.shared.debug("guided classification failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    static let instructions = """
    Classify what the user's question is asking for. Choose exactly one category.

    recall: they are trying to find something they saw before (a page, a repository, a \
    name, a URL).
    resumption: they are trying to remember what they were doing, or pick up where they \
    left off.
    accounting: they are asking how much time something took, or for a summary of a period.
    smallTalk: a greeting or pleasantry, not a request for information.
    outOfScope: it asks about the user's life away from the screen, which a screen-reading \
    memory cannot know (money spent, things bought, bank balances, phone calls, meals, \
    sleep, the weather). "What did I buy today" and "what did I have for lunch" are \
    outOfScope, not accounting or resumption: they are about a day, but not about a day at \
    the computer.
    Two things that look outOfScope and are not. Commitments: "what do I owe anyone", \
    "what did I promise", "what is due" are all recall, because Memoir records commitments. \
    The word "owe" is financial in ordinary English and is not financial here. And TIME \
    spent: "how much time did I spend in Chrome", "did I spend more time in Chrome or \
    Claude" are accounting. Money spent is out; time spent is the thing Memoir measures.
    """
}

#if canImport(FoundationModels)

/// The constrained output type.
///
/// Deliberately mirrors ``QuestionCategory`` rather than using it directly: `@Generable` is
/// a macro from a framework gated to macOS 26, and `QuestionCategory` is part of MemoirKit's
/// public API on macOS 15. Keeping them separate lets the shared type stay unconditional.
@available(macOS 26.0, *)
@Generable
enum GeneratedCategory: String, CaseIterable {
    case recall
    case resumption
    case accounting
    case smallTalk
    case outOfScope

    var asQuestionCategory: QuestionCategory {
        switch self {
        case .recall: return .recall
        case .resumption: return .resumption
        case .accounting: return .accounting
        case .smallTalk: return .smallTalk
        case .outOfScope: return .outOfScope
        }
    }
}

@available(macOS 26.0, *)
@Generable
struct GuidedCategory {
    @Guide(description: "the single category this question falls into")
    let category: GeneratedCategory
}

#endif
