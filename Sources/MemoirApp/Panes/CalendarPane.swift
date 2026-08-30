import SwiftUI
import MemoirKit

/// A day, any day, as facts, then as what you wrote, then as the same date in other years.
///
/// ## Why this is not called Today any more
///
/// It was `TodayModel`, and it could only ever show the current day. That made the product's own
/// ten-year claim unreachable from the interface: there was no way to look at last August. The
/// calendar is now the way you move, and today is simply the day it opens on.
///
/// The name follows the category rather than inventing one. Day One and Diarly both call this
/// surface **Calendar**, beside a Timeline and an On This Day; Apple Journal has no name for it at
/// all. Timeline was the other candidate and would have been a lie: it promises a scrolling list
/// and this is a month grid with a day beside it.
///
/// ## What it shows, in that order
///
/// The measured facts first (hours tracked, hours focused, where they went), because they are
/// three lines that say what kind of day it was before you read a word of it. Then your entry.
/// Then the same date in earlier years, which is the one feature the whole category agrees people
/// love and the only one here that needs a decade to mean anything.
///
/// Not a work log. We can honestly say how long an app was frontmost. We cannot say whether that
/// was productive, so no score is ever invented.
@MainActor
final class CalendarModel: ObservableObject {
    @Published private(set) var minutesByHour: [Int] = Array(repeating: 0, count: 13)
    @Published private(set) var trackedMinutes = 0
    @Published private(set) var topApp: String?
    @Published private(set) var dueToday: [Entity] = []
    /// Notes Memoir picked up on the selected day: imported from a folder, or worked out from a
    /// screen. Not yours, and kept apart from yours. See `Store.notes(written:from:to:)`.
    @Published private(set) var picked: [Entity] = []
    /// People the record saw on the selected day, most recently first.
    @Published private(set) var peopleToday: [Entity] = []
    @Published private(set) var loaded = false

    /// The day being read. Today until the user picks another.
    @Published private(set) var selected: Date = Calendar.current.startOfDay(for: Date())
    /// The month the grid is showing, which is not always the month of `selected`.
    @Published private(set) var visibleMonth: Date = Calendar.current.startOfDay(for: Date())
    /// What was written on the selected day, newest first.
    @Published private(set) var entries: [Entity] = []
    /// How many entries each day of `visibleMonth` holds, keyed by day-of-month. The grid shades
    /// from this, so a day with nothing in it is simply not shaded, never labelled as empty.
    @Published private(set) var entryCounts: [Int: Int] = [:]
    /// Days of `visibleMonth` the record has anything for, keyed the same way.
    ///
    /// The grid used to show writing and nothing else, and on a real month that is four or five
    /// shaded squares in thirty: a memory product whose calendar reads as empty. It is not
    /// empty. This is the other half, and it gets the other half of the mark: violet for what
    /// Memoir saw, against the cream of what you wrote.
    @Published private(set) var recordedDays: Set<Int> = []
    /// The same date in earlier years, newest first. The reason a decade is worth having.
    @Published private(set) var onThisDay: [(year: Int, entries: [Entity])] = []

    /// The photographs taken on the selected day. References and times, never pixels: the
    /// tiles fetch the images themselves and keep none of them. See `PhotoFrames`.
    ///
    /// The journal offers today's four as something to write *about*; this is the other half,
    /// and a day is read here rather than written, so it shows more of them. A day you are
    /// trying to remember is exactly the day its photographs are worth looking at.
    @Published private(set) var frames: [PhotoFrames.Frame] = []

    // MARK: Writing
    //
    // This was a pane of its own, and could only ever write about today. Reading and writing a
    // day are the same act on the same surface now, which is what makes a Tuesday three weeks
    // ago something you can still put a sentence against.

    /// What is in the composer, for the day being read.
    @Published var draft: String = ""
    /// The day's own pieces, offered as something to write *about*. See `DayContext`.
    @Published private(set) var context: DayContext = .empty
    /// Chips already spent, so picking one twice does not write the line twice.
    @Published private(set) var used: Set<String> = []
    /// The entry being rewritten, if any, and the text of the rewrite.
    @Published private(set) var editing: Entity.ID?
    @Published var editDraft: String = ""
    /// The photograph being looked at full size, if any.
    @Published var viewing: PhotoFrames.Frame?

    private let shell: ShellModel

    init(shell: ShellModel) {
        self.shell = shell
    }

    /// True when the day being read is one a person could still write about.
    var canWrite: Bool { selected <= Date() }

    /// When an entry written now would be filed, for the day being read.
    ///
    /// The day it is about, at the current time of day, so entries within a day still sort by
    /// when they were written. `createdAt` keeps the real moment; see `MemoryService.writeEntry`.
    private var filedAt: Date {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selected)
        if calendar.isDateInToday(selected) { return Date() }
        let since = Date().timeIntervalSince(calendar.startOfDay(for: Date()))
        return dayStart.addingTimeInterval(min(since, 86_399))
    }

    /// Moves to a day and reloads. Selecting a day in another month moves the grid too.
    func select(_ day: Date) {
        guard !Calendar.current.isDate(day, inSameDayAs: selected) else { return }
        selected = Calendar.current.startOfDay(for: day)
        visibleMonth = selected
        // A draft belongs to the day it was being written about. Carrying it to the next day
        // would file Tuesday's sentence under Wednesday on the next press of Keep.
        draft = ""
        used = []
        cancelEdit()
        viewing = nil
        Task { await reload() }
    }

    /// Steps the grid by whole months without changing which day is selected.
    func stepMonth(_ delta: Int) {
        let calendar = Calendar.current
        guard let moved = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        visibleMonth = moved
        Task { await reload() }
    }

    var isToday: Bool { Calendar.current.isDateInToday(selected) }

    /// "Tuesday", for the composer's invitation.
    var shortDayName: String { selected.formatted(.dateTime.weekday(.wide)) }

    /// The day's measured shape, on one line, or nil when there is nothing measured.
    ///
    /// A caption under the date. It was two grey key/value pairs set at the same weight as the
    /// sections below them, which is most of why the panel read as flat.
    var dayShape: String? {
        guard trackedMinutes > 0 else { return nil }
        var line = "\(StatBlock.hm(trackedMinutes)) tracked"
        if let topApp { line += " · mostly in \(topApp)" }
        return line
    }

    // MARK: - Writing

    /// Puts a chip's line in the composer, at the end of whatever is already there.
    ///
    /// Into the draft, never into memory: the line is a first sentence to argue with, and it
    /// has to be deletable without the journal having recorded it.
    func pick(_ item: DayContext.Item) {
        guard !used.contains(item.id), !item.line.isEmpty else { return }
        used.insert(item.id)
        draft = draft.isEmpty ? item.line : draft + "\n" + item.line
    }

    /// Writes what is in the composer, as yours, filed under the day being read.
    ///
    /// No confirm step. Typing into a field labelled as your own journal *is* the explicit act,
    /// and a dialog between somebody and their own sentence is the kind of friction that stops
    /// people writing at all.
    func write() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        // The chips are offered again for the next entry. Two entries in one day about two
        // different meetings is normal, and a spent chip that never came back would make the
        // second one impossible.
        used = []
        let memory = shell.memory
        let day = filedAt
        Task { [weak self] in
            _ = try? await memory.writeEntry(text, filedAt: day)
            await self?.reload()
        }
    }

    /// Opens an entry for rewriting. One at a time.
    func beginEdit(_ entry: Entity) {
        editing = entry.id
        editDraft = entry.title
    }

    func cancelEdit() {
        editing = nil
        editDraft = ""
    }

    /// Saves a rewrite, in place, keeping the day the entry is filed under.
    func saveEdit() {
        guard let id = editing else { return }
        let text = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancelEdit()
        let memory = shell.memory
        Task { [weak self] in
            try? await memory.rewriteEntry(id: id, title: text)
            await self?.reload()
        }
    }

    /// What the weather was on a day, or which switch is standing in the way of knowing.
    ///
    /// The order of the guards is the order of the consents: Memoir's own switch first, and
    /// only then macOS. Asking the system for a location before the user has turned weather on
    /// would be a permission prompt out of nowhere for a feature they never enabled.
    private func weather(on day: Date) async -> DayContext.WeatherState {
        guard AppConfig.load().allowWeather else { return .off }
        guard let here = await WhereYouAre.shared.coarseLocation() else { return .needsLocation }
        let reading = await Weather.forDay(
            day,
            latitude: here.coordinate.latitude,
            longitude: here.coordinate.longitude,
            allowed: true
        )
        return reading.map { .known($0) } ?? .unavailable
    }

    /// Opens whichever switch a chip is asking for.
    func settle(_ need: DayContext.Item.Need) {
        switch need {
        case .weatherSwitch:
            shell.onOpenSettings?(.data)
        case .locationPermission:
            Permissions.openPrivacyPane(WhereYouAre.settingsPane)
        }
    }

    var hasAccessibility: Bool { shell.hasAccessibility }

    func reload() async {
        let store = shell.store
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selected)
        let dayEndExclusive = dayStart.addingTimeInterval(86_400)
        // A past day is read to its own midnight; today stops at the current moment, so the
        // hour bars do not draw a flat evening that has not happened yet.
        let now = min(Date(), dayEndExclusive)
        let sessions = (try? await store.sessions(from: dayStart, to: now)) ?? []

        var hours = Array(repeating: 0, count: 13)
        var byApp: [String: TimeInterval] = [:]

        for session in sessions where !session.idle {
            // The timer is gone; its rows are not. Somebody's three recorded focus runs must
            // not start reading as an hour spent in an app called Focus.
            if FocusSession.isFocusRow(session) { continue }
            byApp[session.appName, default: 0] += session.duration
            // Spread the session across the 09:00–21:00 slots it overlaps.
            var cursor = max(session.startedAt, dayStart)
            let end = min(session.endedAt, now)
            while cursor < end {
                let hour = calendar.component(.hour, from: cursor)
                let nextHour = calendar.date(bySettingHour: hour, minute: 59, second: 59, of: cursor)?
                    .addingTimeInterval(1) ?? end
                let slice = min(end, nextHour).timeIntervalSince(cursor)
                if (9...21).contains(hour) {
                    hours[min(12, hour - 9)] += Int(slice / 60)
                }
                cursor = nextHour
            }
        }

        minutesByHour = hours
        trackedMinutes = Int(byApp.values.reduce(0, +) / 60)
        topApp = byApp.max { $0.value < $1.value }?.key

        let open = (try? await store.openCommitments(now: now)) ?? []
        let dayEnd = dayEndExclusive
        dueToday = open.filter { entity in
            guard let due = entity.dueAt else { return false }
            return due < dayEnd
        }
        // Who came up. Provenance carries the timestamp of each sighting, so this is a
        // question the record can answer exactly rather than estimate.
        let people = (try? await store.entities(kind: .person, includeDeleted: false)) ?? []
        var seen: [(Entity, Date)] = []
        for person in people {
            let quotes = (try? await store.provenance(entityID: person.id)) ?? []
            if let latest = quotes.map(\.ts).max(), latest >= dayStart {
                seen.append((person, latest))
            }
        }
        peopleToday = seen.sorted { $0.1 > $1.1 }.map(\.0)

        // Read live from the library rather than from the memory: what is stored is one row
        // per day per place with a count in it, which is the right thing to remember and the
        // wrong thing to look at.
        frames = PhotoFrames.frames(on: dayStart, limit: 8, calendar: calendar)

        // What the day holds, offered as something to write about. Built for the day being
        // read, not for today: that is the whole point of the merge.
        let memory = shell.memory
        let spans = (try? await memory.workSpans(from: dayStart, to: now)) ?? []
        let imported = (try? await store.captures(
            from: dayStart, to: now,
            appBundleIDs: [PhotoImporter.bundleID, LifeImporter.calendarBundleID],
            limit: 200
        )) ?? []
        context = DayContext.build(
            captures: imported, spans: spans, frames: frames,
            weather: await weather(on: dayStart)
        )

        // ---- what you wrote: this day, this month, and this date in other years ----
        //
        // Journal entries only. Filtering on `source == .authored` also caught every note the
        // vault importer had read out of a folder: three Obsidian filenames listed beside the
        // sentence somebody typed, in the same type, with nothing to tell them apart.
        let written = (try? await store.notes(
            written: true, from: .distantPast, to: .distantFuture
        )) ?? []

        entries = written
            .filter { $0.updatedAt >= dayStart && $0.updatedAt < dayEndExclusive }
            .sorted { $0.updatedAt > $1.updatedAt }

        // ---- and what Memoir picked up on the same day, which is a different thing ----
        picked = (try? await store.notes(written: false, from: dayStart, to: dayEndExclusive)) ?? []

        var counts: [Int: Int] = [:]
        for note in written where calendar.isDate(note.updatedAt, equalTo: visibleMonth, toGranularity: .month) {
            counts[calendar.component(.day, from: note.updatedAt), default: 0] += 1
        }
        entryCounts = counts

        if let month = calendar.dateInterval(of: .month, for: visibleMonth) {
            recordedDays = (try? await store.recordedDays(from: month.start, to: month.end)) ?? []
        }

        // On this day: same month and day, any earlier year. Grouped so a year with three
        // entries in it reads as one year rather than three separate memories.
        let month = calendar.component(.month, from: dayStart)
        let day = calendar.component(.day, from: dayStart)
        let thisYear = calendar.component(.year, from: dayStart)
        var byYear: [Int: [Entity]] = [:]
        for note in written {
            let parts = calendar.dateComponents([.year, .month, .day], from: note.updatedAt)
            guard parts.month == month, parts.day == day, let year = parts.year, year < thisYear else {
                continue
            }
            byYear[year, default: []].append(note)
        }
        onThisDay = byYear.keys.sorted(by: >).map {
            (year: $0, entries: byYear[$0]!.sorted { $0.updatedAt > $1.updatedAt })
        }

        loaded = true
    }
}


// MARK: - The month grid

/// One month, with the days you wrote in shaded by how much.
///
/// The shading is the argument for the whole product: a month is faint, a decade of months is a
/// picture of a life accumulating. Nothing marks an empty day: no dot, no label, no "nothing
/// written". Skip three weeks and the grid simply looks quiet, which is the difference between a
/// journal and a habit tracker.
private struct MonthGrid: View {
    @ObservedObject var model: CalendarModel
    let compact: Bool

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 2) {
                Text(monthLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.dim)
                Spacer(minLength: 4)
                // Only when it would do something. Browsing to 2019 used to mean eighty
                // clicks of ‹ to get back, because nothing on this surface said "today".
                if !isShowingToday {
                    Button { model.select(Date()) } label: {
                        Text("Today")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.dim)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.tile))
                    }
                    .buttonStyle(.plain)
                    .help("Back to today")
                    .padding(.trailing, 3)
                }
                step(-1, symbol: "chevron.left", help: "Previous month")
                step(1, symbol: "chevron.right", help: "Next month")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(Array(weekdayInitials.enumerated()), id: \.offset) { _, initial in
                    Text(initial)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ghost)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: cellHeight)
                    }
                }
            }

            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.markInk.opacity(0.22))
                    .frame(width: 9, height: 9)
                Text("Memoir has a record")
                RoundedRectangle(cornerRadius: 2).fill(Theme.markInk)
                    .frame(width: 9, height: 9)
                    .padding(.leading, 3)
                Text("you wrote")
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.ghost)
            .padding(.top, 2)
        }
    }

    /// One month step.
    ///
    /// The target used to be the glyph and nothing else: a 9pt chevron with no content shape,
    /// so about six points by nine of hittable button. It stepped correctly every time it was
    /// actually hit, which was the problem: it read as broken rather than as small.
    private func step(_ delta: Int, symbol: String, help: String) -> some View {
        Button { model.stepMonth(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.faint)
        .help(help)
        .accessibilityLabel(help)
    }

    private func dayCell(_ day: Date) -> some View {
        let number = calendar.component(.day, from: day)
        let count = model.entryCounts[number] ?? 0
        let recorded = model.recordedDays.contains(number)
        let isSelected = calendar.isDate(day, inSameDayAs: model.selected)
        let isToday = calendar.isDateInToday(day)
        let future = day > Date()

        return Button {
            model.select(day)
        } label: {
            Text("\(number)")
                .font(.system(size: 11, weight: isSelected || count > 0 ? .medium : .regular))
                .foregroundStyle(foreground(selected: isSelected, count: count, future: future))
                .frame(maxWidth: .infinity)
                .frame(height: cellHeight)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Theme.ink : shade(entries: count, recorded: recorded))
                )
                .overlay(
                    // Today is outlined rather than filled, so it is always findable without
                    // implying anything was written in it.
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isToday && !isSelected ? Theme.ink.opacity(0.45) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(future)
    }

    /// One hue, two weights: pale violet where Memoir has a record, solid violet where you
    /// wrote something.
    ///
    /// It was a cream fill and a small violet dot, on the argument that the mark's two halves
    /// already mean "what you wrote" and "what it saw". The dot was the problem: three points
    /// of colour under a numeral, on a grid this size, reads as dirt rather than as data. Two
    /// steps of the same colour is the same distinction and you can see it.
    ///
    /// Writing still ramps inside its own step, because a month getting darker over a decade is
    /// the argument for the whole product. Three steps and no more: a finer ramp would invite
    /// reading precision into a colour.
    private func shade(entries: Int, recorded: Bool) -> Color {
        switch entries {
        case 0: return recorded ? Theme.markInk.opacity(0.22) : .clear
        case 1: return Theme.markInk.opacity(0.72)
        case 2: return Theme.markInk.opacity(0.86)
        default: return Theme.markInk
        }
    }

    private func foreground(selected: Bool, count: Int, future: Bool) -> Color {
        if selected { return Theme.bg }
        if future { return Theme.ghost.opacity(0.5) }
        // Dark on the solid violet, light on the pale wash: the writing steps are opaque
        // enough that white on them is the harder read.
        return count > 0 ? Theme.bg : Theme.faint
    }

    /// True when the grid is on this month *and* today is the day being read, which is the only
    /// state in which "Today" has nothing left to do.
    private var isShowingToday: Bool {
        calendar.isDate(model.visibleMonth, equalTo: Date(), toGranularity: .month)
            && model.isToday
    }

    private var cellHeight: CGFloat { compact ? 18 : 22 }

    private var monthLabel: String {
        model.visibleMonth.formatted(.dateTime.month(.wide).year())
    }

    /// Weekday initials in the user's own first-day-of-week order.
    private var weekdayInitials: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The grid, with leading nils for the days before the first of the month.
    private var cells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: model.visibleMonth),
              let count = calendar.range(of: .day, in: .month, for: model.visibleMonth)?.count
        else { return [] }

        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var out: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            out.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        return out
    }
}

// MARK: - The pane

/// A day: what Memoir saw, then what you wrote, then this date in other years.
///
/// The three stats open the day because they are the fastest read on the page and they are the
/// same three every day, so the eye learns where they are. Your sentence follows and gets the
/// room; the same date in earlier years sits at the bottom because that is the part no other app
/// can offer and the part that needs the decade.
struct CalendarPane: View {
    /// Observed, never owned. The selected day belongs to the shell so it survives the band
    /// closing and so `openToday()` can reach it. See `ShellModel.calendar`.
    @ObservedObject var model: CalendarModel
    @Environment(\.memoirSurface) private var surface

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MonthGrid(model: model, compact: surface == .band)
                .frame(width: surface == .band ? 196 : 232)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            Theme.vHairline

            VStack(alignment: .leading, spacing: 0) {
                // Pinned: the date, the day's shape, and the box. Outside the scroll on
                // purpose, so writing is one click away however much the day holds, and so
                // `ImageRenderer` can still draw it.
                DayHead(model: model)
                ScrollView {
                    CalendarDay(model: model)
                }
                .scrollContentBackground(.hidden)
            }
        }
        // Over both columns: a photograph you opened should not be squeezed into the half of
        // the band it happened to be listed in.
        .overlay {
            if model.viewing != nil {
                PhotoViewer(frames: model.frames, showing: $model.viewing)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.viewing)
        .task { await model.reload() }
    }
}

/// The day itself: the log line, what you wrote, who came up, and earlier years.
///
/// A view of its own and outside the pane's `ScrollView`, for the reason `JournalWriting` is:
/// `ImageRenderer` lays out nothing inside a scroll view, so a snapshot of `CalendarPane` was a
/// picture of the month grid and a black rectangle. This is the half of the surface where the
/// typography argument actually happens, and it could not be looked at.
/// The date, the day's shape, and the box you write in. Pinned above the record.
///
/// The date is set as the panel's title rather than a caption. It was 11pt grey, which made
/// the smallest thing on the surface the one thing the whole surface is about.
struct DayHead: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.memoirSurface) private var surface
    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dayHeading)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.ink)

            if let shape = model.dayShape {
                Text(shape)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ghost)
                    .padding(.top, 3)
            }

            if model.canWrite {
                composer.padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// The box, and the day's own material inside it.
    ///
    /// The chips live *in* the box rather than under it. They are a prompt, so they belong
    /// above the writing they start — and inside costs no height, because an empty box has the
    /// room anyway. They go when there is a draft: you are writing, you no longer need them.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // `Theme.tile`, not `Theme.card`. Card is #0C0C0D against a pure black band —
                // twelve values out of 255, which on this surface is not a container at all.
                // Tile is the palette's own fill for something you interact with.
                RoundedRectangle(cornerRadius: 9).fill(Theme.tile)
                if model.draft.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ghost)
                        .padding(.horizontal, 15)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.draft)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink)
                        .scrollContentBackground(.hidden)
                        .focused($writing)
                        .frame(minHeight: 42)
                    if model.draft.isEmpty, !model.context.items.isEmpty {
                        seedChips
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
            }
            .frame(minHeight: model.draft.isEmpty ? 96 : 78)

            HStack(spacing: 8) {
                Text("Yours, markdown and all. Nothing ever deletes it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ghost)
                Spacer(minLength: 8)
                Button("Keep") { model.write() }
                    .buttonStyle(PillButton(emphasis: model.draft.isEmpty ? .quiet : .primary))
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 9)
        }
    }

    private var seedChips: some View {
        HStack(spacing: 6) {
            ForEach(model.context.items.prefix(3)) { item in
                Button { pickOrSettle(item) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.kind.symbol)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.ghost)
                        Text(item.title)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ghost)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.line2))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(model.used.contains(item.id) ? 0.4 : 1)
                .help(item.needs == nil ? "Start a line about this" : "Turn this on")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickOrSettle(_ item: DayContext.Item) {
        if let need = item.needs { model.settle(need) } else { model.pick(item) }
    }

    private var placeholder: String {
        if !model.entries.isEmpty { return "Add to \(model.shortDayName)" }
        return model.isToday ? "Write something for today" : "Write something for \(model.shortDayName)"
    }

    private var dayHeading: String {
        if model.isToday { return "Today · \(model.selected.formatted(.dateTime.day().month(.wide)))" }
        return model.selected.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

struct CalendarDay: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.memoirSurface) private var surface

    var body: some View {
        VStack(alignment: .leading, spacing: surface == .band ? 13 : 18) {
            written
            machineRecord
            onThisDay
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Yours: the largest type on the record, in the mark's own cream, as markdown.
    ///
    /// Cream rather than white is not decoration. `Theme.markPaper` and `Theme.markInk` are the
    /// two halves of the logo and they already mean something (cream is what you wrote, violet
    /// is what it saw), so the one surface where both appear is the one that should say it
    /// loudest. Everything a machine measured on this page is grey.
    @ViewBuilder private var written: some View {
        if !model.entries.isEmpty {
            VStack(alignment: .leading, spacing: surface == .band ? 15 : 20) {
                ForEach(model.entries) { entry in
                    if model.editing == entry.id {
                        editor(for: entry)
                    } else {
                        EntryRow(entry: entry, size: surface == .band ? 15 : 16) {
                            model.beginEdit(entry)
                        }
                    }
                }
            }
        }
    }

    /// An entry, being rewritten in place: same size, same cream, so nothing jumps.
    private func editor(for entry: Entity) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            TextEditor(text: $model.editDraft)
                .font(.system(size: surface == .band ? 15 : 16))
                .foregroundStyle(Theme.markPaper)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 68)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.tile))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Theme.markInk.opacity(0.45), lineWidth: 1)
                )
            HStack(spacing: 8) {
                Text("Stays filed under \(model.selected.formatted(.dateTime.weekday(.wide).day().month())).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ghost)
                Spacer(minLength: 8)
                Button("Cancel") { model.cancelEdit() }
                    .buttonStyle(PillButton(emphasis: .quiet))
                Button("Save") { model.saveEdit() }
                    .buttonStyle(PillButton(emphasis: .primary))
                    .disabled(model.editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Everything on this surface that a person did not write: the photographs, the notes
    /// Memoir picked up, the people it saw. One rule above the lot and one heading, so the page
    /// reads as two halves rather than five sections.
    @ViewBuilder private var machineRecord: some View {
        if !model.frames.isEmpty || !model.picked.isEmpty || !model.peopleToday.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Theme.hairline
                sectionLabel("WHAT MEMOIR SAW")
                photographs
                if !model.picked.isEmpty || !model.peopleToday.isEmpty {
                    sawTable
                }
            }
        }
    }

    /// The day's photographs, at a size worth looking at.
    ///
    /// They were 26pt squares in a table cell, which is decoration rather than photographs, and
    /// they lead this half because on most days they are the most valuable thing in it. Click
    /// one and it fills the band; see `PhotoViewer`.
    @ViewBuilder private var photographs: some View {
        if !model.frames.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 78, maximum: 108), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(model.frames) { frame in
                    Button { model.viewing = frame } label: {
                        Thumbnail(frame: frame)
                            .frame(height: 72)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rChip))
                            .contentShape(RoundedRectangle(cornerRadius: Theme.rChip))
                    }
                    .buttonStyle(.plain)
                    .help("Open")
                    .accessibilityLabel("Photograph, open full size")
                }
            }
        }
    }

    /// Notes and people, as a two-column table. The texture change is what stops the machine's
    /// half reading as more prose: three uppercase labels in a row was the flatness.
    private var sawTable: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 9) {
            if !model.picked.isEmpty {
                GridRow {
                    Text("Notes").font(.system(size: 10)).foregroundStyle(Theme.ghost)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.picked.prefix(Self.pickedShown)) { note in
                            Text(note.title)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.dim)
                                .lineLimit(1)
                        }
                        if model.picked.count > Self.pickedShown {
                            Text("and \(model.picked.count - Self.pickedShown) more")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ghost)
                        }
                    }
                }
            }
            if !model.peopleToday.isEmpty {
                GridRow {
                    Text("People").font(.system(size: 10)).foregroundStyle(Theme.ghost)
                    Text(model.peopleToday.prefix(8).map(\.title).joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// How many picked-up notes a day lists before it starts counting instead.
    private static let pickedShown = 5

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.faint)
    }

    /// The same date, earlier years. Your writing, so cream, but dimmed: it is history.
    @ViewBuilder private var onThisDay: some View {
        if !model.onThisDay.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Theme.hairline
                sectionLabel("ON THIS DAY")
                ForEach(model.onThisDay, id: \.year) { year in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(year.year))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(Theme.faint)
                        ForEach(year.entries) { entry in
                            MarkdownText(markdown: entry.title, size: 12.5,
                                         color: Theme.markPaper.opacity(0.62))
                        }
                    }
                }
            }
        }
    }
}

/// One entry, with the way to rewrite it.
///
/// The affordance is a tag on hover rather than a click on the text itself, because the text is
/// selectable and click-to-edit would eat every attempt to copy a line out of it.
private struct EntryRow: View {
    let entry: Entity
    let size: CGFloat
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MarkdownText(markdown: entry.title, size: size, color: Theme.markPaper)
            if let written = writtenLater {
                Text(written)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ghost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: edit) {
                    Text("Edit")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.tile))
                }
                .buttonStyle(.plain)
                .help("Rewrite this entry")
            }
        }
        .onHover { hovering = $0 }
    }

    /// "written on 23 August", when the entry was typed on a different day from the one it is
    /// filed under. Absent when they agree, which is the ordinary case.
    private var writtenLater: String? {
        let calendar = Calendar.current
        guard !calendar.isDate(entry.createdAt, inSameDayAs: entry.updatedAt) else { return nil }
        return "written on \(entry.createdAt.formatted(.dateTime.day().month(.wide)))"
    }
}

/// A photograph, full size, over the band's body.
struct PhotoViewer: View {
    let frames: [PhotoFrames.Frame]
    @Binding var showing: PhotoFrames.Frame?

    var body: some View {
        ZStack {
            // Solid, not a scrim. At 97% the month grid and the composer still read through it
            // and the photograph was competing with a calendar; a picture you opened should be
            // the only thing on the surface until you close it.
            Theme.bg.ignoresSafeArea()
            if let showing {
                Thumbnail(frame: showing, size: 1200, fit: true)
                    .padding(.horizontal, 46)
                    .padding(.vertical, 26)
            }
            HStack {
                step(-1, symbol: "chevron.left", help: "Previous photograph")
                Spacer()
                step(1, symbol: "chevron.right", help: "Next photograph")
            }
            .padding(.horizontal, 12)

            VStack {
                HStack {
                    Spacer()
                    Button { showing = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Theme.ink.opacity(0.10)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                    .keyboardShortcut(.escape, modifiers: [])
                }
                Spacer()
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func step(_ delta: Int, symbol: String, help: String) -> some View {
        if frames.count > 1 {
            Button { move(delta) } label: {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.ink.opacity(0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }

    private func move(_ delta: Int) {
        guard let showing, let at = frames.firstIndex(where: { $0.id == showing.id }) else { return }
        let next = (at + delta + frames.count) % frames.count
        self.showing = frames[next]
    }

    private var caption: String? {
        guard let showing, let at = frames.firstIndex(where: { $0.id == showing.id }) else { return nil }
        return "\(at + 1) of \(frames.count) · \(showing.date.formatted(date: .omitted, time: .shortened))"
    }
}

extension CalendarDay {
    private var dayHeading: String {
        if model.isToday { return "Today · \(model.selected.formatted(.dateTime.day().month(.wide)))" }
        return model.selected.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}
