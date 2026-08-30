//  CF-17b: a challenge is not a correction.
//
//  Observed live, three consecutive turns:
//
//      Memoir:  "You spent 1 minute and 43 seconds on Claude."   ← wrong, it was 2h 10m
//      User: "mmm I do not think I have only spent 1 minute on claude"
//      Memoir:  "You spent 1 minute on Claude."                  ← agreed, changed nothing
//
//  The second answer is the failure these tests exist for. Agreeing with a challenge without
//  going back to the data converts a wrong answer into a CONFIRMED wrong answer, and it
//  teaches the user that pushing back does nothing, after which they stop pushing back, and
//  every remaining error goes unreported.
//
//  Two halves, both pinned here: recognising that the user disputed something, and
//  recognising that the reply caved instead of re-deriving.

import Foundation
import Testing

@testable import MemoirKit

@Suite("CF-17b · a challenge is not a correction")
struct ChallengeTests {

    /// The turn Memoir actually produced, and the one it should have.
    private static let wrongAnswer = "You spent 1 minute and 43 seconds on Claude."
    private static let challenge = "mmm I do not think I have only spent 1 minute on claude"
    private static let capitulation = "You spent 1 minute on Claude."

    @Test("CF-17b the live transcript: agreeing with a challenge is caught")
    func theRealTranscript() {
        #expect(Grounding.isChallenge(Self.challenge))
        #expect(Grounding.capitulates(
            answer: Self.capitulation,
            toChallenge: Self.challenge,
            previousAnswer: Self.wrongAnswer))
    }

    // MARK: - Recognising a challenge

    @Test("CF-17b genuine challenges are recognised")
    func challengesAreDetected() {
        let disputes = [
            "mmm I do not think I have only spent 1 minute on claude",
            "I don't think that's right",
            "that's wrong",
            "you are wrong",
            "are you sure?",
            "are you sure about that",
            "that can't be right",
            "no it wasn't",
            "no I didn't",
            "really?",
            "mmm",
            "hmm",
            "that seems low",
            "that seems really low",
            "that seems way too high",
            "that sounds low to me",
            "it was more like two hours",
            "that doesn't add up",
            "can you check again",
            "where did you get that number",
            "no way",
        ]
        for message in disputes {
            #expect(Grounding.isChallenge(message), "'\(message)' is a challenge")
        }
    }

    @Test("CF-17b a challenge typed fast is still a challenge")
    func typosAreTolerated() {
        // The message that started this was lowercase, unpunctuated and typed in irritation.
        // A detector that needs correct spelling misses exactly the turns that matter most.
        let typed = [
            "i dont thnk that is right",
            "thats worng",
            "that cant be rigth",
            "are you shure",
            "that seemms low",
            "no it wasnt",
        ]
        for message in typed {
            #expect(Grounding.isChallenge(message), "'\(message)' is a challenge with a typo")
        }
    }

    @Test("CF-17b ordinary follow-ups are not challenges")
    func followUpsAreNotChallenges() {
        // The cost of a false positive is Memoir getting defensive about an answer nobody
        // questioned. These are the most common things a user says after a GOOD answer.
        let followUps = [
            "and before that?",
            "what about chrome",
            "what about chrome?",
            "and what was I doing before that",
            "how about yesterday",
            "ok and then what",
            "tell me more about that",
            "what else did I have open",
            "how long was I in obsidian",
            "hmm what did I have open on chrome",
            "summarise my day",
            "what do I owe anyone",
        ]
        for message in followUps {
            #expect(Grounding.isChallenge(message) == false,
                    "'\(message)' is an ordinary follow-up, not a challenge")
        }
    }

    @Test("CF-17b an empty message is not a challenge")
    func emptyIsNotAChallenge() {
        #expect(Grounding.isChallenge("") == false)
        #expect(Grounding.isChallenge("   ") == false)
    }

    // MARK: - Recognising a capitulation

    @Test("CF-17b restating the disputed figure with nothing new is capitulation")
    func restatingIsCapitulation() {
        for reply in [
            "You spent 1 minute on Claude.",
            "You spent only 1 minute on Claude.",
            "You are right, you spent 1 minute on Claude.",
            "Sorry about that. You spent 1 minute on Claude.",
        ] {
            #expect(Grounding.capitulates(
                answer: reply,
                toChallenge: Self.challenge,
                previousAnswer: Self.wrongAnswer),
                "'\(reply)' repeats the disputed figure and adds nothing")
        }
    }

    @Test("CF-17b a re-derivation that lands somewhere else is not capitulation")
    func differentFigureIsNotCapitulation() {
        // The correct behaviour, and the point of being challenged at all: go back to the
        // session rows. Whether the new figure is right is the duration guard's job, not
        // this one's. What matters here is that it MOVED.
        let rederived = "I went back to the session records: it was 2 hours and 10 minutes on Claude."
        #expect(Grounding.capitulates(
            answer: rederived,
            toChallenge: Self.challenge,
            previousAnswer: Self.wrongAnswer) == false)
    }

    @Test("CF-17b digits alone do not make two durations the same claim")
    func durationsCompareAsWholeClaims() {
        // "43 minutes" reuses the digits of "1 minute and 43 seconds" and agrees with it
        // about nothing. Comparing loose numbers would call this a restatement.
        #expect(Grounding.capitulates(
            answer: "It was 43 minutes on Claude.",
            toChallenge: Self.challenge,
            previousAnswer: Self.wrongAnswer) == false)
    }

    @Test("CF-17b standing by a figure with fresh evidence is not capitulation")
    func honestReCheckIsAllowed() {
        // The honest outcome of a challenge where Memoir was right the first time. It repeats
        // the number, which is the whole point, but it says where the number came from.
        let previous = "You spent 2 hours and 10 minutes on Claude."
        let pushBack = "mmm that seems high"
        let checked = "I checked the session records again and it is still 2 hours and 10 minutes on Claude."
        #expect(Grounding.isChallenge(pushBack))
        #expect(Grounding.capitulates(
            answer: checked, toChallenge: pushBack, previousAnswer: previous) == false)
    }

    @Test("CF-17b a reply carrying no figure at all is not judged here")
    func noFigureIsNotCapitulation() {
        // Refusing is a different failure with a different guard. This one only rules on
        // figures, and claiming otherwise would make it fire on every honest "I don't know".
        #expect(Grounding.capitulates(
            answer: Grounding.refusal,
            toChallenge: Self.challenge,
            previousAnswer: Self.wrongAnswer) == false)
    }

    @Test("CF-17b repeating a figure for someone who asked again is not capitulation")
    func onlyChallengesCanBeCapitulatedTo() {
        // "what about chrome" is not a dispute, so restating a number in reply to it is an
        // answer, not a collapse. Capitulation exists only in reply to a challenge.
        #expect(Grounding.capitulates(
            answer: Self.capitulation,
            toChallenge: "what about chrome",
            previousAnswer: Self.wrongAnswer) == false)
    }

    // MARK: - Asserting confidence is not answering

    @Test("CF-17b \"Yes, I am sure\" is not an answer to \"are you sure?\"")
    func bareConfidenceIsCaught() {
        // The real exchange, from the user's own log:
        //   Memoir:  "You spent 2 minutes on Claude today."
        //   User: "are you sure ?"
        //   Memoir:  "Yes, I am sure."
        // capitulates() compares figures and there is no figure here, so it saw nothing. The
        // user asked Memoir to CHECK and Memoir asserted instead, which spends the trust that a
        // re-derivation would have earned.
        #expect(Grounding.isChallenge("are you sure ?"))
        #expect(Grounding.assertsWithoutEvidence("Yes, I am sure."))
        #expect(Grounding.assertsWithoutEvidence("Yes."))
        #expect(Grounding.assertsWithoutEvidence("That is correct"))
        #expect(Grounding.assertsWithoutEvidence("Confirmed."))
        #expect(Grounding.assertsWithoutEvidence("Yes, I am sure about that."))
    }

    @Test("CF-17b a real re-derivation is not mistaken for bluffing")
    func evidenceSurvives() {
        // A challenge has two honest answers: the figure again with where it came from, or
        // "I was wrong". Both carry content, and neither may be caught.
        #expect(Grounding.assertsWithoutEvidence("Yes: 5.7 minutes across 5 sessions today.") == false)
        #expect(Grounding.assertsWithoutEvidence("I checked again, it is 2h 10m.") == false)
        #expect(Grounding.assertsWithoutEvidence("No, I was wrong. It was 5 minutes.") == false)
        #expect(Grounding.assertsWithoutEvidence("You were in Claude from 09:12 to 09:18.") == false)
        // An ordinary answer that merely happens to be short must survive too.
        #expect(Grounding.assertsWithoutEvidence("You looked at screenpipe/screenpipe.") == false)
    }

    @Test("CF-19b the shortest way to ask for your list is not resumption")
    func shortTodoQuestionsRoute() {
        // Observed live: "any to do ?" was answered "You were on Google Chrome at 14:05."
        for q in ["any to do ?", "any todos", "anything to do?", "what's on my list", "todo list"] {
            #expect(QuestionRouter.asksAboutCommitments(q), "'\(q)' asks for the list")
        }
        // And the things that must NOT be dragged in with them.
        for q in ["what was I doing", "where did I leave off", "how much time in chrome"] {
            #expect(QuestionRouter.asksAboutCommitments(q) == false, "'\(q)' is not a list question")
        }
    }

    @Test("CF-17b a complaint is repaired, never searched")
    func complaintIsNotAQuery() {
        // The real exchange: "so what ? this is not what I have asked" was routed to recall,
        // its own words were used as the search query, and the model reported a URL the user
        // had never mentioned. Telling someone who just said "that is not what I asked" about
        // https://t.co/ybIpXhYSsj proves Memoir was not listening, twice.
        for m in ["so what ? this is not what I have asked",
                  "that's not what I meant",
                  "this doesn't answer my question",
                  "that makes no sense"] {
            #expect(Grounding.isComplaint(m), "'\(m)' is a complaint")
        }
        // Real questions must never be caught, or a complaint guard becomes a question eater.
        for q in ["what was that repo about screen memory", "where did I leave off",
                  "how much time in chrome today", "what do I owe anyone",
                  "remind me to send the invoice friday"] {
            #expect(Grounding.isComplaint(q) == false, "'\(q)' is a question")
        }
    }

    @Test("CF-17b a complaint and a challenge are repaired differently")
    func complaintIsNotAChallenge() {
        // A challenge disputes the ANSWER and is repaired by checking again. A complaint says
        // the whole question was misunderstood, and the only honest repair is to admit it and
        // ask, because guessing a third time after two misses is worse than saying so.
        #expect(Grounding.isChallenge("are you sure ?"))
        #expect(Grounding.isComplaint("are you sure ?") == false)
        #expect(Grounding.isComplaint("this is not what I have asked"))
    }
}
