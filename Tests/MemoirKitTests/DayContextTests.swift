import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

/// Tests for the strip above the composer: the day's own material, offered as something to
/// write about.
///
/// Two of these are product rules rather than logic: a screen capture must never become a
/// writing prompt, and the store query must survive a busy day. Both are ways the feature
/// fails quietly rather than loudly, which is why they are pinned here.
@Suite("Day context")
struct DayContextTests {

    private let day = TestClock.reference

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: day
        ) ?? day
    }

    private func event(_ title: String, at date: Date, evidence: String? = nil) -> CaptureEvent {
        CaptureEvent(
            id: "ev-\(title)-\(date.timeIntervalSince1970)",
            ts: date,
            appBundleID: LifeImporter.calendarBundleID,
            appName: LifeImporter.calendarAppName,
            windowTitle: title,
            text: evidence ?? title,
            textHash: "h"
        )
    }

    private func photoRow(place: String?, shots: Int, on date: Date) -> CaptureEvent {
        let row = PhotoImporter.DayInPlace(day: date, cell: nil, shots: shots)
        return CaptureEvent(
            id: "ph-\(place ?? "-")-\(shots)",
            ts: date,
            appBundleID: PhotoImporter.bundleID,
            appName: PhotoImporter.appName,
            windowTitle: place,
            text: row.evidence(placeName: place),
            textHash: "h"
        )
    }

    private func span(_ label: String, seconds: TimeInterval) -> WorkSpan {
        WorkSpan(
            label: label, entityID: nil, start: day, end: day.addingTimeInterval(seconds),
            seconds: seconds, apps: [], captureIDs: []
        )
    }

    // MARK: - What may become a tile

    @Test("A screen capture never becomes a writing prompt")
    func screenCapturesAreNotOffered() {
        // The one rule in this file worth breaking a build over. Captures are the only source
        // that can hold text from an app the user would never want quoted back at them (a
        // password manager, somebody else's message, a medical result), and a tile is text
        // handed over unread. The imported sources are safe because their rows are titles and
        // counts the user themselves created.
        let screen = CaptureEvent(
            id: "screen",
            ts: at(11),
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Test results \u{2014} MyChart",
            text: "Test results \u{2014} MyChart",
            textHash: "h"
        )

        let context = DayContext.build(captures: [screen], spans: [])

        #expect(context.isEmpty, "a screen capture was offered as something to write about")
    }

    @Test("A meeting becomes a tile that starts a sentence")
    func meetingBecomesATile() {
        let context = DayContext.build(
            captures: [event("Call with Ana", at: at(10, 30))], spans: []
        )

        #expect(context.items.count == 1)
        let item = try? #require(context.items.first)
        #expect(item?.kind == .event)
        #expect(item?.title == "Call with Ana")
        // The line is an opening, not a statement. It has to be finishable by the user.
        #expect(item?.line.hasPrefix("Call with Ana, ") == true)
        #expect(item?.line.hasSuffix("… ") == true)
    }

    @Test("Meetings are offered in the order they happened")
    func meetingsAreChronological() {
        let context = DayContext.build(
            captures: [
                event("Standup", at: at(9)),
                event("Retro", at: at(16)),
                event("Call with Ana", at: at(10, 30)),
            ],
            spans: []
        )

        #expect(context.items.map(\.title) == ["Standup", "Call with Ana", "Retro"])
    }

    @Test("A day of back-to-back meetings does not become a wall of tiles")
    func meetingsAreCapped() {
        // Eight standups is not eight invitations to write. Past four the strip stops being
        // something you take in at a glance and becomes another list to get through.
        let many = (9..<17).map { event("Meeting \($0)", at: at($0)) }

        let context = DayContext.build(captures: many, spans: [])

        #expect(context.items.count == DayContext.maxEvents)
        #expect(context.items.first?.title == "Meeting 9", "the earliest meetings are kept")
    }

    @Test("An untitled calendar row is dropped rather than shown blank")
    func untitledEventIsDropped() {
        var blank = event("x", at: at(12))
        blank = CaptureEvent(
            id: blank.id, ts: blank.ts, appBundleID: blank.appBundleID,
            appName: blank.appName, windowTitle: "   ", text: blank.text, textHash: "h"
        )

        #expect(DayContext.build(captures: [blank], spans: []).isEmpty)
    }

    // MARK: - Photos

    @Test("A photo tile names the place and counts the photographs, and shows neither")
    func photoTileIsMetadataOnly() {
        // `PhotoImporter` never asks PhotoKit for image data of any size, and the absence of
        // that call is the proof of the promise. So the tile carries what the row carries: a
        // place name the user gave, and a number.
        let context = DayContext.build(
            captures: [photoRow(place: "Cala Piccola", shots: 6, on: day)], spans: []
        )

        let item = try? #require(context.items.first)
        #expect(item?.kind == .photos)
        #expect(item?.title == "Cala Piccola")
        #expect(item?.detail == "6 photos")
    }

    @Test("The count comes from the row, not from a second count of the same photographs")
    func photoCountIsReadNotRecomputed() {
        // Two numbers derived separately drift. The row is what an answer would quote, so the
        // tile quotes the row.
        #expect(DayContext.photoCount(from: "6 photos · Cala Piccola") == "6 photos")
        #expect(DayContext.photoCount(from: "1 photo") == "1 photo")
    }

    @Test("Photographs with no place still say something happened")
    func photosWithoutAPlace() {
        let context = DayContext.build(
            captures: [photoRow(place: nil, shots: 3, on: day)], spans: []
        )

        let item = try? #require(context.items.first)
        #expect(item?.title == "3 photos")
        #expect(item?.detail == nil, "the count is the title; saying it twice is not more")
    }

    @Test("The photographs themselves replace the count of them")
    func framesReplaceImportedRows() {
        // Both describe the same afternoon. A picture of it is the better invitation, and
        // showing the tally underneath the pictures would just be the same fact twice.
        let frames = [
            PhotoFrames.Frame(id: "a", date: at(14, 2)),
            PhotoFrames.Frame(id: "b", date: at(17, 41)),
        ]

        let context = DayContext.build(
            captures: [photoRow(place: "Cala Piccola", shots: 6, on: day)],
            spans: [],
            frames: frames
        )

        #expect(context.items.count == 2)
        #expect(context.items.allSatisfy { $0.frame != nil })
        #expect(context.items.first?.title == DayContext.clockTime(
            at(14, 2), calendar: .current, locale: .current
        ))
    }

    @Test("A tile carries a reference to a photograph, never a photograph")
    func framesCarryReferencesOnly() {
        // `Frame` is an identifier and a time. The pixels are fetched by the view that draws
        // them and are never held by the model, which is what keeps "nothing is stored" true
        // at the level of the type rather than as a habit.
        let context = DayContext.build(
            captures: [], spans: [], frames: [PhotoFrames.Frame(id: "asset-1", date: at(14))]
        )

        #expect(context.items.first?.frame?.id == "asset-1")
    }

    @Test("A day of a hundred photographs offers four")
    func framesAreCapped() {
        let many = (0..<100).map { PhotoFrames.Frame(id: "f\($0)", date: at(9)) }

        let context = DayContext.build(captures: [], spans: [], frames: many)

        #expect(context.items.count == PhotoFrames.maxPerDay)
    }

    @Test("With no readable library the imported rows still say something happened")
    func importedRowsSurviveWithoutTheLibrary() {
        // Photos declined, or macOS handing over a slice of the library under limited access.
        // The day-row is what is left, and it is better than an empty strip.
        let context = DayContext.build(
            captures: [photoRow(place: "Cala Piccola", shots: 6, on: day)], spans: [], frames: []
        )

        #expect(context.items.first?.title == "Cala Piccola")
        #expect(context.items.first?.frame == nil)
    }

    @Test("Photographs come before meetings")
    func photosLeadTheStrip() {
        let context = DayContext.build(
            captures: [event("Standup", at: at(9)), photoRow(place: "Home", shots: 2, on: day)],
            spans: []
        )

        #expect(context.items.first?.kind == .photos)
    }

    // MARK: - Work

    @Test("The longest stretch of work is offered, and a short one is not")
    func workTile() {
        let busy = DayContext.build(
            captures: [], spans: [span("Mail", seconds: 600), span("The listings", seconds: 8_040)]
        )
        let item = try? #require(busy.items.first)
        #expect(item?.kind == .work)
        #expect(item?.title == "The listings")
        #expect(item?.detail == "2h14")

        let quiet = DayContext.build(captures: [], spans: [span("Mail", seconds: 600)])
        #expect(quiet.isEmpty, "ten minutes of mail is not what the day was about")
    }

    @Test("A day Memoir saw nothing in offers nothing")
    func emptyDayIsEmpty() {
        // Not a placeholder tile, not an apology. The composer already has `JournalPrompt` for
        // this case and the strip simply does not appear.
        #expect(DayContext.build(captures: [], spans: []).isEmpty)
    }

    // MARK: - Fetching

    @Test("A busy day does not bury the day's material")
    func importedRowsSurviveABusyDay() async throws {
        // The bug this exists to prevent: imported rows are timestamped by when the thing
        // happened, so a photo day-row sits at 00:00 and a morning meeting at 09:00: the
        // oldest rows of the day. Fetching the day with a limit and filtering in Swift spends
        // the whole quota on this afternoon's screen captures and returns an empty strip on
        // exactly the days worth writing about.
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let dayStart = Calendar.current.startOfDay(for: day)

            try await store.insert(capture: event("Call with Ana", at: at(9)))
            for minute in 0..<300 {
                try await store.insert(capture: CaptureEvent(
                    id: "screen-\(minute)",
                    ts: at(17).addingTimeInterval(Double(minute)),
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    windowTitle: "Listings",
                    text: "listings",
                    textHash: "h-\(minute)"
                ))
            }

            let imported = try await store.captures(
                from: dayStart,
                to: at(23),
                appBundleIDs: [PhotoImporter.bundleID, LifeImporter.calendarBundleID],
                limit: 200
            )

            #expect(imported.count == 1)
            #expect(imported.first?.windowTitle == "Call with Ana")
        }
    }
}
