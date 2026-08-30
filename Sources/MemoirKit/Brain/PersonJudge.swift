import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Asks the on-device model whether a name the extractor filed as a person is one.
///
/// ## Why a model rather than another rule
///
/// Because every rule ran out. Measured on a real database: 261 "people", of which the
/// heuristics could honestly remove 241: one-page names, usernames, feed and search-result
/// scrapings. What survived was `Claude Code`, `Apple Silicon`, `Dynamic Island`, `Boring
/// Notch`, `Transparent Background`. Every one of those is a capitalised multi-word phrase
/// seen across many pages over weeks, which is indistinguishable from `Elena Duarte` by any
/// property the database holds. Only a signal outside the database can tell them apart, and
/// knowing that "Dynamic Island" is a screen feature and "Elena Duarte" is a name is exactly
/// the kind of thing a language model knows and a `LIKE` clause never will.
///
/// This is the line `ARCHITECTURE.md` already draws: AI where language understanding is
/// irreducible, code where determinism matters. The contradiction sweep stays model-free
/// because a sweep that hallucinates contradictions is worse than no sweep. This is the other
/// side of it: a question with no deterministic answer available.
///
/// ## Constrained, not asked
///
/// Guided generation, the same as ``GuidedClassifier``: the verdict is a `@Generable` enum, so
/// no token sequence outside it can be produced. There is nothing to police afterwards because
/// there is nothing else it can say.
///
/// ## Biased towards keeping
///
/// The two mistakes are not equal. Wrongly dropping somebody removes a real person from their
/// own memory; wrongly keeping something leaves a product name in a list. Anything the model
/// is not sure about stays, and an unavailable model changes nothing at all.
public struct PersonJudge: Sendable {

    /// What the record can show about a candidate, which is what the model gets to see.
    public struct Candidate: Sendable, Equatable {
        public let id: ID
        public let name: String
        /// Window titles the name was seen on, deduplicated. The deciding context: "Dynamic
        /// Island" appears on pages about notch apps, "Elena Duarte" in a conversation.
        public let seenOn: [String]

        public init(id: ID, name: String, seenOn: [String]) {
            self.id = id
            self.name = name
            self.seenOn = seenOn
        }
    }

    public enum Verdict: String, Sendable {
        /// A human being the user could plausibly know or deal with.
        case person
        /// A product, feature, company, website, place, or interface element.
        case notAPerson
        /// Genuinely ambiguous. Kept, always.
        case unsure
    }

    public init() {}

    /// Whether this machine can judge at all.
    public static func isAvailable() -> Bool {
        // Gated by `ModelGate`, because this one runs inside consolidation, so a seeder
        // building a fixture would bake a model's judgements into the database it is supposed
        // to make reproducible, and the fixture would differ by machine before a single
        // question was asked.
        guard !ModelGate.modelsDisabled else { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Judges one candidate. Returns `.unsure` for every failure, so a model that errors or is
    /// missing can only ever leave the memory exactly as it found it.
    public func judge(_ candidate: Candidate) async -> Verdict {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard Self.isAvailable() else { return .unsure }
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let reply = try await session.respond(
                    to: Self.prompt(for: candidate),
                    generating: GeneratedVerdict.self
                )
                return reply.content.verdict.asVerdict
            } catch {
                Log.shared.debug("person judgement failed for \(candidate.name): \(error.localizedDescription)")
                return .unsure
            }
        }
        #endif
        return .unsure
    }

    /// What the model is shown. The name alone is not enough: "Dynamic Island" and "Elena
    /// Duarte" are both two capitalised words, and only the surrounding pages separate them.
    static func prompt(for candidate: Candidate) -> String {
        let context = candidate.seenOn.prefix(6)
            .map { "- " + $0.prefix(110) }
            .joined(separator: "\n")
        return """
        Name: \(candidate.name)

        Seen on these windows and pages:
        \(context.isEmpty ? "- (nothing recorded)" : context)
        """
    }

    static let instructions = """
    A memory tool reads the text on someone's screen and tries to spot the people in their \
    life. It gets this wrong often: it files product names, app names, interface features and \
    website brands as if they were people.

    You are given one name and the windows it was seen on. Decide what it is.

    person: a human being. A first name, a full name, or a name somebody would be addressed \
    by. Marco, Elena Duarte, Priya Raghunathan.

    notAPerson: anything else. Products and apps (Claude Code, Google Maps, Time Machine), \
    hardware and interface features (Apple Silicon, Dynamic Island, Boring Notch), companies \
    and websites, places, events (World Cup), and descriptive phrases lifted off a page \
    (Transparent Background, Vector Art, Final Part, English Sub).

    unsure: it could genuinely be either, or the pages give you nothing to go on. A name that \
    is also a common word, a single foreign name you do not recognise, a brand that is also a \
    surname.

    The windows matter more than the name. A name appearing on pages about software features \
    and product documentation is almost certainly a product. A name appearing in messages, \
    email, or a conversation is almost certainly a person.

    When you cannot tell, answer unsure. Removing a real person from somebody's memory of \
    their own life is far worse than leaving a product name in a list.
    """
}

#if canImport(FoundationModels)

/// The constrained output type.
///
/// Mirrors ``PersonJudge/Verdict`` rather than using it, for the same reason `GuidedCategory`
/// mirrors `QuestionCategory`: `@Generable` is gated to macOS 26 and the shared type has to
/// stay unconditional on macOS 15.
@available(macOS 26.0, *)
@Generable
enum GeneratedPersonVerdict: String, CaseIterable {
    case person
    case notAPerson
    case unsure

    var asVerdict: PersonJudge.Verdict {
        switch self {
        case .person: return .person
        case .notAPerson: return .notAPerson
        case .unsure: return .unsure
        }
    }
}

@available(macOS 26.0, *)
@Generable
struct GeneratedVerdict {
    let verdict: GeneratedPersonVerdict
}

#endif
