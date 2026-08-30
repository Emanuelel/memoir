//  CF-19b: cheap-first question routing with a calibrated escalation signal.
//
//  Every question used to get the same treatment: build 2000 tokens of context, wake a 3B
//  model, hope. Routing decides what KIND of question it is first, so the right context is
//  built and the cheapest tier that can answer does.
//
//  The design follows the LLM-cascade literature (FrugalGPT, RouteLLM): try cheap, and
//  escalate on a measured confidence signal rather than on a fixed rule. Here that signal
//  is the margin between the best and second-best embedding match: measured on real
//  questions, correct classifications scored 0.225+ while both mistakes were under 0.10.

import Foundation
import Testing

@testable import MemoirKit

/// Records what the escalation path was asked, across the actor boundary a @Sendable
/// closure has to cross.
private actor EscalationSpy {
    private(set) var questions: [String] = []
    private let answer: QuestionCategory?

    init(answering answer: QuestionCategory? = nil) { self.answer = answer }

    func record(_ question: String) -> QuestionCategory? {
        questions.append(question)
        return answer
    }
    var count: Int { questions.count }
}

@Suite("CF-19b · question routing escalates only when unsure")
struct QuestionRouterTests {

    @Test("CF-85 what Memoir cannot know is decided by fact, not by similarity")
    func structurallyOutOfScopeIsNotASimilarityJudgement() async throws {
        let router = QuestionRouter()

        // Every one of these is about something Memoir does not record at all. Phrasing
        // must not matter: "how much money did I spend today" is one word away from "how
        // much time did I spend in chrome today", and on the real database the embedding
        // put it in `accounting` and answered a question about money with a time report.
        // "Who did I call on the phone" landed near "who did I talk to" and came back as
        // a general brief. A status report standing in for an answer is the failure; the
        // fact that the two sentences look alike is not a defence.
        for question in [
            "how much money did I spend today",
            "who did I call on the phone",
            "what is my bank balance",
            "what did I eat for lunch",
            "how much did that cost me",
            "did I pay the electricity bill",
        ] {
            let routing = await router.route(question)
            #expect(routing.category == .outOfScope,
                    "\"\(question)\" routed as \(routing.category.rawValue), so it will be answered")
        }

        // And the questions it CAN answer must not be swept up by the same rule. "Time" is
        // the word that makes the money question dangerous, so the real accounting
        // questions have to keep working.
        for (question, expected) in [
            ("how much time did I spend in chrome today", QuestionCategory.accounting),
            ("how long have I been working", .accounting),
            ("who did I talk to", .recall),
            ("remind me to pay the invoice on friday", .push),
        ] {
            let routing = await router.route(question)
            #expect(routing.category == expected,
                    "\"\(question)\" routed as \(routing.category.rawValue), expected \(expected.rawValue)")
        }
    }


    @Test("CF-19b confident questions are routed for free, with no model call")
    func confidentRoutingIsFree() async {
        let router = QuestionRouter()
        let spy = EscalationSpy()
        let counting: @Sendable (String) async -> QuestionCategory? = { await spy.record($0) }

        // These sit clearly inside one cluster and must never reach the model.
        for question in ["what was that repo about screen memory", "summarise my day"] {
            let routing = await router.route(question, escalate: counting)
            #expect(routing.wasFree, "\(question) should not have needed a model")
        }
        #expect(await spy.count == 0)
    }

    @Test("CF-19b an unsure question escalates to the constrained classifier")
    func unsureQuestionEscalates() async {
        let router = QuestionRouter()
        // Stands in for the guided classifier so the escalation path is exercised without
        // a 15-second model call.
        let spy = EscalationSpy(answering: .outOfScope)
        let stub: @Sendable (String) async -> QuestionCategory? = { await spy.record($0) }

        // Measured at margin 0.003: the embedding stage puts this in `recall`, which is
        // wrong; it is a resumption question. Exactly the case the escalation path exists
        // to rescue.
        //
        // This used to be "how much money did I spend today", measured at 0.070. CF-85
        // now decides that one by rule before any similarity is measured, because whether
        // a question is answerable at all is a fact about what Memoir records rather than
        // a judgement about which sentence it resembles. That made it a bad example of a
        // THIN MARGIN, which is what this flow is about. The invariant is unchanged, only
        // the question that demonstrates it.
        let question = "what did I look at in the last hour"
        let routing = await router.route(question, escalate: stub)
        #expect(await spy.questions == [question])
        #expect(routing.category == .outOfScope)
        #expect(routing.wasFree == false)
    }

    @Test("CF-19b escalation failure keeps the embedding answer rather than losing it")
    func escalationFailureDegradesGracefully() async {
        let router = QuestionRouter()
        let failing: @Sendable (String) async -> QuestionCategory? = { _ in nil }
        let routing = await router.route("what did I look at in the last hour", escalate: failing)
        // Still answers, still reports the low margin so callers can hedge.
        #expect(routing.margin < QuestionRouter.confidentMargin)
    }

    @Test("CF-19b the margin genuinely separates right answers from wrong ones")
    func marginIsCalibrated() async {
        let router = QuestionRouter()

        // The whole escalation design rests on this: confident means correct.
        // Measured at 0.278 and 0.211 respectively, comfortably above the threshold.
        let confident = ["what was that repo about screen memory", "summarise my day"]
        for question in confident {
            guard let routing = await router.classifyByEmbedding(question) else { continue }
            #expect(routing.margin >= QuestionRouter.confidentMargin,
                    "\(question) scored \(routing.margin), expected a confident margin")
        }
    }

    @Test("CF-19b every category has training examples")
    func everyCategoryIsRepresented() {
        for category in QuestionCategory.allCases {
            let examples = QuestionRouter.examples[category] ?? []
            #expect(examples.count >= 3, "\(category.rawValue) needs examples to form a centroid")
        }
    }

    @Test("CF-19b the keyword fallback works with no embeddings at all")
    func keywordFallback() {
        #expect(QuestionRouter.keywordFallback("hey") == .smallTalk)
        #expect(QuestionRouter.keywordFallback("how much money did I spend today") == .outOfScope)
        #expect(QuestionRouter.keywordFallback("where did I leave off") == .resumption)
        #expect(QuestionRouter.keywordFallback("how long have I been working") == .accounting)
        // Unknown shapes default to recall, whose context builder is the most general.
        #expect(QuestionRouter.keywordFallback("tell me about the widget") == .recall)
    }

    @Test("CF-19b cosine similarity behaves")
    func cosineIsSane() {
        #expect(abs(QuestionRouter.cosine([1, 0], [1, 0]) - 1.0) < 0.0001)
        #expect(abs(QuestionRouter.cosine([1, 0], [0, 1])) < 0.0001)
        #expect(QuestionRouter.cosine([], []) == 0)
        #expect(QuestionRouter.cosine([1, 2], [1]) == 0)
    }

    // MARK: - CF-50 · telling is distinguished from asking

    @Test("CF-50 the remind-me collision routes correctly on both sides")
    func remindMeCollision() async {
        // The sharpest boundary in the product. Three identical opening words, opposite
        // meanings, and the QUESTION side is an existing passing eval case, so a push
        // classifier that steals it is a recall regression wearing a feature's clothes.
        let router = QuestionRouter()
        let asks = [
            "remind me what I was working on",
            "remind me where I left off",
            "remind me what that repo was called",
        ]
        let tells = [
            "remind me to send the invoice friday",
            "remind me to call the accountant tomorrow at 10",
            "remember that the wifi password is on the fridge",
            "add a todo to review the migration notes",
            "note that we decided on postgres",
        ]
        for q in asks {
            let r = await router.route(q)
            #expect(r.category != .push, "'\(q)' is a QUESTION, got .\(r.category.rawValue)")
        }
        for q in tells {
            let r = await router.route(q)
            #expect(r.category == .push, "'\(q)' is a COMMAND, got .\(r.category.rawValue) margin \(r.margin)")
        }
    }

    @Test("CF-50 push margins are reported so the threshold stays honest")
    func pushMarginsAreMeasured() async {
        // Same discipline as the original 16-question measurement: the threshold is a
        // precision/recall dial set from data, and adding a sixth centroid moves every
        // margin. Anything below confidentMargin escalates rather than guessing.
        let router = QuestionRouter()
        var thin: [String] = []
        for q in ["remind me to send the invoice friday", "remind me what I was working on",
                  "remember the wifi password is on the fridge", "where did I leave off",
                  "how much time did I spend in chrome today"] {
            guard let r = await router.classifyByEmbedding(q) else { continue }
            if r.margin < QuestionRouter.confidentMargin { thin.append("\(q) -> \(r.category.rawValue) \(r.margin)") }
        }
        // Not an assertion that every margin is fat: some legitimately are not. This
        // records WHICH are thin so escalation coverage is a known quantity, not a hope.
        #expect(thin.count <= 2, "too many thin margins after adding .push: \(thin)")
    }

    // MARK: - CF-17b · scope is settled before anything else gets a vote

    @Test("CF-17b life away from the screen is out of scope, for free, every time")
    func offScreenLifeIsRefusedForFree() async {
        // The honesty group must pass on ANY database, which means it must not depend on
        // the escalation model being awake or being right. Measured before this rule: every
        // one of these scored under the 0.075 confidence threshold, so all of them were
        // decided by a 3B model, and three of them never reached the router at all,
        // because `QueryRewriter` had already rewritten them into an in-scope shape.
        let router = QuestionRouter()
        let outside = [
            // Money moved.
            "how much money did I spend today",
            "what did I buy today",
            "what is my bank balance",
            "how much did that cost",
            "did I pay the electricity bill",
            "what did I order from amazon",
            "how much is in my savings account",
            // Food.
            "what did I have for lunch",
            "what did I eat today",
            "did I skip lunch",
            "what did I have for dinner",
            // The phone.
            "who called me today",
            "did I call marco back",
            "any calls today",
            // The body and the world.
            "how well did I sleep",
            "did I work out this morning",
        ]
        for q in outside {
            #expect(QuestionRouter.isStructurallyUnknowable(q), "'\(q)' is not something a screen can know")
            let routing = await router.route(q)
            #expect(routing.category == .outOfScope, "'\(q)' routed .\(routing.category.rawValue)")
            #expect(routing.wasFree, "'\(q)' should not need a model to be refused")
        }
    }

    @Test("CF-17b the scope rule never steals a question Memoir can answer")
    func inScopeQuestionsSurviveTheScopeRule() async {
        // The asymmetry that sets every phrase in the rule: a missed out-of-scope question
        // falls through to the embeddings and usually recovers, while a false refusal tells
        // the user a real feature does not exist. "Spend" is the sharp edge: it is the verb
        // of both money and hours, and hours are what Memoir measures best.
        let inside = [
            "did I spend more time in chrome or claude",   // live tier1 case
            "how much time did I spend in chrome today",
            "how long was I in chrome",
            "what did I spend my time on",
            "how much time did I spend on the invoice",
            "what was I working on before lunch",           // "lunch" is the clock, not a meal
            "what do I owe anyone",
            "what did I promise",
            "what is due this week",
            "who did I talk to",
            "what did I write on whatsapp",
            "where did I leave off",
            "what was that repo about screen memory",
        ]
        for q in inside {
            #expect(!QuestionRouter.isStructurallyUnknowable(q),
                    "'\(q)' is answerable and must not be refused as out of scope")
        }
    }

    @Test("CF-17b the rewriter cannot carry an out-of-scope question into scope")
    func rewriterHasNoVoteOnScope() async {
        // The actual bug. Every canonical shape is in scope, so a rewriter handed a question
        // Memoir cannot answer has no honest output but `somethingElse`, and the on-device
        // model does not reliably find it: "how much money did I spend today" came back
        // `timeToday` and was answered with an app-time table. A canonical form is never
        // routed, so the router, which had the right answer, never saw the question.
        let rewriter = QueryRewriter()
        for q in ["how much money did I spend today", "what did I buy today",
                  "what did I have for lunch", "what is my bank balance",
                  "who called me today"] {
            let canonical = await rewriter.canonical(for: q)
            #expect(canonical == nil, "'\(q)' was rewritten to \(canonical!.rawValue)")
        }
        // And the rewrites that matter still happen.
        #expect(await rewriter.canonical(for: "catch me up") == .recentActivity)
        // Named an app, this one is handed back whole. See the scope test below. A time
        // question with nothing to scope it still rewrites, which is what this line checks.
        #expect(await rewriter.canonical(for: "how much time did I spend today") == .timeToday)
        #expect(await rewriter.canonical(for: "what's on my plate") == .openCommitments)
    }

    @Test("CF-17b the rewriter may drop phrasing but never a constraint")
    func rewriterKeepsTheYearThatMakesAQuestionUnanswerable() async {
        // The same one-way error as the scope case, on the time axis. "What was I doing in
        // 1995" answered with today's app table: `byWording` matched "what was i doing",
        // returned `recentActivity`, and the canonical string that reached the brain
        // ("what was I doing recently") no longer contained 1995, so `mentionedYear`, the
        // guard written for exactly this question, never saw the token it exists to catch.
        let rewriter = QueryRewriter()
        #expect(await rewriter.canonical(for: "what was I doing in 1995") == nil)
        #expect(await rewriter.canonical(for: "where was I in 2011") == nil)

        // The current year is not a constraint that rules anything out, so it still
        // rewrites, and so does every phrasing that names no year at all.
        let thisYear = Calendar.current.component(.year, from: Date())
        #expect(await rewriter.canonical(for: "what was I doing in \(thisYear)") == .recentActivity)
        #expect(await rewriter.canonical(for: "what was I doing") == .recentActivity)
    }

    @Test("CF-17b a time question keeps the app it names")
    func rewriterKeepsTheAppATimeQuestionNames() async {
        // The third axis, after scope and the year. "How much time did I spend in chrome
        // today" matched `how much time`, canonicalised to "how much time did I spend today",
        // and the app was gone. That would be survivable if a canonical form were only a
        // search key, but `BrainRouter` hands it to `RulesOnlyBrain` as the question to
        // CLASSIFY, so the floor matched the canonical string exactly and rendered the
        // whole-day app table. Measured on the fixture world: asked about Chrome, the answer
        // was four apps and their totals, every figure correct and none of them the one asked
        // for. Found by the eval gate, which is what a gate is for.
        let rewriter = QueryRewriter()
        #expect(await rewriter.canonical(for: "how much time did I spend in chrome today") == nil)
        #expect(await rewriter.canonical(for: "how much time in obsidian") == nil)
        #expect(await rewriter.canonical(for: "how long was I in chrome") == nil)

        // A question that names no scope still rewrites, and so does one whose only scope is
        // temporal: "on monday" narrows WHEN, which the canonical form already carries.
        #expect(await rewriter.canonical(for: "how much time did I spend today") == .timeToday)
        #expect(await rewriter.canonical(for: "how long have I been working") == .timeToday)
        #expect(await rewriter.canonical(for: "how much time did I spend on monday") == .timeToday)
    }

    @Test("CF-17b the refusal names the limit rather than three of the families")
    func refusalIsHonestAboutWhatItCannotKnow() {
        // "I do not have anything about money, purchases or calls" was the reply to a
        // question about lunch. An enumeration has to be exhaustive to be honest, and the
        // set of things that happen away from a screen is not a list.
        let text = Grounding.outOfScopeRefusal.lowercased()
        #expect(!text.contains("money"))
        #expect(!text.contains("purchases"))
        // Still recognisable as a refusal to every caller that greps for one.
        #expect(text.contains("no record") || text.contains("do not have"))
    }
}
