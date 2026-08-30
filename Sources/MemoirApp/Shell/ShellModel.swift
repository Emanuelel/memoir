import Combine
import SwiftUI
import MemoirKit

/// The hub every shell surface observes: which pane is selected, what shape the band
/// is in, the one number the strip shows, and the moment queue.
///
/// The band is the same object as the notch (it widens and drops, it never becomes a
/// window), so this model deliberately has no notion of "windows": it has a mode, and
/// the panel renders whatever the mode says.
@MainActor
final class ShellModel: ObservableObject {

    // MARK: - Types

    /// Every pane the shell can show. The band carries the first four; Memories and
    /// Settings are things a band can't hold and live in the promoted window.
    /// What the band can show.
    ///
    /// `ask` sits low because the MCP already
    /// answers questions inside whatever agent somebody already has open, and a chat box in a
    /// 560pt strip competes with that and loses. See ``PaneID/bandTabs`` for the order.
    ///
    /// `todos` is gone. Commitments still exist and still matter (they are the first of the
    /// three sentences this product is for), but they belong to the person they were made to,
    /// which is where they now appear.
    enum PaneID: String, CaseIterable {
        case portrait, journal, ask, memories, settings
        /// Reading: any day, chosen from a month grid.
        ///
        /// The raw value stays `"today"` on purpose: it is the key a saved tab preference was
        /// written under, and changing it would silently drop every existing user back to the
        /// portrait on their next launch.
        case calendar = "today"

        var inBand: Bool {
            switch self {
            case .portrait, .calendar, .ask: return true
            // `journal` is no longer a tab. Writing happens on the day you are looking at, in
            // the Calendar, which is what makes writing about a past day possible at all. The
            // case stays so a saved preference naming it still decodes; `inBand` sends it home.
            case .journal, .memories, .settings: return false
            }
        }

        /// The tabs, left to right, in both the band strip and the window sidebar.
        ///
        /// Written out rather than derived from `allCases`, because the declaration order is
        /// pinned by the raw values and reordering the cases would be a migration, not a
        /// layout change. Calendar leads: it is the day you are in, and every other tab is
        /// something you go to from there.
        static let bandTabs: [PaneID] = [.calendar, .ask, .portrait]

        /// Where the shell goes when nothing has been chosen yet. The first tab, so the
        /// nav and the landing agree.
        static var home: PaneID { bandTabs[0] }

        var title: String {
            switch self {
            case .portrait: return "People"
            case .journal: return "Journal"
            case .calendar: return "Calendar"
            case .ask: return "Ask"
            case .memories: return "Memories"
            case .settings: return "Settings"
            }
        }
    }

    /// A transient auto-widening of the collapsed band. Speech, a nudge, or a save
    /// receipt. One at a time, queued, and only while collapsed: an open band already
    /// has the user's attention.
    enum BandMoment: Equatable {
        case speech(String, Expression)
        case nudge(Nudge)
        case saved(title: String, due: Date?)
        /// Capture started or stopped. The one moment that is about Memoir itself.
        case health(CaptureHealth, String)
        /// A newer Memoir exists. Tapping opens the download page; nothing installs itself.
        case update(UpdateCheck.Release)

        /// How long the moment holds before the band settles back.
        var dwell: TimeInterval {
            switch self {
            case .speech(let text, _): return min(9, max(4, Double(text.count) / 14))
            case .nudge: return 8
            case .saved: return 4
            // Twice as long as anything else, because it is the only sentence in this app
            // that a user cannot afford to have scrolled past while looking elsewhere.
            case .health(let health, _): return health.isHealthy ? 5 : 16
            // Long, because it is the only moment whose whole purpose is to be acted on
            // later: a user who misses it does not hear about the fix again until tomorrow.
            case .update: return 12
            }
        }

        /// Whether this moment jumps the queue and interrupts whatever is on screen.
        var isUrgent: Bool {
            if case .health(let health, _) = self { return !health.isHealthy }
            return false
        }
    }

    enum Mode: Equatable {
        case collapsed
        case moment(BandMoment)
        case open
    }

    // MARK: - Published state

    @Published private(set) var mode: Mode = .collapsed
    @Published var pane: PaneID {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey) }
    }
    @Published private(set) var hasAccessibility: Bool
    /// Mirrors the capture-paused config so the right-click menu can label itself.
    @Published private(set) var capturePaused: Bool = false
    /// What capture is actually doing, measured rather than assumed. Drives the strip.
    @Published private(set) var health: CaptureHealth = .starting
    /// "Paused · 42m", when a pause is running down. The countdown is the reassurance: a pause
    /// that shows its own end is a pause nobody has to remember they set.
    @Published private(set) var pauseLabel: String?
    /// True while the promoted window is on screen, so the strip's control flips from
    /// "open as a window" to "come back to the band" instead of lying.
    @Published private(set) var isPromoted: Bool = false
    /// How many times the band has been opened, for the coach-mark fade.
    @Published private(set) var openCount: Int

    // MARK: - Wiring

    // Internal so the pane models can read the same services without re-plumbing.
    let store: Store
    let memory: MemoryService
    let character: CharacterModel
    let chat: ChatController
    /// Invoked by the ⤢ control and the window-only panes. The app delegate owns
    /// what "promote" means so the shell stays window-free.
    /// The two panes that own state worth keeping across an open and a collapse.
    ///
    /// Lazy so nothing queries the database until somebody actually looks at them, and held
    /// here rather than made per-view so that reopening the band does not throw away a
    /// selected person or a half-written journal entry.
    lazy var portrait = PortraitModel(shell: self)
    /// Held here for the same reason, and it was not at first: `CalendarPane` owned its own
    /// `@StateObject`, so which day you were reading was per-view state. That broke the rule
    /// above twice over: reopening the band could throw away the day you had navigated to, and
    /// nothing outside the view could reach the selection, so "show me today" from the ask bar
    /// opened the pane still showing August 2019.
    lazy var calendar = CalendarModel(shell: self)

    /// A shell with only what the panes need, for rendering one in isolation.
    ///
    /// The band normally hangs off a running app: a character, a chat controller, a notch. None of that is required to draw a list of people, and requiring it
    /// would mean the panes could only ever be looked at by launching the whole product and
    /// arranging for the right data to exist, which is how a pane ends up shipping with an
    /// empty state nobody checked.
    static func forPreview(store: Store) throws -> ShellModel {
        let memory = MemoryService(store: store, extractors: [])
        let character = CharacterModel(reduceMotion: true)
        let chat = ChatController(voice: .init(), push: nil, character: character) { _ in nil }
        return ShellModel(
            store: store, memory: memory, character: character, chat: chat,
            hasAccessibility: true
        )
    }

    var onPromote: (@MainActor (PaneID) -> Void)?

    /// Opens Settings **on a named pane**, for a link that is pointing at one switch.
    ///
    /// Distinct from `onPromote(.settings)`, which lands on whatever pane Settings opened on
    /// last. The difference matters wherever the app offers a capability the user has not
    /// found yet: sending them to a window with eight tabs and letting them hunt is the same
    /// as not offering it. Found by doing exactly that: the journal's weather link opened
    /// Settings on Capture, one tab away from the switch it was talking about.
    var onOpenSettings: (@MainActor (SettingsSection) -> Void)?
    /// Invoked when a nudge moment is explicitly dismissed with ✕.
    var onNudgeDismissed: (@MainActor (Nudge) -> Void)?
    /// The right-click menu's verbs, owned by the app delegate.
    var onTogglePause: (@MainActor () -> Void)?
    var onGrantPermission: (@MainActor () -> Void)?
    /// Sends the window away and brings the band back.
    var onDemote: (@MainActor () -> Void)?

    private var momentQueue: [BandMoment] = []
    private var momentTask: Task<Void, Never>?
    private var speechSink: AnyCancellable?

    private static let paneKey = "memoir.pane.selected"
    private static let openCountKey = "memoir.band.openCount"
    /// The coach mark retires itself after this many opens.
    static let coachMarkOpens = 5

    // MARK: - Init

    init(
        store: Store,
        memory: MemoryService,
        character: CharacterModel,
        chat: ChatController,
        hasAccessibility: Bool
    ) {
        self.store = store
        self.memory = memory
        self.character = character
        self.chat = chat
        self.hasAccessibility = hasAccessibility
        let saved = UserDefaults.standard.string(forKey: Self.paneKey).flatMap(PaneID.init(rawValue:))
        // First run lands on the first tab; afterwards the nav remembers where you were.
        // Home is the day, not the constellation: the calendar is what the tabs open with
        // and it is the one pane that means something before any memory has accumulated.
        self.pane = (saved?.inBand == true ? saved! : PaneID.home)
        self.openCount = UserDefaults.standard.integer(forKey: Self.openCountKey)

        // The character says things; the collapsed band is where they appear now.
        // Dropping speech while the band is open is intentional: the face is right
        // there in the strip and the panes carry the actual content.
        speechSink = character.$speech
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                self.presentMoment(.speech(text, self.character.expression))
            }

    }

    /// Detaches timers and observers. Deinit cannot touch main-actor state.
    func invalidate() {
        momentTask?.cancel()
        speechSink?.cancel()
    }

    // MARK: - Mode transitions

    var isOpen: Bool { mode == .open }

    /// ⌥Space. Opens onto the remembered pane, or collapses.
    func toggleOpen() {
        if case .open = mode { collapse() } else { open(pane: pane) }
    }

    /// Opens the band on a pane. A non-band pane promotes to the window instead.
    /// Opens the calendar **on today**, which is what every "today" phrasing means.
    ///
    /// A separate entry point rather than a flag on `open(pane:)`: opening the calendar because
    /// the user clicked the tab must keep whatever day they were reading, and opening it because
    /// they asked for today must not. Same pane, two different intents.
    func openToday() {
        calendar.select(Date())
        open(pane: .calendar)
    }

    func open(pane target: PaneID) {
        guard target.inBand else {
            onPromote?(target)
            return
        }
        pane = target
        momentTask?.cancel()
        momentQueue.removeAll()
        withAnimation(Self.spring) { mode = .open }
        openCount += 1
        UserDefaults.standard.set(openCount, forKey: Self.openCountKey)
        chat.bandDidOpen()
    }

    /// Esc / ⌥Space. Always stops the microphone; never clears the transcript.
    func collapse() {
        chat.stopVoice()
        withAnimation(Self.spring) { mode = .collapsed }
        drainMoments()
    }

    /// True while the coach-mark hint should still be taught.
    var showsCoachMark: Bool { openCount > 0 && openCount <= Self.coachMarkOpens }

    // MARK: - Moments

    /// Queues a transient widening of the collapsed band. Ignored while open.
    ///
    /// Urgent moments (capture stopping) go to the *front* and cut in front of whatever is
    /// currently showing. A queue is the right shape for pleasantries and the wrong shape for
    /// an alarm: "your memory has stopped" waiting politely behind a save receipt is how a
    /// warning ends up never seen.
    func presentMoment(_ moment: BandMoment) {
        guard mode != .open else { return }
        if moment.isUrgent {
            momentQueue.removeAll { if case .health = $0 { return true } else { return false } }
            momentQueue.insert(moment, at: 0)
            momentTask?.cancel()
            if case .moment = mode {
                withAnimation(Self.spring) { mode = .collapsed }
            }
        } else {
            momentQueue.append(moment)
        }
        drainMoments()
    }

    /// Explicit ✕ on a nudge moment: records the dismissal and settles the band.
    /// Letting a moment fade records nothing; the cooldown already prevents re-spam.
    func dismissCurrentMoment() {
        if case .moment(.nudge(let nudge)) = mode {
            onNudgeDismissed?(nudge)
        }
        momentTask?.cancel()
        withAnimation(Self.spring) { mode = .collapsed }
        momentTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.drainMoments()
        }
    }

    /// Tapping a moment opens the band on the thing it was about.
    func activateCurrentMoment() {
        guard case .moment(let moment) = mode else { return }
        switch moment {
        case .nudge: open(pane: .portrait)
        // A saved entry is a day's entry, and the day is where it now appears.
        case .saved: openToday()
        case .speech: open(pane: pane)
        // Tapping the alarm goes where the fix is, not where the news was.
        case .health(let health, _):
            if case .blocked(.accessibility) = health { onGrantPermission?() } else { onPromote?(.settings) }
        // Opens the page in the browser. Memoir never fetches the download itself: see
        // `UpdateCheck` for why nothing in this app is allowed to replace its own binary.
        case .update(let release):
            NSWorkspace.shared.open(release.url)
        }
    }

    /// Shows the next queued moment, but only from a settled collapsed band: an open
    /// band or a moment already on screen keeps the queue waiting.
    private func drainMoments() {
        guard mode == .collapsed, !momentQueue.isEmpty else { return }
        let next = momentQueue.removeFirst()
        withAnimation(Self.spring) { mode = .moment(next) }
        momentTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.dwell))
            guard !Task.isCancelled else { return }
            guard let self, case .moment = self.mode else { return }
            withAnimation(Self.spring) { self.mode = .collapsed }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self.drainMoments()
        }
    }

    func setAccessibility(_ granted: Bool) {
        hasAccessibility = granted
    }

    func setCapturePaused(_ paused: Bool) {
        capturePaused = paused
    }

    func setHealth(_ new: CaptureHealth) {
        health = new
    }

    func setPauseLabel(_ label: String?) {
        pauseLabel = label
    }

    /// What the user chose, for the menu and Settings to tick.
    var onPauseFor: (@MainActor (CapturePause) -> Void)?
    var onResume: (@MainActor () -> Void)?

    func setPromoted(_ promoted: Bool) {
        isPromoted = promoted
    }

    // MARK: - Motion

    /// The one spring every band transition uses. Reduce Motion flattens it.
    static var spring: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : .spring(response: 0.38, dampingFraction: 0.82)
    }
}
