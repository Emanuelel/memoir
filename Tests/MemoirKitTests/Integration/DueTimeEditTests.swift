//  CF-52 / CF-53: editing the due time invents nothing either.
//
//  17:00 is Memoir's convention for a phrase that names a day and no hour. It is a reasonable
//  default and a bad final answer: a reminder at the wrong hour is a reminder you miss. So the
//  panel lets the hour be corrected in place, and the correction is held to exactly the same
//  promises the parse is held to: the day the user said survives, an empty field means no due
//  date rather than midnight, and text that is not a time is refused out loud instead of
//  quietly leaving the old value in a panel the user believes they changed.
//
//  The panel itself cannot be honestly tested. Every decision it makes can, and all of them
//  live in `DueTime` and `DueEdit`, which is what this file is pointed at.

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-52/53 · editing the due time")
struct DueTimeEditTests {

    /// The frame production reads days in. Injected everywhere below so no assertion here
    /// depends on which machine is running it.
    private let cal = TestClock.localCalendar

    /// Friday 20 March 2026 at Memoir's 17:00 convention, the value a bare "friday" produces,
    /// and the one this whole feature exists to let the user overrule.
    private var friday: Date { TestClock.local(2026, 3, 20, 17, 0) }

    /// A proposal shaped like the one on screen after "remind me to send the invoice friday".
    private func proposal(due: Date? = nil, convention: Bool = false) -> PushIntent {
        PushIntent(
            kind: .commitment,
            title: "send the invoice",
            dueAt: due,
            dueTimeIsConvention: convention,
            source: "remind me to send the invoice friday"
        )
    }

    // MARK: - The parser, as a pure function

    @Test("a typed time is read the way a person meant it")
    func readsWhatPeopleType() {
        let cases: [(String, Int, Int)] = [
            ("9", 9, 0),
            ("09", 9, 0),
            ("0", 0, 0),
            ("21", 21, 0),
            ("23", 23, 0),
            ("9am", 9, 0),
            ("9 am", 9, 0),
            ("9AM", 9, 0),
            ("9pm", 21, 0),
            ("12am", 0, 0),
            ("12pm", 12, 0),
            ("9:30", 9, 30),
            ("09:05", 9, 5),
            ("9.30", 9, 30),
            ("21:30", 21, 30),
            ("9:30pm", 21, 30),
            ("12:30am", 0, 30),
            ("930", 9, 30),
            ("0930", 9, 30),
            ("2130", 21, 30),
            ("half past 2", 2, 30),
            ("half past two", 2, 30),
            ("half past 2 pm", 14, 30),
            ("quarter past 9", 9, 15),
            ("quarter to 6", 5, 45),
            ("quarter to six", 5, 45),
            ("noon", 12, 0),
            ("midday", 12, 0),
            ("midnight", 0, 0),
            ("morning", 9, 0),
            ("in the morning", 9, 0),
            ("afternoon", 14, 0),
            ("lunchtime", 13, 0),
            ("tonight", 20, 0),
            ("evening", 20, 0),
            ("eod", 18, 0),
            ("end of the day", 18, 0),
            // Whitespace and stray punctuation are how the text actually arrives from
            // dictation and from someone typing fast.
            ("  9:30  ", 9, 30),
            ("9pm.", 21, 0),
            ("NOON", 12, 0),
        ]
        for (typed, hour, minute) in cases {
            #expect(
                DueTime.read(typed) == .time(ClockTime(hour: hour, minute: minute)!),
                "'\(typed)' should read as \(hour):\(minute), got \(DueTime.read(typed))"
            )
        }
    }

    @Test("a bare number is the 24 hour reading, never an assumed afternoon")
    func bareNumbersAre24Hour() {
        // Reading "3" as 15:00 would be Memoir picking an hour the user did not type, which is
        // the exact bug this field exists to fix. The value lands on screen immediately, so a
        // wrong reading costs one correction rather than a missed reminder.
        #expect(DueTime.read("3") == .time(ClockTime(hour: 3, minute: 0)!))
        #expect(DueTime.read("3pm") == .time(ClockTime(hour: 15, minute: 0)!))
    }

    @Test("an empty field is a decision, not an absence")
    func blankIsBlank() {
        for typed in ["", " ", "   ", "\n", "\t "] {
            #expect(DueTime.read(typed) == .blank, "'\(typed)' should be blank")
        }
    }

    @Test("text that is not a time is refused rather than rounded into one")
    func refusesNonTimes() {
        let cases = [
            "banana", "soon", "later", "asap", "next week", "friday",
            "24", "25", "99", "-3", "9:70", "24:00", "2400", "2560",
            "13pm", "0pm", "13am", "9 30", "9:5", "half past", "half 2",
            "quarter to 12am", "quarter past thirteen", "::", "9:", ":30",
            "9am 9pm", String(repeating: "9", count: 40),
        ]
        for typed in cases {
            #expect(DueTime.read(typed) == .unreadable, "'\(typed)' should be unreadable")
        }
    }

    @Test("the field's own contents read back as the same time")
    func editableTextRoundTrips() {
        // A field that would reject the value it was seeded with is a trap: the user tabs in,
        // presses Return, and is told their own unchanged time is not a time.
        for hour in 0...23 {
            for minute in [0, 1, 5, 30, 59] {
                let day = cal.date(bySettingHour: hour, minute: minute, second: 0, of: friday)!
                let text = DueEdit.editableText(for: proposal(due: day), timeZone: cal.timeZone)
                #expect(
                    DueTime.read(text) == .time(ClockTime(hour: hour, minute: minute)!),
                    "'\(text)' did not read back as \(hour):\(minute)"
                )
            }
        }
    }

    // MARK: - CF-52 · the day is never touched

    @Test("CF-52 changing the time never changes the day")
    func editingTheTimeKeepsTheDay() {
        for hour in 0...23 {
            for minute in [0, 15, 30, 45, 59] {
                let typed = String(format: "%02d:%02d", hour, minute)
                guard case .applied(let out) = DueEdit.apply(
                    typed, to: proposal(due: friday, convention: true), day: friday, calendar: cal)
                else {
                    Issue.record("'\(typed)' was refused on an ordinary day")
                    continue
                }
                guard let due = out.dueAt else {
                    Issue.record("'\(typed)' cleared the date instead of setting it")
                    continue
                }
                #expect(cal.isDate(due, inSameDayAs: friday), "'\(typed)' moved off Friday")
                #expect(cal.component(.hour, from: due) == hour)
                #expect(cal.component(.minute, from: due) == minute)
            }
        }
    }

    @Test("CF-52 nothing but the due date moves")
    func editingTouchesNothingElse() {
        let before = proposal(due: friday, convention: true)
        guard case .applied(let after) = DueEdit.apply("9", to: before, day: friday, calendar: cal) else {
            Issue.record("a plain '9' was refused")
            return
        }
        #expect(after.kind == before.kind)
        #expect(after.title == before.title)
        #expect(after.source == before.source)
        #expect(after.dueAt == TestClock.local(2026, 3, 20, 9, 0))
    }

    @Test("CF-52 clearing the field means no due date, not midnight")
    func clearingRemovesTheDate() {
        guard case .applied(let out) = DueEdit.apply(
            "  ", to: proposal(due: friday, convention: true), day: friday, calendar: cal)
        else {
            Issue.record("an empty field was refused")
            return
        }
        // Midnight is what a date built out of an empty time would be, and a reminder at
        // 00:00 is one that fires while you sleep off the back of a field somebody cleared.
        #expect(out.dueAt == nil)
        #expect(out.dueTimeIsConvention == false)
    }

    @Test("CF-52 a cleared date can be given a time again without inventing a day")
    func clearingIsUndoable() {
        var intent = proposal(due: friday, convention: true)
        guard case .applied(let cleared) = DueEdit.apply("", to: intent, day: friday, calendar: cal) else {
            Issue.record("clearing was refused")
            return
        }
        intent = cleared
        #expect(intent.dueAt == nil)

        // The anchor is the day the user's own words produced. Re-attaching a time to it is
        // undo, not invention: no day is being guessed, only the one already said.
        guard case .applied(let restored) = DueEdit.apply("9am", to: intent, day: friday, calendar: cal) else {
            Issue.record("restoring a time to the parsed day was refused")
            return
        }
        #expect(restored.dueAt == TestClock.local(2026, 3, 20, 9, 0))
    }

    @Test("CF-52 a time with no day is refused, never given today")
    func aTimeWithNoDayIsRefused() {
        let intent = proposal(due: nil)
        let result = DueEdit.apply("9am", to: intent, day: nil, calendar: cal)
        #expect(result == .rejected(DueEdit.noDay))
        // The proposal must be exactly as it was: an invented day is the worst outcome here,
        // and a silently unchanged one is the second worst.
        if case .applied = result { Issue.record("a day was invented for a phrase that gave none") }
    }

    // MARK: - Refusals leave the previous value standing

    @Test("a refused edit says so and changes nothing")
    func refusedEditsChangeNothing() {
        let before = proposal(due: friday, convention: true)
        for typed in ["banana", "25", "9:70", "soon"] {
            let result = DueEdit.apply(typed, to: before, day: friday, calendar: cal)
            guard case .rejected(let why) = result else {
                Issue.record("'\(typed)' was accepted")
                continue
            }
            #expect(why.contains("as a time"), "the refusal should say what it wanted: \(why)")
            #expect(why.contains(typed), "the refusal should quote what was typed: \(why)")
        }
        // The value the user can still see is the value that would be saved.
        #expect(before.dueAt == friday)
    }

    @Test("a very long paste is refused without being quoted back in full")
    func longPasteIsRefusedTidily() {
        let paste = String(repeating: "wednesday afternoon ", count: 20)
        guard case .rejected(let why) = DueEdit.apply(
            paste, to: proposal(due: friday), day: friday, calendar: cal)
        else {
            Issue.record("a paste was accepted as a time")
            return
        }
        #expect(why.count < 120, "the refusal grew with the input: \(why.count) characters")
    }

    @Test("an hour that does not exist that day is refused, not nudged")
    func springForwardIsRefused() {
        // Rome moves 02:00 to 03:00 on 29 March 2026, so 02:30 does not happen. `bySettingHour`
        // would hand back 03:00 without saying a word, and a reminder half an hour later than
        // the one you set is the same silent wrongness as a default you could not see.
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = TimeZone(identifier: "Europe/Rome")!
        rome.locale = Locale(identifier: "en_US_POSIX")
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 29; comps.hour = 12
        let gapDay = rome.date(from: comps)!

        #expect(DueEdit.apply("2:30", to: proposal(due: gapDay), day: gapDay, calendar: rome)
                == .rejected(DueEdit.impossibleHour))
        // The hours either side of the gap are ordinary and must still work.
        if case .applied(let out) = DueEdit.apply("1:30", to: proposal(due: gapDay), day: gapDay, calendar: rome) {
            #expect(rome.component(.hour, from: out.dueAt!) == 1)
        } else {
            Issue.record("01:30 was refused on the clock change day")
        }
    }

    // MARK: - Saying whose hour it is

    @Test("CF-53 a day with no time said is labelled as Memoir's default")
    func conventionIsLabelled() {
        let intent = PushParser.parse(
            "remind me to send the invoice friday",
            reference: TestClock.reference,
            resolver: MemoryDateResolver()
        )
        #expect(intent?.dueAt == friday)
        #expect(intent?.dueTimeIsConvention == true)
        #expect(DueEdit.note(for: intent!) == DueEdit.conventionNote)
    }

    @Test("CF-53 an hour the user said is never called Memoir's default")
    func statedHoursAreNotLabelled() {
        let cases = [
            "remind me to call the accountant tomorrow at 10",
            "remind me to call marco friday at 5pm",
            "remind me to call marco friday at 17:00",
            "remind me to send it tomorrow at 20:00",
        ]
        for phrase in cases {
            let intent = PushParser.parse(phrase, reference: TestClock.reference, resolver: MemoryDateResolver())
            #expect(intent?.dueAt != nil, "'\(phrase)' lost its date")
            #expect(intent?.dueTimeIsConvention == false, "'\(phrase)' was called Memoir's default")
            #expect(DueEdit.note(for: intent!) == nil)
        }
    }

    @Test("CF-52 a proposal with no date is not labelled at all")
    func noDateIsNotLabelled() {
        let intent = PushParser.parse(
            "remind me to renew the domain",
            reference: TestClock.reference,
            resolver: MemoryDateResolver()
        )
        #expect(intent?.dueAt == nil)
        #expect(intent?.dueTimeIsConvention == false)
        #expect(DueEdit.note(for: intent!) == nil)
    }

    @Test("the label comes off as soon as the user sets the hour themselves")
    func editingDropsTheLabel() {
        let before = proposal(due: friday, convention: true)
        #expect(DueEdit.note(for: before) == DueEdit.conventionNote)

        guard case .applied(let after) = DueEdit.apply("9am", to: before, day: friday, calendar: cal) else {
            Issue.record("'9am' was refused")
            return
        }
        #expect(after.dueTimeIsConvention == false)
        #expect(DueEdit.note(for: after) == nil)
    }

    @Test("the label comes off while the hour is being typed, not after it lands")
    func typingDropsTheLabel() {
        let intent = proposal(due: friday, convention: true)
        let seeded = DueEdit.editableText(for: intent, timeZone: cal.timeZone)
        // The field's own text has to read back as a time, or tabbing in and pressing Return
        // would refuse the user's unchanged value.
        #expect(DueTime.read(seeded) == .time(ClockTime(hour: 17, minute: 0)!))

        // Untouched: still Memoir's hour, still says so.
        #expect(DueEdit.note(for: intent, draft: seeded, timeZone: cal.timeZone) == DueEdit.conventionNote)
        // The moment the field stops matching, the hour being previewed is the user's, and
        // calling it Memoir's would be the same lie pointing the other way.
        #expect(DueEdit.note(for: intent, draft: "9", timeZone: cal.timeZone) == nil)
        #expect(DueEdit.note(for: intent, draft: "", timeZone: cal.timeZone) == nil)
    }

    @Test("editing back to the very hour Memoir chose is still the user's choice")
    func reTypingTheDefaultIsNotTheDefault() {
        // The value is identical, the provenance is not. Recomputing the label from the hour
        // alone would put "Memoir's default" back on a time the user deliberately confirmed.
        let before = proposal(due: friday, convention: true)
        guard case .applied(let after) = DueEdit.apply("17:00", to: before, day: friday, calendar: cal) else {
            Issue.record("'17:00' was refused")
            return
        }
        #expect(after.dueAt == friday)
        #expect(DueEdit.note(for: after) == nil)
    }

    // MARK: - What the panel shows

    @Test("a missing date is stated in words, never left blank")
    func missingDatesSaySo() {
        #expect(DueEdit.absoluteText(nil) == DueEdit.noDateText)
        #expect(DueEdit.editableText(for: proposal(due: nil)) == "")
    }

    @Test("the live preview is silent until the text is a time, and never lies about the day")
    func previewFollowsTheTyping() {
        let posix = Locale(identifier: "en_US_POSIX")
        func preview(_ typed: String) -> String? {
            DueEdit.preview(typed, day: friday, calendar: cal, locale: posix, timeZone: cal.timeZone)
        }
        // Half-typed input is not a mistake, so it draws no complaint and no preview.
        #expect(preview("9:") == nil)
        #expect(preview("banana") == nil)
        // Clearing has a preview too: the user should see what an empty field will mean.
        #expect(preview("") == DueEdit.noDateText)
        // The day in the preview is the day in the proposal, whatever the hour becomes.
        #expect(preview("9am") == "Fri 20 Mar, 09:00")
        #expect(preview("23:59") == "Fri 20 Mar, 23:59")
        // With no day there is nothing honest to preview.
        #expect(DueEdit.preview("9am", day: nil, calendar: cal, locale: posix, timeZone: cal.timeZone) == nil)
    }

    @Test("the preview and the saved value are the same instant")
    func previewMatchesWhatIsSaved() {
        let posix = Locale(identifier: "en_US_POSIX")
        for typed in ["9", "9am", "half past 2", "noon", "tonight", "21:30"] {
            guard case .applied(let out) = DueEdit.apply(
                typed, to: proposal(due: friday), day: friday, calendar: cal)
            else {
                Issue.record("'\(typed)' was refused")
                continue
            }
            let shown = DueEdit.preview(typed, day: friday, calendar: cal, locale: posix, timeZone: cal.timeZone)
            #expect(shown == DueEdit.absoluteText(out.dueAt, locale: posix, timeZone: cal.timeZone),
                    "'\(typed)' previews something other than what it saves")
        }
    }

    @Test("the words the field accepts mean the same as the words the parser accepts")
    func fieldAndSentenceAgree() {
        // "tonight" typed into the field and "tonight" said in the sentence have to be the
        // same hour, or the panel would contradict the parse over one word.
        #expect(DueTime.read("tonight") == .time(ClockTime(hour: MemoryDateResolver.eveningHour, minute: 0)!))
        #expect(DueTime.read("eod") == .time(ClockTime(hour: MemoryDateResolver.endOfDayHour, minute: 0)!))

        let spoken = PushParser.parse(
            "remind me to call marco tonight", reference: TestClock.reference, resolver: MemoryDateResolver())
        guard let spoken, let due = spoken.dueAt else {
            Issue.record("'tonight' lost its date")
            return
        }
        #expect(cal.component(.hour, from: due) == MemoryDateResolver.eveningHour)
    }
}
