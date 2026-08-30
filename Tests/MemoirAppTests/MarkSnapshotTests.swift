import Testing
import SwiftUI
import AppKit
@testable import MemoirApp
@testable import MemoirKit

/// Renders the mark to a PNG so it can be looked at.
///
/// Not an assertion about pixels: a snapshot test that fails on every antialiasing change is
/// a test that gets deleted. This exists so a change to ``FoldMark`` can be *seen*, at the two
/// sizes that actually matter: the collapsed band, where it has to survive being 20 points
/// wide, and opened, where it is the portrait.
///
/// Set `MEMOIR_SNAPSHOT_DIR` to write somewhere other than the temp directory.
@MainActor
struct MarkSnapshotTests {

    @Test("the mark draws at every state and every size the shell uses")
    func renderTheMark() throws {
        let states = Expression.allCases
        let sizes: [CGFloat] = [20, 28, 74, 160]

        let sheet = VStack(alignment: .leading, spacing: 26) {
            Text("The fold: every state")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(Theme.markPaper))

            HStack(alignment: .bottom, spacing: 22) {
                ForEach(states, id: \.self) { state in
                    VStack(spacing: 10) {
                        FoldMark(traits: state.fold, gaze: .zero, blink: 0)
                            .frame(width: 74, height: 80)
                        Text(state.rawValue)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color(Theme.faint))
                    }
                }
            }

            Text("Capturing, at the sizes the shell uses")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(Theme.markPaper))

            HStack(alignment: .bottom, spacing: 26) {
                ForEach(sizes, id: \.self) { size in
                    VStack(spacing: 10) {
                        FoldMark(traits: Expression.idle.fold, gaze: .zero, blink: 0)
                            .frame(width: size, height: size * 1.1)
                        Text("\(Int(size))pt")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color(Theme.faint))
                    }
                }
            }

            Text("Not capturing, at those same sizes: the half that watches goes dark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(Theme.markPaper))

            HStack(alignment: .bottom, spacing: 26) {
                ForEach(sizes, id: \.self) { size in
                    FoldMark(traits: Expression.concerned.fold, gaze: .zero, blink: 0)
                        .frame(width: size, height: size * 1.1)
                }
            }
        }
        .padding(34)
        .background(Color.black)

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "the mark produced no image at all")

        let directory = ProcessInfo.processInfo.environment["MEMOIR_SNAPSHOT_DIR"]
            ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: directory).appendingPathComponent("memoir-mark.png")

        let data = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(data.representation(using: .png, properties: [:]))
        try png.write(to: url)

        // The only real assertion: something was actually drawn. A mark that renders as an
        // empty canvas still writes a valid PNG, and that is exactly the bug worth catching.
        #expect(png.count > 4_000, "the mark rendered, but produced almost no image data")
        print("mark snapshot: \(url.path)")
    }

    /// Every first-run screen, rendered so a redesign can be looked at rather than described.
    ///
    /// One file per step, at the real window width. `ImageRenderer` lays out nothing inside a
    /// `ScrollView`, so this renders the step body, which is exactly why
    /// ``OnboardingStepContent`` is a type of its own.
    @Test("every first-run screen draws")
    func renderEveryStep() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let directory = ProcessInfo.processInfo.environment["MEMOIR_SNAPSHOT_DIR"]
            ?? NSTemporaryDirectory()

        try Paths.$supportDirectoryOverride.withValue(temp) {
            for granted in [false, true] {
                let flow = OnboardingFlow(
                    accessibilityGranted: granted,
                    hotkeyLabel: "⌥Space",
                    requestAccessibility: {},
                    finish: {}
                )
                flow.recovery.adopt(try VaultKey.recoveryKey(for: VaultKey.randomKey()))

                for step in OnboardingFlow.Step.allCases {
                    // The granted pass exists for the permission screen, which is the only one
                    // that reads differently once the switch is on.
                    if granted && step != .permission { continue }
                    flow.step = step

                    let renderer = ImageRenderer(
                        content: OnboardingStepContent(flow: flow)
                            .frame(width: 560)
                            .background(Theme.bg)
                    )
                    renderer.scale = 2
                    let image = try #require(renderer.nsImage, "\(step) produced no image")
                    let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                    let png = try #require(rep.representation(using: .png, properties: [:]))

                    let suffix = granted ? "-granted" : ""
                    let url = URL(fileURLWithPath: directory)
                        .appendingPathComponent("onboarding-\(step)\(suffix).png")
                    try png.write(to: url)

                    // A screen that lays out to nothing still writes a valid PNG, which is the
                    // failure worth catching in a redesign.
                    #expect(png.count > 4_000, "\(step) rendered almost nothing")
                    print("onboarding snapshot: \(url.path)")
                }
            }
        }
    }

    @Test("the recovery key screen draws")
    func renderRecoveryStep() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try Paths.$supportDirectoryOverride.withValue(temp) {
            let flow = OnboardingFlow(
                accessibilityGranted: false,
                hotkeyLabel: "⌥Space",
                requestAccessibility: {},
                finish: {}
            )
            // A real recovery key, rendered the way the product renders one.
            flow.recovery.adopt(try VaultKey.recoveryKey(for: VaultKey.randomKey()))
            flow.step = .recovery

            // The step body, not the whole window: ImageRenderer renders nothing inside a
            // ScrollView, so a snapshot of OnboardingView shows chrome and an empty middle.
            let renderer = ImageRenderer(
                content: OnboardingStepContent(flow: flow)
                    .frame(width: 560)
                    .background(Theme.bg)
            )
            renderer.scale = 2
            let image = try #require(renderer.nsImage)

            let directory = ProcessInfo.processInfo.environment["MEMOIR_SNAPSHOT_DIR"]
                ?? NSTemporaryDirectory()
            let url = URL(fileURLWithPath: directory).appendingPathComponent("memoir-recovery.png")

            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: url)
            #expect(png.count > 4_000)
            print("recovery snapshot: \(url.path)")
        }
    }
}

// MARK: - The redesigned panes, rendered so they can be looked at

@MainActor
struct PaneSnapshotTests {

    /// Builds a memory with people, sightings, a commitment and a journal entry, then renders
    /// each pane against it.
    ///
    /// A screenshot of an empty pane proves nothing: every one of these surfaces is mostly
    /// empty-state until there is something in the database, and the empty states were not the
    /// thing being designed.
    private func seeded(_ dir: URL) async throws -> Store {
        let store = try Store(path: dir.appendingPathComponent("t.sqlite"), mayMigrate: true)
        let now = Date()
        var captureNo = 0

        /// Adds a person seen on `pages` different windows, saying `sentences` different
        /// things, re-read `reads` times each. The re-reads are the point: that is what a
        /// real database looks like, and it is what broke the first version of this panel.
        func person(_ name: String, daysAgo: Double, pages: Int, sentences: Int,
                    reads: Int, with others: [String] = []) async throws {
            let id = MemoryText.stableID("entity", EntityKind.person.rawValue,
                                         MemoryText.normalizedTitle(name))
            try await store.upsert(entity: Entity(
                id: id, kind: .person, title: name, detail: nil, dueAt: nil,
                confidence: 0.99, source: .inferred, createdAt: now, updatedAt: now
            ))
            for page in 0..<pages {
                for sentence in 0..<sentences {
                    for read in 0..<reads {
                        captureNo += 1
                        let ts = now.addingTimeInterval(-daysAgo * 86_400 - Double(read) * 60)
                        let capture = CaptureEvent(
                            id: "cap\(captureNo)", ts: ts,
                            appBundleID: "com.google.Chrome", appName: "Google Chrome",
                            windowTitle: "\(name) page \(page) - Google Chrome",
                            text: "\(name) said something", textHash: "h\(captureNo)"
                        )
                        try await store.insert(capture: capture)
                        try await store.add(provenance: Provenance(
                            entityID: id, captureID: capture.id, field: "title",
                            snippet: "\(name): the thing they said, number \(sentence)", ts: ts
                        ))
                        // Everyone in `others` shares this exact capture, which is what makes
                        // an edge between them.
                        for other in others {
                            let otherID = MemoryText.stableID("entity", EntityKind.person.rawValue,
                                                              MemoryText.normalizedTitle(other))
                            try await store.add(provenance: Provenance(
                                entityID: otherID, captureID: capture.id, field: "title",
                                snippet: "\(other): also in this conversation \(sentence)", ts: ts
                            ))
                        }
                    }
                }
            }
        }

        // A cluster who appear together.
        try await person("Elena", daysAgo: 1, pages: 3, sentences: 4, reads: 1)
        try await person("Pawel", daysAgo: 2, pages: 2, sentences: 3, reads: 1)
        try await person("Marco Rossi", daysAgo: 0.4, pages: 3, sentences: 3, reads: 9,
                         with: ["Elena", "Pawel"])
        // A second, separate cluster.
        try await person("Mum", daysAgo: 3, pages: 4, sentences: 5, reads: 2)
        try await person("Sofia", daysAgo: 9, pages: 2, sentences: 3, reads: 1, with: ["Mum"])
        // People with nobody attached.
        try await person("Ana", daysAgo: 140, pages: 2, sentences: 2, reads: 1)
        try await person("Jonas", daysAgo: 60, pages: 2, sentences: 2, reads: 1)
        try await person("Tom Whitfield", daysAgo: 21, pages: 2, sentences: 3, reads: 1)
        // And the noise: names scraped off one page, never seen again. These must not draw.
        for junk in ["typescript", "framer", "shadcn", "nordlysfoto", "Vector Art"] {
            try await person(junk, daysAgo: 5, pages: 1, sentences: 1, reads: 4)
        }

        try await store.upsert(entity: Entity(
            id: "c1", kind: .commitment, title: "Read Marco Rossi's draft",
            detail: nil, dueAt: now.addingTimeInterval(86_400), confidence: 0.8,
            source: .inferred, createdAt: now, updatedAt: now
        ))
        try await store.upsert(entity: Entity(
            id: "n1", kind: .note,
            title: "Went back to the listings again tonight. It is not the flat, it is that I still have not decided whether I am staying.",
            detail: nil, dueAt: nil, confidence: 1, source: .authored,
            createdAt: now, updatedAt: now
        ))
        // A second entry, written in markdown, because people write lists. Without one in the
        // fixture a snapshot cannot show whether the markdown renders or sits there as `**`.
        try await store.upsert(entity: Entity(
            id: "n2", kind: .note,
            title: """
            ## The flat

            Three things settled it in the end:

            - the **light** in the front room
            - the walk to Marco's, which is nine minutes
            - that I stopped arguing with myself about it

            > Still going to miss the balcony.
            """,
            detail: nil, dueAt: nil, confidence: 1, source: .authored,
            createdAt: now.addingTimeInterval(-3_600), updatedAt: now.addingTimeInterval(-3_600)
        ))

        // Three notes read out of a vault folder: authored, but with a capture behind each. These
        // are what used to sit in the day's writing list looking exactly like a journal entry.
        for title in ["Architecture", "Launch Copy", "Competitive Landscape"] {
            let noteID = MemoryText.stableID("entity", EntityKind.note.rawValue,
                                             MemoryText.normalizedTitle(title))
            let capture = CaptureEvent(
                id: "vaultcap-\(noteID)", ts: now,
                appBundleID: VaultImporter.bundleID, appName: VaultImporter.appName,
                windowTitle: title, text: "the body of \(title)", textHash: "vh-\(noteID)"
            )
            try await store.insert(capture: capture)
            try await store.upsert(entity: Entity(
                id: noteID, kind: .note, title: title, detail: nil, dueAt: nil,
                confidence: 0.95, source: .authored, createdAt: now, updatedAt: now
            ))
            try await store.add(provenance: Provenance(
                entityID: noteID, captureID: capture.id, field: "title", snippet: title, ts: now
            ))
        }

        // Sessions, so the day has hours to report. The calendar's log line is absent without
        // them, which would make a snapshot of it a picture of a case that rarely happens.
        let dayStart = Calendar.current.startOfDay(for: now)
        for (offset, app) in [(3.0, "Google Chrome"), (5.0, "Xcode"), (7.5, "Google Chrome")] {
            let start = dayStart.addingTimeInterval(offset * 3_600)
            try await store.upsert(session: Session(
                appBundleID: app == "Xcode" ? "com.apple.dt.Xcode" : "com.google.Chrome",
                appName: app,
                startedAt: start,
                endedAt: min(now, start.addingTimeInterval(app == "Xcode" ? 4_200 : 2_700))
            ))
        }
        return store
    }

    private func render(_ view: some View, width: CGFloat, height: CGFloat, name: String) throws {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(Theme.bg))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let dir = ProcessInfo.processInfo.environment["MEMOIR_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        #expect(png.count > 3_000, "\(name) rendered almost nothing")
        print("pane snapshot: \(url.path)")
    }

    @Test("the portrait draws people, weighted, with what it can say about one")
    func portrait() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try await seeded(dir)
        let shell = try ShellModel.forPreview(store: store)
        await shell.portrait.reload()
        #expect(!shell.portrait.figures.isEmpty, "seeded people did not reach the portrait")

        // The noise must not be drawn.
        let drawn = shell.portrait.figures.map(\.entity.title)
        for junk in ["typescript", "framer", "shadcn", "nordlysfoto", "Vector Art"] {
            #expect(!drawn.contains(junk), "\(junk) was seen on one page and should not be drawn")
        }
        #expect(shell.portrait.uncorroborated >= 5, "the dropped names should be counted, not hidden")
        #expect(!shell.portrait.ties.isEmpty, "people sharing captures should be tied together")

        if let marco = shell.portrait.figures.first(where: { $0.entity.title.contains("Marco") }) {
            await shell.portrait.select(marco)
            let reading = shell.portrait.reading
            #expect(reading?.commitments.isEmpty == false, "a commitment naming Marco should attach")
            #expect(reading?.lines.isEmpty == false, "the panel should lead with sentences")
            // The whole complaint: 81 sightings carrying 3 sentences must show 3 rows.
            let texts = (reading?.quotes ?? []).map(\.snippet)
            #expect(texts.count == Set(texts).count, "the same sentence was shown more than once")
            #expect(reading?.alongside.isEmpty == false, "Marco shares captures with Elena and Pawel")
        }
        try render(PortraitPane(model: shell.portrait), width: 560, height: 330, name: "pane-portrait")
        // And the panel on its own, which the pane's ScrollView hides from the renderer.
        if let reading = shell.portrait.reading {
            try render(PortraitReading(reading: reading), width: 232, height: 330, name: "pane-portrait-reading")
        }
        await store.close()
    }

    @Test("the day shows what was written beside what was noticed")
    func journal() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try await seeded(dir)
        let shell = try ShellModel.forPreview(store: store)

        await shell.calendar.reload()
        #expect(shell.calendar.entryCounts.values.reduce(0, +) > 0, "the month grid has nothing to shade")
        #expect(shell.calendar.trackedMinutes > 0, "the day has no hours, so the log line is absent")
        #expect(shell.calendar.entries.contains { $0.title.contains("**light**") },
                "the markdown entry did not reach the day")
        #expect(shell.calendar.entries.count == 2, "an imported note leaked into the journal")
        #expect(shell.calendar.picked.count == 3, "the imported notes did not reach the day's log")
        try render(CalendarPane(model: shell.calendar), width: 700, height: 400, name: "pane-calendar")
        // And the day column on its own, which the pane's ScrollView hides from the renderer:
        // the half where the log line, the entries and their typography actually live.
        try render(DayHead(model: shell.calendar), width: 500, height: 190, name: "pane-day-head")
        try render(CalendarDay(model: shell.calendar), width: 500, height: 330, name: "pane-calendar-day")
        await store.close()
    }
}

// MARK: - Correcting the record by hand

@MainActor
struct PortraitCorrectionTests {

    /// The model pass cannot run on a machine whose on-device model fails every generation,
    /// which is the machine this was written on. One click has to be enough.
    @Test("dismissing a name removes it from the constellation and keeps it gone")
    func dismissRemoves() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dismiss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try Store(path: dir.appendingPathComponent("t.sqlite"), mayMigrate: true)
        let now = Date()
        for name in ["Elena Duarte", "Dynamic Island"] {
            let id = MemoryText.stableID("entity", EntityKind.person.rawValue,
                                         MemoryText.normalizedTitle(name))
            try await store.upsert(entity: Entity(
                id: id, kind: .person, title: name, detail: nil, dueAt: nil,
                confidence: 0.99, source: .inferred, createdAt: now, updatedAt: now))
            for page in 0..<2 {
                for sentence in 0..<2 {
                    let capture = CaptureEvent(
                        id: "c-\(id)-\(page)-\(sentence)", ts: now,
                        appBundleID: "com.google.Chrome", appName: "Google Chrome",
                        windowTitle: "\(name) window \(page)", text: "text",
                        textHash: "h-\(id)-\(page)-\(sentence)")
                    try await store.insert(capture: capture)
                    try await store.add(provenance: Provenance(
                        entityID: id, captureID: capture.id, field: "title",
                        snippet: "\(name) said thing \(sentence)", ts: now))
                }
            }
        }

        let shell = try ShellModel.forPreview(store: store)
        await shell.portrait.reload()
        #expect(shell.portrait.figures.count == 2)

        let wrong = try #require(shell.portrait.figures.first { $0.entity.title == "Dynamic Island" })
        await shell.portrait.dismiss(wrong)

        #expect(shell.portrait.figures.map(\.entity.title) == ["Elena Duarte"])
        // And it stays gone across a reload, rather than being hidden in the view.
        await shell.portrait.reload()
        #expect(!shell.portrait.figures.contains { $0.entity.title == "Dynamic Island" })
        await store.close()
    }
}
