import SwiftUI
import MemoirKit

/// The home of the band: your memory, drawn as the people in it and how they connect.
///
/// ## Three things this had to get right, and got wrong first
///
/// **Most "people" are not people.** Measured on a real database: 261 of them, of whom 196
/// appeared on exactly one web page and never again. `typescript`, `framer` and `torvend`
/// were scraped off one component library's marketing site; `nordlysfoto` off a directory of
/// wedding venues. A name on a page you looked at once is not somebody you know, so this asks
/// for corroboration before it draws anybody.
///
/// **Repetition is not evidence.** Marco had seventy sightings carrying three distinct
/// sentences, because the same chat window was read seventy times. Counting sightings ranked
/// a page that never changed above a person who wrote to you twice, and the panel showed the
/// same line six times over. Everything here counts *distinct* text.
///
/// **A scatter of unconnected dots says nothing.** The first version placed people on a spiral
/// by rank, which is a list pretending to be a picture. Two people who turn up in the same
/// capture are connected in the record, and that is a real edge. So the layout is a force
/// simulation and what you see is who clusters with whom.
@MainActor
final class PortraitModel: ObservableObject {

    /// One person, with only what the record can corroborate.
    struct Figure: Identifiable, Equatable {
        let entity: Entity
        let evidence: Store.Corroboration
        var x: Double = 0
        var y: Double = 0

        var id: ID { entity.id }

        /// 0 when they have gone quiet, 1 when they are in your week.
        var presence: Double {
            guard let last = evidence.lastSeen else { return 0.12 }
            let days = Date().timeIntervalSince(last) / 86_400
            if days <= 7 { return 1.0 }
            if days >= 180 { return 0.14 }
            return max(0.14, 1.0 - (days - 7) / 173 * 0.86)
        }

        /// How much there is to say, which is what makes a node worth being big.
        var weight: Double { Double(min(evidence.distinctSnippets, 24)) }
    }

    /// Two people the record has seen in the same place.
    struct Tie: Identifiable, Equatable {
        let a: ID
        let b: ID
        /// How many distinct captures hold them both.
        let together: Int
        var id: String { a + "·" + b }
    }

    /// What Memoir can say about somebody, as sentences rather than a log.
    struct Reading: Equatable {
        let figure: Figure
        /// One or two lines that are actually about the person.
        let lines: [String]
        /// Distinct quotes, newest first. Never the same sentence twice.
        let quotes: [Provenance]
        let commitments: [Entity]
        /// People who keep turning up alongside them.
        let alongside: [String]
    }

    @Published private(set) var figures: [Figure] = []
    @Published private(set) var ties: [Tie] = []
    @Published private(set) var reading: Reading?
    @Published private(set) var loaded = false
    /// Names the record holds but cannot corroborate. Counted and said out loud rather than
    /// quietly dropped, because hiding the shape of your own data is what everyone else does.
    @Published private(set) var uncorroborated = 0

    private let shell: ShellModel

    init(shell: ShellModel) { self.shell = shell }

    /// A name earns a place when the record saw it somewhere other than a single page.
    ///
    /// Two distinct window titles is the whole rule, plus the usual exemptions: anything the
    /// user wrote, corrected or pinned is theirs and is never second-guessed. It removes three
    /// quarters of the noise without a blocklist, and without deleting a row: the memory still
    /// holds every name, this only decides what is worth drawing.
    static func isCorroborated(_ entity: Entity, _ evidence: Store.Corroboration) -> Bool {
        if entity.source == .authored || entity.corrected || entity.pinned { return true }
        if looksLikeAHandle(entity.title) { return false }
        return evidence.pages >= 2 && evidence.distinctSnippets >= 2
    }

    /// A username is not a name.
    ///
    /// `quillnorth`, `marek_vance`, `kt7742`, `heypixly`. 206 of 261 "people" on the
    /// database this was measured against were single-token handles lifted off web pages,
    /// which is not how anybody refers to somebody they know. A real name arrives with a
    /// capital and usually with a surname; the exceptions people actually use (Mum, Marco)
    /// are capitalised single words, and those still pass.
    ///
    /// Only ever applied to inferred names. Anything the user typed, corrected or imported
    /// from their own contacts is theirs, whatever it looks like.
    static func looksLikeAHandle(_ title: String) -> Bool {
        guard !title.contains(" ") else { return false }
        if title.contains(where: \.isNumber) { return true }
        if title.contains("_") { return true }
        return title == title.lowercased()
    }

    func reload() async {
        let store = shell.store
        let people = (try? await store.entities(kind: .person, includeDeleted: false)) ?? []
        let evidence = (try? await store.corroboration(kind: .person)) ?? [:]

        var built: [Figure] = []
        var dropped = 0
        for person in people {
            guard let mine = evidence[person.id] else { dropped += 1; continue }
            guard Self.isCorroborated(person, mine) else { dropped += 1; continue }
            built.append(Figure(entity: person, evidence: mine))
        }

        built.sort { ($0.presence, $0.weight) > ($1.presence, $1.weight) }
        built = Array(built.prefix(28))

        let links = await Self.ties(among: built, store: store)
        Self.settle(&built, ties: links)

        figures = built
        ties = links
        uncorroborated = dropped
        loaded = true

        if let id = reading?.figure.id, let again = built.first(where: { $0.id == id }) {
            await select(again)
        }
    }

    // MARK: Ties

    /// Who shares a capture with whom.
    ///
    /// This is the only honest edge available. There is no relationship table and inventing
    /// one from name proximity in prose would be a guess presented as a fact. Two names quoted
    /// from the same capture were genuinely on screen together, which is a small claim and a
    /// true one.
    static func ties(among figures: [Figure], store: Store) async -> [Tie] {
        var capturesByPerson: [ID: Set<ID>] = [:]
        for figure in figures {
            let rows = (try? await store.provenance(entityID: figure.id)) ?? []
            capturesByPerson[figure.id] = Set(rows.map(\.captureID))
        }

        var out: [Tie] = []
        for i in figures.indices {
            for j in (i + 1)..<figures.count {
                let a = figures[i].id, b = figures[j].id
                let shared = (capturesByPerson[a] ?? []).intersection(capturesByPerson[b] ?? []).count
                // Once is a coincidence: two names on one page. Twice is a pattern.
                if shared >= 2 { out.append(Tie(a: a, b: b, together: shared)) }
            }
        }
        return out
    }

    // MARK: Layout

    /// A small force simulation: ties pull, everything pushes, the centre holds.
    ///
    /// Run to completion once at load rather than animated every frame. The band is not a
    /// physics toy and a graph that drifts while you are trying to click it is a worse
    /// experience than one that simply is where you left it. Seeded from the index rather than
    /// randomly, so the same memory always draws the same picture.
    static func settle(_ figures: inout [Figure], ties: [Tie], iterations: Int = 320) {
        guard figures.count > 1 else {
            if !figures.isEmpty { figures[0].x = 0; figures[0].y = 0 }
            return
        }
        let index = Dictionary(uniqueKeysWithValues: figures.enumerated().map { ($1.id, $0) })

        // Deterministic starting ring, so the simulation always begins from the same place.
        let golden = Double.pi * (3 - 5.0.squareRoot())
        for i in figures.indices {
            let radius = (Double(i) / Double(figures.count)).squareRoot()
            figures[i].x = radius * cos(Double(i) * golden)
            figures[i].y = radius * sin(Double(i) * golden)
        }

        for step in 0..<iterations {
            let cooling = 1.0 - Double(step) / Double(iterations)
            var dx = [Double](repeating: 0, count: figures.count)
            var dy = [Double](repeating: 0, count: figures.count)

            // Everything repels everything, so names do not stack on top of each other.
            for i in figures.indices {
                for j in figures.indices where j != i {
                    var vx = figures[i].x - figures[j].x
                    var vy = figures[i].y - figures[j].y
                    var distance = (vx * vx + vy * vy).squareRoot()
                    if distance < 0.001 {
                        // Perfectly coincident points have no direction to separate along.
                        vx = Double(i - j) * 0.001; vy = 0.001; distance = 0.001
                    }
                    let push = 0.010 / (distance * distance)
                    dx[i] += vx / distance * push
                    dy[i] += vy / distance * push
                }
            }

            // Ties pull, harder the more often the two were seen together.
            for tie in ties {
                guard let i = index[tie.a], let j = index[tie.b] else { continue }
                let vx = figures[j].x - figures[i].x
                let vy = figures[j].y - figures[i].y
                let pull = 0.02 * min(Double(tie.together), 8) / 8
                dx[i] += vx * pull; dy[i] += vy * pull
                dx[j] -= vx * pull; dy[j] -= vy * pull
            }

            for i in figures.indices {
                // A gentle pull to the middle, or disconnected names drift off the edge.
                dx[i] -= figures[i].x * 0.012
                dy[i] -= figures[i].y * 0.012
                figures[i].x += dx[i] * cooling
                figures[i].y += dy[i] * cooling
            }
        }

        // Normalise into -1…1 so the view can place them without knowing any of this.
        let maxRadius = figures.map { max(abs($0.x), abs($0.y)) }.max() ?? 1
        guard maxRadius > 0 else { return }
        for i in figures.indices {
            figures[i].x /= maxRadius
            figures[i].y /= maxRadius
        }
    }

    // MARK: Reading

    func select(_ figure: Figure) async {
        let store = shell.store

        // Distinct text only. Seventy rows carrying three sentences is three things to show,
        // not seventy, and showing the same line six times was the loudest thing wrong with
        // the first version of this panel.
        var seen = Set<String>()
        let quotes = ((try? await store.provenance(entityID: figure.id)) ?? [])
            .sorted { $0.ts > $1.ts }
                        .filter {
                // Collapsed and lowercased, because the same sentence re-read arrives with
                // different surrounding whitespace each time.
                let key = $0.snippet.split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ").lowercased()
                return seen.insert(key).inserted
            }

        let names = ([figure.entity.title] + figure.entity.aliases)
            .map { $0.lowercased() }
            .filter { $0.count >= 3 }
        let open = ((try? await store.entities(kind: .commitment, includeDeleted: false)) ?? [])
            .filter { $0.completedAt == nil }
            .filter { commitment in
                let haystack = (commitment.title + " " + (commitment.detail ?? "")).lowercased()
                return names.contains { haystack.contains($0) }
            }

        let companions = ties
            .filter { $0.a == figure.id || $0.b == figure.id }
            .sorted { $0.together > $1.together }
            .compactMap { tie -> String? in
                let other = tie.a == figure.id ? tie.b : tie.a
                return figures.first(where: { $0.id == other })?.entity.title
            }

        reading = Reading(
            figure: figure,
            lines: Self.lines(for: figure, quotes: quotes.count),
            quotes: Array(quotes.prefix(4)),
            commitments: open,
            alongside: Array(companions.prefix(3))
        )
    }

    /// The sentences at the top of the panel.
    ///
    /// The point of the whole surface. A list of log rows is what the first version showed and
    /// it told you nothing you could not have got from search; these are small claims that are
    /// true, and are the shape of the thing this product exists to say.
    static func lines(for figure: Figure, quotes: Int) -> [String] {
        var out: [String] = []
        let e = figure.evidence

        if let last = e.lastSeen {
            let days = Int(Date().timeIntervalSince(last) / 86_400)
            switch days {
            case 0: out.append("Came up today.")
            case 1: out.append("Came up yesterday.")
            case 2...13: out.append("Last came up \(days) days ago.")
            case 14...59: out.append("Nothing since \(last.formatted(.dateTime.day().month(.wide))).")
            default: out.append("Nothing since \(last.formatted(.dateTime.month(.wide).year())).")
            }
        }

        if let first = e.firstSeen, let last = e.lastSeen,
           last.timeIntervalSince(first) > 86_400 * 21 {
            out.append("In the record since \(first.formatted(.dateTime.month(.wide).year())).")
        }

        // The honest version of a mention count. "Seen 70 times" is a lie told by a window
        // that was read 70 times; "3 things, across 6 places" is what actually happened.
        if quotes > 0 {
            let things = quotes == 1 ? "one thing" : "\(quotes) different things"
            let places = e.pages == 1 ? "one place" : "\(e.pages) places"
            out.append("\(things.prefix(1).capitalized)\(things.dropFirst()) said, across \(places).")
        }
        return out
    }

    /// Says that somebody in the constellation is not a person.
    ///
    /// The deterministic version of ``MemoryService/judgeUncertainPeople(limit:dryRun:judge:)``,
    /// and the one that works today: the on-device model reports itself available on this
    /// machine and then fails every generation, so the model pass currently retires nothing.
    /// One click per wrong name, and it stays gone.
    ///
    /// This is authored-beats-inferred, which is the oldest rule in the product. A soft delete,
    /// so the row and its provenance stay on disk and no extraction pass can resurrect it.
    ///
    /// `corrected: true` because a person decided this. Without it the row is indistinguishable
    /// from one a consolidation sweep retired, and the resurrection guard reads `corrected`.
    func dismiss(_ figure: Figure) async {
        let store = shell.store
        try? await store.deleteEntity(id: figure.id, corrected: true)
        reading = nil
        await reload()
    }

    func clearSelection() { reading = nil }
}

// MARK: - View

struct PortraitPane: View {
    @ObservedObject var model: PortraitModel
    @State private var hovered: ID?

    var body: some View {
        HStack(spacing: 0) {
            graph.frame(maxWidth: .infinity)
            if model.reading != nil {
                Theme.vHairline
                ScrollView {
                    PortraitReading(reading: model.reading!) {
                        let figure = model.reading!.figure
                        Task { await model.dismiss(figure) }
                    }
                }
                .frame(width: 236)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.reading)
        .task { await model.reload() }
    }

    // MARK: The graph

    private var graph: some View {
        GeometryReader { geo in
            ZStack {
                // Edges first, underneath, and dimmed unless they touch what you are looking
                // at: the Obsidian trick, and the reason a dense graph stays readable.
                Canvas { ctx, _ in
                    for tie in model.ties {
                        guard let a = model.figures.first(where: { $0.id == tie.a }),
                              let b = model.figures.first(where: { $0.id == tie.b }) else { continue }
                        let p1 = place(a, in: geo.size)
                        let p2 = place(b, in: geo.size)
                        var path = Path()
                        path.move(to: p1)
                        path.addLine(to: p2)

                        let focus = hovered ?? model.reading?.figure.id
                        let touches = focus == nil || focus == tie.a || focus == tie.b
                        let strength = min(Double(tie.together), 8) / 8
                        ctx.stroke(
                            path,
                            with: .color(Theme.accent.opacity(touches ? 0.10 + strength * 0.30 : 0.045)),
                            lineWidth: touches ? 0.6 + strength * 1.1 : 0.5
                        )
                    }
                }
                .allowsHitTesting(false)

                ForEach(model.figures) { figure in
                    let point = place(figure, in: geo.size)
                    Button {
                        Task { await model.select(figure) }
                    } label: {
                        FigureDot(
                            figure: figure,
                            selected: model.reading?.figure.id == figure.id,
                            dimmed: isDimmed(figure)
                        )
                    }
                    .buttonStyle(.plain)
                    .position(x: point.x, y: point.y)
                    .onHover { hovered = $0 ? figure.id : nil }
                }

                if model.loaded && model.figures.isEmpty { emptyState }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.clearSelection() }
            .overlay(alignment: .bottomLeading) { footnote }
        }
    }

    /// Everything not connected to what you are pointing at fades back.
    private func isDimmed(_ figure: PortraitModel.Figure) -> Bool {
        guard let focus = hovered ?? model.reading?.figure.id, focus != figure.id else { return false }
        return !model.ties.contains {
            ($0.a == focus && $0.b == figure.id) || ($0.b == focus && $0.a == figure.id)
        }
    }

    private func place(_ figure: PortraitModel.Figure, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2 + figure.x * size.width * 0.38,
            y: size.height / 2 + figure.y * size.height * 0.35
        )
    }

    /// What is not being drawn, said plainly.
    @ViewBuilder
    private var footnote: some View {
        if model.uncorroborated > 0 {
            Text("\(model.uncorroborated) names seen once, on one page, are not shown.")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.ghost)
                .padding(.leading, 12)
                .padding(.bottom, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Text("Nobody yet.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.memoirInk)
            Text("People appear here once the record has seen them somewhere more than once.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 26)
    }
}

/// What Memoir can say about one person: sentences first, evidence under them.
struct PortraitReading: View {
    let reading: PortraitModel.Reading
    /// Absent in previews and snapshots, where there is nothing to correct.
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(reading.figure.entity.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)

            // The sentences. This is the surface, and the log underneath is the footnote.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(reading.lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.memoirInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !reading.alongside.isEmpty {
                Text("Usually turns up with \(reading.alongside.joined(separator: ", ")).")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.memoirInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !reading.commitments.isEmpty {
                Theme.hairline
                Text("You said you would")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .tracking(0.6)
                ForEach(reading.commitments.prefix(3)) { c in
                    Text(c.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.memoirInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Theme.hairline
            if reading.quotes.isEmpty {
                Text("Nothing on record to quote.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
            } else {
                Text("In their own words")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .tracking(0.6)
                ForEach(reading.quotes) { quote in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quote.snippet)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.memoirInk)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(quote.ts.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Theme.ghost)
                    }
                }
            }

            if let onDismiss {
                Theme.hairline
                Button("Not a person") { onDismiss() }
                    .buttonStyle(PillButton(emphasis: .quiet))
                    .help("Removes it from here for good. The record keeps what it saw.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One point of light. Size carries how much there is to say, brightness how recent it is.
private struct FigureDot: View {
    let figure: PortraitModel.Figure
    let selected: Bool
    let dimmed: Bool

    private var diameter: CGFloat { 7 + CGFloat(figure.weight / 24) * 11 }

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(selected ? Theme.ink : Theme.accent)
                .frame(width: diameter, height: diameter)
                .opacity(selected ? 1 : (0.35 + figure.presence * 0.65) * (dimmed ? 0.28 : 1))
                .overlay {
                    if selected {
                        Circle().stroke(Theme.ink.opacity(0.3), lineWidth: 4).scaleEffect(1.75)
                    }
                }
            Text(figure.entity.title)
                .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.ink : Theme.dim)
                .opacity(dimmed ? 0.3 : 0.45 + figure.presence * 0.55)
                .lineLimit(1)
        }
        .animation(.easeInOut(duration: 0.16), value: selected)
        .animation(.easeInOut(duration: 0.16), value: dimmed)
    }
}
