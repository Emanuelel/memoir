//  CF-52 / CF-53: what the user TELLS Memoir is parsed, never embroidered.
//
//  Every other entity in the product is a guess that happened to be good enough. A push is
//  not: the user said it, so the parse has exactly one job, which is to not add anything.
//  A reminder that quietly acquires a due date the user never gave is worse than no
//  reminder at all, because they will trust it.
//
//  So these tests are mostly about absence: the field that stays nil, the word that is
//  still the user's own, the phrase that is a question and produces nothing.

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-52/53 · a parse never invents")
struct PushIntentTests {

    /// The parser under test, with the resolver injected exactly as production does.
    private func parse(_ phrase: String, at reference: Date = TestClock.reference) -> PushIntent? {
        PushParser.parse(phrase, reference: reference, resolver: MemoryDateResolver())
    }

    /// Friday 20 March 2026 at the 17:00 day-granularity convention, in the local frame.
    ///
    /// Built with the local calendar rather than hardcoded as UTC because the resolver
    /// resolves days in `TimeZone.current`. The reference is 10:00 UTC on Monday 16 March,
    /// which lands on Sunday 15, Monday 16 or Tuesday 17 March depending on the machine's
    /// offset, and the next Friday strictly after each of those is the same day.
    private var friday: Date { TestClock.local(2026, 3, 20, 17, 0) }

    /// Saturday 21 March 2026 at 17:00 local, by the same reasoning.
    private var saturday: Date { TestClock.local(2026, 3, 21, 17, 0) }

    /// The reference's tomorrow at a given hour, computed the way production computes it.
    private func tomorrow(at hour: Int, minute: Int = 0) -> Date {
        let cal = TestClock.localCalendar
        let day = cal.date(byAdding: .day, value: 1, to: TestClock.reference) ?? TestClock.reference
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    // MARK: - CF-52 · every lead-in form, and only the lead-in removed

    @Test("CF-52 every lead-in is recognised and nothing but the lead-in is removed")
    func leadInForms() {
        let cases: [(phrase: String, kind: EntityKind, title: String)] = [
            ("remind me to send the invoice", .commitment, "send the invoice"),
            ("remind me that the office is shut", .note, "the office is shut"),
            ("remember to water the plants", .commitment, "water the plants"),
            ("remember that the wifi password is on the fridge", .note, "the wifi password is on the fridge"),
            ("remember the wifi password is on the fridge", .note, "the wifi password is on the fridge"),
            ("note that we decided to keep postgres", .note, "we decided to keep postgres"),
            ("note: the retro moved to the big room", .note, "the retro moved to the big room"),
            ("make a note that marco prefers email", .note, "marco prefers email"),
            ("make a note: elena signs off the invoices", .note, "elena signs off the invoices"),
            ("add a todo to review the migration notes", .commitment, "review the migration notes"),
            ("add a to-do to review the migration notes", .commitment, "review the migration notes"),
            ("add a todo: chase the vat receipt", .commitment, "chase the vat receipt"),
            ("add a task to rotate the api keys", .commitment, "rotate the api keys"),
            ("todo: file the annual return", .commitment, "file the annual return"),
            ("to-do: file the annual return", .commitment, "file the annual return"),
            ("put it on my list to renew the domain", .commitment, "renew the domain"),
            ("put this on my list to renew the domain", .commitment, "renew the domain"),
            ("put that on my list to renew the domain", .commitment, "renew the domain"),
            ("put on my list to renew the domain", .commitment, "renew the domain"),
            ("i need to reply to the tax letter", .commitment, "reply to the tax letter"),
            ("i have to reply to the tax letter", .commitment, "reply to the tax letter"),
        ]
        for c in cases {
            let intent = parse(c.phrase)
            #expect(intent?.kind == c.kind, "'\(c.phrase)' should be .\(c.kind.rawValue), got \(String(describing: intent?.kind))")
            #expect(intent?.title == c.title, "'\(c.phrase)' -> '\(String(describing: intent?.title))'")
            // None of these carry a date, so none of them may acquire one.
            #expect(intent?.dueAt == nil, "'\(c.phrase)' invented a due date")
            #expect(intent?.source == c.phrase)
        }
    }

    @Test("CF-52 the lead-in is matched however it was capitalised")
    func leadInsAreCaseInsensitive() {
        #expect(parse("Remind me to send the invoice")?.title == "send the invoice")
        #expect(parse("REMEMBER THAT the shop shuts at six")?.kind == .note)
        // The title keeps the user's own casing. Tidying it would be a rewrite.
        #expect(parse("Remind me to Call Marco")?.title == "Call Marco")
    }

    @Test("CF-52 dictation whitespace is normalised, never the words")
    func whitespaceIsNormalised() {
        let intent = parse("remind me to   send\n the invoice  ")
        #expect(intent?.title == "send the invoice")
        #expect(intent?.source == "remind me to send the invoice")
    }

    // MARK: - CF-52 · no date in the phrase means no date on the parse

    @Test("CF-52 a phrase with no date produces no date")
    func noDateMeansNil() {
        // The flow's own example. There is nothing in here that resolves to a day, and the
        // parse must not reach for one.
        let intent = parse("remember the wifi password is on the fridge")
        #expect(intent?.dueAt == nil)
        #expect(intent?.kind == .note)
        #expect(intent?.title == "the wifi password is on the fridge")

        for phrase in ["remind me to call the plumber",
                       "add a todo to unsubscribe from the newsletter",
                       "note that the espresso machine needs descaling",
                       "put it on my list to back up the photos"] {
            #expect(parse(phrase)?.dueAt == nil, "'\(phrase)' invented a due date")
        }
    }

    @Test("CF-52 a weekday abbreviation that is also an English word is not a deadline")
    func ordinaryWordsAreNotDates() {
        // The resolver accepts "sun", "sat" and "wed" as weekday names, which is correct for
        // a screen full of calendar chrome and disastrous for a sentence someone spoke.
        #expect(parse("remember that the sun deck is closed")?.dueAt == nil)
        #expect(parse("note that i sat in on the platform review")?.dueAt == nil)
        // Spelled out, it is a date again.
        #expect(parse("remind me to call marco wednesday")?.dueAt != nil)
    }

    @Test("CF-52 the title is a slice of the user's own words")
    func titleIsNeverReworded() {
        // With no date to cut, the title is literally a substring of the phrase.
        for phrase in ["remind me to send the invoice to elena",
                       "remember that marco prefers email",
                       "add a todo to review the migration notes"] {
            let title = try? #require(parse(phrase)?.title)
            #expect(title.map { phrase.contains($0) } == true, "'\(phrase)' -> '\(String(describing: title))' is not a slice of it")
        }

        // With a date cut out of the middle the title is no longer contiguous, but every
        // word is still the user's, in the order they said them.
        let intent = parse("remind me to call marco tomorrow about the invoice")
        #expect(intent?.title == "call marco about the invoice")
        #expect(wordsAppearInOrder(intent?.title ?? "", within: "remind me to call marco tomorrow about the invoice"))
    }

    // MARK: - CF-53 · dates resolve against the injected reference

    @Test("CF-53 a day-granularity date resolves to the 17:00 convention and leaves the title")
    func dayGranularityDate() {
        let intent = parse("remind me to send the invoice friday")
        #expect(intent?.kind == .commitment)
        #expect(intent?.title == "send the invoice")
        #expect(intent?.dueAt == friday, "got \(String(describing: intent?.dueAt.map(TestClock.iso)))")
        // Nothing is lost: the phrase is kept whole for display and provenance.
        #expect(intent?.source == "remind me to send the invoice friday")
    }

    @Test("CF-53 an explicit time overrides the convention, and goes with the date")
    func explicitTimeIsTakenAndRemoved() {
        // The flow's own example. "at 10" is folded into the due date by the resolver, so
        // leaving it in the title would state the same time twice with the day missing.
        let intent = parse("remind me to call the accountant tomorrow at 10")
        #expect(intent?.title == "call the accountant")
        #expect(intent?.dueAt == tomorrow(at: 10), "got \(String(describing: intent?.dueAt.map(TestClock.iso)))")

        #expect(parse("remind me to join the standup tomorrow at 9:30")?.dueAt == tomorrow(at: 9, minute: 30))
        #expect(parse("remind me to join the standup tomorrow at 9:30")?.title == "join the standup")
    }

    @Test("CF-53 a number that merely follows a date stays in the title")
    func trailingNumbersAreNotTimes() {
        // "friday 3" is not 03:00. The resolver refuses it, so the parser must not cut it.
        let intent = parse("remind me to send friday 3 invoices")
        #expect(intent?.dueAt == friday)
        #expect(intent?.title == "send 3 invoices")
    }

    @Test("CF-53 the preposition that introduced the date does not survive it")
    func danglingPrepositionsAreTrimmed() {
        #expect(parse("remind me to send the invoice by tomorrow")?.title == "send the invoice")
        #expect(parse("remind me to send the invoice by friday")?.title == "send the invoice")
        #expect(parse("i need to reply to the tax letter by monday")?.title == "reply to the tax letter")

        // A verb particle is not a preposition, and the parser leaves it alone: "on" is
        // never trimmed, so the task keeps its meaning.
        #expect(parse("remind me to turn the heating on tomorrow")?.title == "turn the heating on")

        // The exception, recorded rather than fixed. `MemoryDateResolver` reports "on friday"
        // as ONE expression, so the particle is inside the span the parser removes and
        // "turn the heating on friday" becomes "turn the heating". Putting it back would
        // mean knowing that "turn on" is a phrasal verb while "send on" is not, which is a
        // guess, and CF-52 spends its budget on not guessing. A lost particle leaves every
        // remaining word the user's own; a restored one does not.
        #expect(parse("remind me to turn the heating on friday")?.title == "turn the heating")
    }

    @Test("CF-53 the same phrase on a different day resolves to a different date")
    func referenceIsInjectedNotRead() {
        // The whole of CF-53 in one assertion: nothing in the parser knows what day it is
        // except what it was handed.
        let phrase = "remind me to send the invoice friday"
        let thisWeek = parse(phrase, at: TestClock.reference)?.dueAt
        let nextWeek = parse(phrase, at: TestClock.days(7))?.dueAt
        #expect(thisWeek == friday)
        #expect(nextWeek != nil)
        #expect(nextWeek != thisWeek, "the reference moved a week and the due date did not")
        if let a = thisWeek, let b = nextWeek {
            #expect(TestClock.localCalendar.dateComponents([.day], from: a, to: b).day == 7)
        }
    }

    @Test("CF-53 a fact keeps its date words, because the date is the fact")
    func notesKeepTheirDates() {
        // Cutting "on saturday" out of this leaves "the party is", which is exactly the
        // garbled entity CF-57 forbids. The due date is resolved all the same.
        let intent = parse("remember that the party is on saturday")
        #expect(intent?.kind == .note)
        #expect(intent?.title == "the party is on saturday")
        #expect(intent?.dueAt == saturday, "got \(String(describing: intent?.dueAt.map(TestClock.iso)))")
    }

    @Test("CF-53 a date that would empty the title stays in the title")
    func dateSurvivesWhenNothingElseWould() {
        // Dictation trails off mid-sentence more often than anyone would like. Cutting the
        // date here would leave an empty commitment, so the words stand and the date is
        // resolved alongside them: nothing invented, nothing dropped.
        let intent = parse("remind me to friday")
        #expect(intent?.kind == .commitment)
        #expect(intent?.title == "friday")
        #expect(intent?.dueAt == friday)
    }

    // MARK: - CF-52 · a question is never a push

    @Test("CF-52 a question is not a push, however it opens")
    func questionsReturnNil() {
        // The CF-50 collision seen from the parser's side. The first three words of the
        // first two are identical, and the fourth decides.
        for phrase in ["remind me what I was working on",
                       "remind me where I left off",
                       "remind me what that repo was called",
                       "remember what I was doing before lunch",
                       "remember where I put the keys",
                       "remember when the review is",
                       "note what did I look at yesterday",
                       "what do I owe anyone",
                       "where did I leave off",
                       "how much time did I spend in chrome"] {
            #expect(parse(phrase) == nil, "'\(phrase)' is a question and parsed as a push")
        }
    }

    @Test("CF-52 a question mark settles it before any pattern gets a vote")
    func questionMarkWins() {
        #expect(parse("remind me to send the invoice friday?") == nil)
        #expect(parse("remember that the wifi password is on the fridge?") == nil)
    }

    @Test("CF-52 an imperative that opens with a question word is still a push")
    func imperativesSurviveTheQuestionGuard() {
        // "do", "have" and "will" are interrogatives in subject position and ordinary verbs
        // after an infinitive. Rejecting these would cost real reminders.
        #expect(parse("remind me to do the taxes")?.title == "do the taxes")
        #expect(parse("add a todo to have the car serviced")?.title == "have the car serviced")
        #expect(parse("remind me to can the tomatoes")?.title == "can the tomatoes")
    }

    // MARK: - CF-52 · empty and garbage input

    @Test("CF-52 empty and garbage input parse to nothing")
    func garbageReturnsNil() {
        for phrase in ["", "   ", "\n\t ", "...", "asdf jkl", "hey how's it going",
                       "remember", "remind me to", "remind me to ", "note that",
                       "todo:", "the invoice is late"] {
            #expect(parse(phrase) == nil, "'\(phrase)' should not parse as a push")
        }
    }

    @Test("CF-52 a lead-in followed by nothing usable parses to nothing")
    func emptyBodyReturnsNil() {
        #expect(parse("remind me to .") == nil)
        #expect(parse("remember that !!") == nil)
        #expect(parse("add a todo to 7") == nil)
    }

    @Test("CF-52 a phrase with no recognised lead-in is not guessed at")
    func unrecognisedPhrasesAreNotGuessed() {
        // Returning nil here is the supported outcome, not a shortfall: CF-57 allows Memoir to
        // say plainly that it did not understand, and a confident parse of something the
        // user did not frame as a push is the worse of the two failures.
        #expect(parse("send the invoice friday") == nil)
        #expect(parse("the standup moved to thursday") == nil)
    }

    // MARK: - CF-57 · the no-model path

    @Test("CF-57 the parse needs no brain, no store and no network")
    func parsingIsPure() {
        BlockingURLProtocol.install()
        let phrases = ["remind me to send the invoice friday",
                       "remember that the wifi password is on the fridge",
                       "add a todo to review the migration notes",
                       "remind me what I was working on"]

        // Deterministic: the same inputs produce byte-identical intents every time, which is
        // what lets a push be re-parsed for display without drifting.
        let first = phrases.map { parse($0) }
        let second = phrases.map { parse($0) }
        #expect(first == second)

        #expect(first[0]?.dueAt == friday)
        #expect(first[3] == nil)
        assertNoNetwork()
    }

    @Test("CF-52 a long phrase keeps every word in its source")
    func longPhrasesKeepTheirSource() {
        let body = String(repeating: "review the migration notes and ", count: 20) + "then ship it"
        let phrase = "remind me to " + body
        let intent = parse(phrase)
        #expect(intent?.source == phrase, "the full phrase must survive for provenance")
        #expect((intent?.title.count ?? 0) <= PushParser.maxTitle + 1)
    }

    // MARK: - Helpers

    /// True when every word of `title` appears in `phrase`, in the same order.
    ///
    /// Weaker than a substring check and deliberately so: cutting a date out of the middle
    /// makes the title non-contiguous, but it must still be the user's words in their order.
    private func wordsAppearInOrder(_ title: String, within phrase: String) -> Bool {
        var remaining = phrase.split(separator: " ").map(String.init)[...]
        for word in title.split(separator: " ").map(String.init) {
            guard let i = remaining.firstIndex(of: word) else { return false }
            remaining = remaining[(i + 1)...]
        }
        return true
    }
}
