import Combine
import Foundation
import SwiftUI
import MemoirKit

/// The state of first run, from the welcome to the point where nothing else is needed.
///
/// A flow rather than a screen, and an object rather than view state, because two of the
/// steps finish on their own schedule: Accessibility is granted in System Settings and
/// arrives back here through a poll, and every agent connection is written the moment it is
/// clicked. `AppDelegate` needs somewhere to deliver the first of those, and the view needs
/// somewhere to keep the rest while the window is being scrolled around.
@MainActor
final class OnboardingFlow: ObservableObject {

    /// First run is four screens: what this is, the one permission, the years you already
    /// have, done.
    ///
    /// It was seven, then three. Identity and agents were real settings wearing the costume of
    /// a setup step (gates in front of an app nobody had seen yet) and they stay in Settings,
    /// where they can also be changed. `history` came back, because it is not a setting. It is
    /// the difference between a memory that reaches back ten years and one that starts empty,
    /// and the only moment to offer it is the moment the user is already being asked for
    /// permissions. Declining is one click and costs nothing.
    /// `recovery` stays in the enum because it is still a screen, but ``applies(_:)`` keeps it
    /// out of first run: a spare key for an empty database is homework, and it is asked for on
    /// a later launch instead.
    /// Order is the order they appear in, and `recovery` sits before `ready` so the
    /// spare-key launch ends on "you're set" like every other one.
    enum Step: Int, CaseIterable {
        case welcome, permission, history, recovery, ready

        /// What the header says while this step is showing.
        var title: String {
            switch self {
            case .welcome: return "Ask your life a question"
            case .permission: return "One permission"
            case .history: return "Your life so far"
            case .ready: return "Ready"
            case .recovery: return "Your spare key"
            }
        }

        /// What the mark is doing here. Traits interpolate, so this costs one line and the
        /// change reads as one object moving rather than as four drawings.
        var expression: Expression {
            switch self {
            case .welcome: return .idle
            case .permission: return .alert
            // Something is waiting on the user, same as the permission before it: this screen
            // does nothing until a choice is made, and either choice is a fine one.
            case .history: return .alert
            case .ready: return .idle
            case .recovery: return .idle
            }
        }
    }

    @Published var step: Step = .welcome
    /// Set by the permission watcher in `AppDelegate`, not polled from in here.
    @Published var accessibilityGranted: Bool

    let recovery = RecoveryStep()
    let identity = IdentityStep()
    let history = HistoryStep()
    let connections = ConnectionsModel()

    /// How the user summons Memoir, rendered for the last step. Comes from the live config,
    /// so a rebound hotkey is taught correctly rather than as the factory default.
    let hotkeyLabel: String

    private let requestAccessibility: () -> Void
    private let finish: () -> Void
    private var relays: [AnyCancellable] = []

    init(
        accessibilityGranted: Bool,
        hotkeyLabel: String,
        requestAccessibility: @escaping () -> Void,
        finish: @escaping () -> Void
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.hotkeyLabel = hotkeyLabel
        self.requestAccessibility = requestAccessibility
        self.finish = finish

        // The footer reads `history.running` and `history.hasRun`, and a nested
        // `ObservableObject` does not republish through its owner. Without this the button
        // still says "Read them" while the import is running and after it has finished: the
        // work happens and the control lies about it.
        relays.append(history.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
    }

    var isFirst: Bool { step == .welcome }
    var isLast: Bool { step == .ready }

    /// What the forward button says.
    ///
    /// Always the thing that happens, never the thing the user failed to do. The old version
    /// renamed itself to "Continue without saving it", "Continue without it" and "Start empty
    /// instead". So the largest, most obvious control on the screen was a reprimand, and the
    /// good path had no button at all. Skipping is still allowed; it is a quiet link beside
    /// the action it declines, which is where an escape belongs.
    var forwardTitle: String {
        switch step {
        case .welcome: return "Start"
        // "Open Settings" over a permission that is already granted describes something the
        // button does not do: it moves on. The label follows the action, both ways.
        case .permission: return accessibilityGranted ? "Continue" : "Open Settings"
        // The import is the action, so it is the button, not a secondary control beside a
        // "Continue" that skips past it. Once it has run, or been refused, the same button
        // goes back to being the way forward.
        case .history:
            if history.running { return "Reading…" }
            return history.hasRun || history.declined ? "Continue" : "Read them"
        case .ready: return "Done"
        case .recovery: return "Save to a file"
        }
    }

    /// Whether the forward button is the emphasised one. It always is now: it is always the
    /// action, and never the skip.
    var forwardIsPrimary: Bool { true }

    /// The quiet way past this step, when there is one. Rendered as a link, not a button.
    var declineTitle: String? {
        switch step {
        case .permission: return accessibilityGranted ? nil : "Not now"
        case .history: return history.hasRun || history.declined ? nil : "Not now"
        case .recovery: return "Later"
        case .welcome, .ready: return nil
        }
    }

    /// "2 of 3", or nil when this launch is one errand rather than a sequence.
    var positionLabel: String? {
        guard !recoveryOnly else { return nil }
        let steps = applicableSteps
        guard steps.count > 1, let index = steps.firstIndex(of: step) else { return nil }
        return "\(index + 1) of \(steps.count)"
    }

    /// What the primary button does.
    ///
    /// Separate from ``forward()`` because on two of these screens the button is the action
    /// itself and advancing is a consequence of it: the permission step opens System
    /// Settings and then waits to be told, and the spare key step writes the file.
    func primaryAction() {
        switch step {
        case .permission:
            if accessibilityGranted { forward() } else { askForAccessibility() }
        case .history:
            // `run()` guards against a second press while it is working, so a hurried double
            // click does not start two imports.
            if history.hasRun || history.declined { forward() } else { history.run() }
        case .recovery:
            recovery.saveToFile()
            if recovery.saved { forward() }
        case .welcome, .ready:
            forward()
        }
    }

    func askForAccessibility() { requestAccessibility() }

    /// Whether a step has anything to say on this launch.
    ///
    /// The spare key is the only one that varies, and it is deliberately not part of first
    /// run: a key protecting an empty database is homework handed out before anything has
    /// happened. `recoveryOnly` is the launch that asks for it, once there is a memory worth
    /// the thirty seconds.
    func applies(_ candidate: Step) -> Bool {
        if recoveryOnly { return candidate == .recovery || candidate == .ready }
        switch candidate {
        case .recovery: return false
        default: return true
        }
    }

    /// Reopening first run for one reason only: this Mac has a recovery key nobody has kept.
    /// Marching an existing user back through permissions and imports to reach it would be
    /// worse than the problem.
    var recoveryOnly = false

    /// The steps this particular launch will actually show, in order.
    var applicableSteps: [Step] { Step.allCases.filter(applies) }

    func forward() {
        guard !isLast else { finish(); return }
        var next = Step(rawValue: step.rawValue + 1)
        while let candidate = next, !applies(candidate) {
            next = Step(rawValue: candidate.rawValue + 1)
        }
        guard let next else { finish(); return }
        withAnimation(ShellModel.spring) { step = next }
    }

    func back() {
        var previous = Step(rawValue: step.rawValue - 1)
        while let candidate = previous, !applies(candidate) {
            previous = Step(rawValue: candidate.rawValue - 1)
        }
        guard let previous else { return }
        withAnimation(ShellModel.spring) { step = previous }
    }

    /// Jumps straight to the end. The user who wants the app and not the tour.
    func skipToEnd() {
        withAnimation(ShellModel.spring) { step = .ready }
    }
}

// MARK: - The window

/// The body of whichever step is showing.
///
/// Split out of ``OnboardingView`` so it can be rendered on its own. `ImageRenderer` does not
/// lay out anything inside a `ScrollView` (it produces the chrome and an empty middle), so a
/// snapshot of the whole window silently shows nothing where the step should be. Every step is
/// reachable through this type instead, which is also the only way to look at one without
/// running first-run for real.
struct OnboardingStepContent: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch flow.step {
            case .welcome: WelcomeStep()
            case .permission: PermissionStep(flow: flow)
            case .history: HistoryStepView(step: flow.history)
            case .ready: ReadyStep(flow: flow)
            case .recovery: RecoveryStepView(step: flow.recovery)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// First run, in the shell's own language: black, hairlines, white pill for the action
/// that matters. The previous version was a single scrolling column of system controls,
/// which made the one screen a new user sees the one screen that looked like a different app.
struct OnboardingView: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        VStack(spacing: 0) {
            // Centred in the space that is actually left, not floated at the top of it.
            //
            // A `ScrollView` sizes its content to the content, so three short lines sat
            // against the top edge with two-thirds of the window empty underneath. The
            // minimum height is the viewport, so a short step centres and a long one still
            // scrolls.
            GeometryReader { geo in
                ScrollView(.vertical) {
                    OnboardingStepContent(flow: flow)
                        // The shell has no slide or push anywhere; things arrive and leave by
                        // fading. A stepper that pushed horizontally would be the only thing in
                        // the app that did.
                        .transition(.opacity)
                        .id(flow.step)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
            .frame(maxHeight: .infinity)

            Theme.hairline
            footer
        }
        .frame(width: 560, height: 620)
        .background(Theme.bg)
        // These steps borrow pane views built for the band, where body text is a size
        // smaller. This is a window.
        .environment(\.memoirSurface, .window)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // "2 of 3", not a row of capsules. The capsules were a position indicator that
            // nothing identified as one, so they read as decoration in the corner of every
            // screen. Three steps is a number worth simply printing.
            if let position = flow.positionLabel {
                Text(position)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.faint)
            }

            Spacer(minLength: 8)

            if let decline = flow.declineTitle {
                Button(decline) { flow.forward() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            if !flow.isFirst {
                Button("Back") { flow.back() }
                    .buttonStyle(PillButton(emphasis: .quiet))
            }
            Button(flow.forwardTitle) { flow.primaryAction() }
                .buttonStyle(PillButton(emphasis: .primary))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

// MARK: - The button

/// The shell's pill, as a button style: white fill for the action that matters, tile fill
/// for the one beside it, bare text for retreat.
struct PillButton: ButtonStyle {
    enum Emphasis { case primary, secondary, quiet }
    var emphasis: Emphasis = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // The closure form, not `.background(fill)`. The bare form prefers the
            // `ShapeStyle` overload, will not match an opaque `some View`, and the only
            // error it reports is that the whole style no longer conforms to `ButtonStyle`.
            .background { fill }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    @ViewBuilder private var fill: some View {
        switch emphasis {
        case .primary: Capsule().fill(Theme.ink)
        case .secondary: Capsule().fill(Theme.tile)
        case .quiet: Color.clear
        }
    }

    private var foreground: Color {
        switch emphasis {
        case .primary: return Theme.bg
        case .secondary: return Theme.ink
        case .quiet: return Theme.dim
        }
    }
}

/// A titled block with a body, used by every step so the rhythm never changes.
private struct Block<Content: View>: View {
    let icon: String
    let title: String
    var tint: Color = Theme.dim
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                content
            }
        }
    }
}

/// Body copy, at the one size the rest of the shell uses for it.
///
/// Not called `Body`: inside a `View` that name resolves to the protocol's own associated
/// type, and every use site fails with "type 'X.Body' has no member 'init'".
private struct Prose: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Steps

/// The first screen: the mark, the tagline, and one question at a time.
///
/// The tagline and the questions are the approved copy, not new writing. It converts because
/// the reader answers it with their own question rather than being handed a use case, and a
/// paragraph explaining what the product does underneath would take that back.
private struct WelcomeStep: View {

    /// From the unused prompt list. Personal, and none of them answerable today.
    private static let asks = [
        "What did my mother actually say about the house, three years on?",
        "What was the band I played on loop that winter?",
        "What did I promise, and to whom, and never do?",
    ]

    @State private var index = 0

    /// Three seconds. Long enough to read one, short enough that a second one arrives while
    /// somebody is still on the screen, which is the entire point of showing three.
    private let clock = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 30) {
            FoldMark(traits: Expression.idle.fold, gaze: .zero, blink: 0)
                .frame(width: 96, height: 106)

            Text("Ask your life a question.")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)

            Text(Self.asks[index])
                .font(.system(size: 19))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 58, alignment: .center)
                .padding(.horizontal, 30)
                .id(index)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 34)
        .onReceive(clock) { _ in
            withAnimation(.easeInOut(duration: 0.45)) {
                index = (index + 1) % Self.asks.count
            }
        }
    }
}


/// The recovery key, shown exactly once.
///
/// Auto-unlock is the right default (nobody should type a password to look at their own life),
/// but it means the memory is held by the login keychain, and a keychain does not survive a
/// wiped disk or a Mac that will not boot. This screen is the only thing standing between a
/// user and losing a decade, so it is deliberately the second thing they see.
@MainActor
final class RecoveryStep: ObservableObject {
    /// Present only on the launch that created the vault. Nil on every launch after, which is
    /// what makes the step skip itself.
    @Published private(set) var key: String?
    /// Set once the user has copied it or written it to a file. Not a promise that they kept
    /// it, only that they were given a real chance to.
    @Published private(set) var saved = false
    @Published private(set) var note: String?

    init(key: String? = nil) { self.key = key }

    /// Takes the key from the launch that created it, or failing that reads the one already in
    /// the keychain.
    ///
    /// The second half is the fix. The first version only ever received a key from the launch
    /// that minted it, so a relaunch, or an upgrade that skips first run because this Mac was
    /// already set up, meant the only thing that can recover a decade of somebody's memory was
    /// created and never shown to anybody.
    func adopt(_ recoveryKey: String?) {
        key = recoveryKey ?? (try? VaultKey.recoveryKey())
    }

    /// Written down. Nothing offers the key again after this.
    private func markKept() {
        saved = true
        var config = AppConfig.load()
        config.recoveryKeyAcknowledged = true
        config.save()
    }

    /// Puts it on the clipboard, and does **not** count that as having kept it.
    ///
    /// It used to call ``markKept()``, which set `recoveryKeyAcknowledged` and retired the
    /// offer for good. A clipboard is not somewhere a key is kept (copy anything else and it
    /// is gone), so that one line could leave somebody holding nothing, with the screen that
    /// would have shown it again permanently switched off. Only a written file counts.
    func copyToClipboard() {
        guard let key else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        note = "Copied. Paste it somewhere that is not this Mac. The clipboard doesn't count as kept."
    }

    /// Writes it to a file the user chooses. Plain text on purpose: a recovery key inside a
    /// format that needs an app to open it is a recovery key you cannot read on the day you
    /// need it.
    func saveToFile() {
        guard let key else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Memoir recovery key.txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Somewhere that is not this Mac: a printer, another machine, a safe."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = """
        Memoir recovery key

        \(key)

        This unlocks your Memoir memory if this Mac is lost, wiped, or will not start.
        Without it, and without this Mac, the memory cannot be opened by anyone, including us.
        Keep it somewhere that is not this Mac.
        """
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            markKept()
            note = "Saved to \(url.lastPathComponent)."
        } catch {
            note = "Could not write that file: \(error.localizedDescription)"
        }
    }
}

/// The spare key: what it opens, and where to find it again.
///
/// It is a spare key rather than a "recovery key" because that is a thing people already own
/// and already know what to do with, and because the old screen read as a warning: a wall of
/// consequences for a decision the user had not been given the means to make yet.
private struct RecoveryStepView: View {
    @ObservedObject var step: RecoveryStep

    var body: some View {
        VStack(spacing: 24) {
            Text("Your spare key.")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.ink)

            if let key = step.key {
                Text(key)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Theme.markPaper)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: Theme.rTile).fill(Theme.tile))
            }

            VStack(spacing: 6) {
                Text("If this Mac is ever lost or wiped, this key opens your memory again.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.dim)
                Text("Keep it somewhere else. You can find it again in Settings › Data.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.faint)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button("Copy") { step.copyToClipboard() }
                .buttonStyle(PillButton(emphasis: .secondary))

            if let note = step.note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(step.saved ? Theme.good : Theme.dim)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 34)
    }
}

/// Reading Contacts, Calendar and Photos, so the memory does not start empty.
///
/// One button for all three. Three separate system prompts still appear (that is TCC's
/// decision, not ours), but the user makes one choice, not a sequence of them.
@MainActor
final class HistoryStep: ObservableObject {
    /// Nil until a pass has run. Non-nil is the whole "did this work" signal.
    @Published private(set) var summary: LifeImporter.Summary?
    @Published private(set) var running = false
    /// Set when every source was declined, so the step can say so rather than look broken.
    @Published private(set) var declined = false
    /// What macOS is withholding, re-read after every attempt. Non-empty on a partial import
    /// too: two sources granted and one refused is still a switch the user has to be shown,
    /// and it used to disappear behind the success count.
    @Published private(set) var withheld: [LifeImporter.Source] = []

    var hasRun: Bool { summary != nil }

    /// Where the memory service comes from. Injected rather than reached for, because this
    /// step is built before the service exists and the rest of the flow already works this way.
    var provideMemory: () -> MemoryService? = { nil }

    /// The single click. Asks for both permissions, imports whatever was allowed, and never
    /// treats a refusal as an error: a user who says no to Contacts still gets the calendar.
    func run() {
        guard !running, let memory = provideMemory() else { return }
        running = true
        declined = false

        Task { @MainActor in
            // All three asked back to back, so the user answers a row of dialogs once and is
            // never surprised by a fourth one later. Declining any of them is fine.
            let contacts = await LifeImporter.requestContactsAccess()
            let calendar = await LifeImporter.requestCalendarAccess()
            let photos = await LifeImporter.requestPhotosAccess()

            let sources = LifeImporter.Sources(contacts: contacts, calendar: calendar, photos: photos)
            // Recorded on every path, success included.
            withheld = LifeImporter.withheld

            guard !sources.isEmpty else {
                running = false
                declined = true
                return
            }
            // No `since`: the first pass is the decade.
            summary = try? await memory.importLife(sources: sources)
            running = false
        }
    }

    /// Re-reads the three grants without asking for anything. TCC never tells us it changed,
    /// so this is what makes the problem block disappear by itself after a trip to System
    /// Settings, the same trick the Vault pane uses.
    func refreshGrants() {
        guard hasRun || declined else { return }
        withheld = LifeImporter.withheld
    }
}

struct HistoryStepView: View {
    @ObservedObject var step: HistoryStep

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Capture can only know about today onwards. Your contacts, your calendar and your photo library already hold years of it: who is in your life, what you were doing, and where you keep going back to. Read them and your memory starts deep instead of empty. It keeps reading them afterwards, so it stays current on its own.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.memoirInk)
                .fixedSize(horizontal: false, vertical: true)

            Theme.hairline.padding(.vertical, 2)

            Block(icon: "person.2", title: "Contacts", tint: Theme.dim) {
                Prose("Names only. Not numbers, not addresses, not birthdays. Nothing is ever written back.")
            }
            Block(icon: "calendar", title: "Calendar", tint: Theme.dim) {
                Prose("What you were doing and who was there, up to ten years back. It never adds, changes or deletes an event. Google and Exchange calendars come through too, as long as the account is set up in the Mac's Calendar app.")
            }
            Block(icon: "photo.on.rectangle", title: "Photos", tint: Theme.dim) {
                Prose("Dates and rough locations only. Never a picture, not even a thumbnail. macOS has no way to ask for less than the whole library, so the dialog will sound broader than what is read. Screenshots are skipped.")
            }

            if let summary = step.summary {
                Block(icon: "checkmark.seal", title: "Done", tint: Theme.good) {
                    Prose(result(summary))
                }
            }

            // The same block Settings uses, deliberately: a refusal here used to end on "you
            // can turn any of these on later in Settings → Vault" and leave the user to go and
            // find it, while macOS, having recorded the refusal, had already stopped asking.
            // One button per withheld switch is the only thing that actually opens the door.
            if !step.withheld.isEmpty {
                WithheldBlock(
                    withheld: step.withheld,
                    readNothing: step.declined,
                    status: "",
                    open: { $0.openSettings() }
                )
            }

            if step.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your contacts, calendar and photos…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        // TCC changes are never published to us, so without this the block keeps naming a
        // switch the user has just flipped in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            step.refreshGrants()
        }
    }

    /// What the user actually wants to know: how far back it now goes.
    private func result(_ summary: LifeImporter.Summary) -> String {
        var parts: [String] = []
        if summary.peopleImported > 0 { parts.append("\(summary.peopleImported) people") }
        // "events", not "days": the row is one per calendar entry, and the number is shown to
        // the user, so it has to be called what it actually counts.
        if summary.eventsImported > 0 { parts.append("\(summary.eventsImported) calendar events") }
        if summary.photoDaysImported > 0 { parts.append("\(summary.photoDaysImported) days with photographs") }
        if summary.placesFound > 0 { parts.append("\(summary.placesFound) places you keep returning to") }
        guard !parts.isEmpty else { return "There was nothing to read. Your memory starts today." }

        let what = parts.joined(separator: " and ")
        guard let back = summary.reachesBackTo else { return "\(what.prefix(1).capitalized)\(what.dropFirst())." }
        let year = Calendar.current.component(.year, from: back)
        return "\(what.prefix(1).capitalized)\(what.dropFirst()). Your memory now reaches back to \(year)."
    }
}

/// The one permission, shown as the switch it actually is.
///
/// The row is a picture of the thing to do, in the place it appears, and it is also the
/// button that opens that place, one target rather than an illustration and a control. No
/// app may grant itself Accessibility, so opening the right pane is the most any of this can
/// do; the watcher in `AppDelegate` notices the grant and the step advances by itself.
private struct PermissionStep: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        VStack(spacing: 26) {
            Text(flow.accessibilityGranted ? "That's it." : "Turn this on.")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Button { flow.askForAccessibility() } label: {
                HStack(spacing: 13) {
                    FoldMark(traits: Expression.idle.fold, gaze: .zero, blink: 0)
                        .frame(width: 30, height: 34)
                    Text("Memoir")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    if !flow.accessibilityGranted {
                        Text("Open Settings ›")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                    }
                    AccessibilitySwitch(on: flow.accessibilityGranted)
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 15)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.tile))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(flow.accessibilityGranted ? Theme.line : Theme.accent, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(flow.accessibilityGranted)

            Text(flow.accessibilityGranted
                 ? "Memoir is reading your screen now."
                 : "It's the only permission Memoir ever asks for.")
                .font(.system(size: 16))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 34)
        .animation(ShellModel.spring, value: flow.accessibilityGranted)
    }
}

/// The macOS switch, drawn rather than borrowed, so it can show "off" while the real one is
/// off and settle to "on" the moment the grant lands.
private struct AccessibilitySwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Theme.good : Theme.line2)
            .frame(width: 50, height: 30)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                    .padding(.horizontal, 3)
            }
    }
}



private struct ReadyStep: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        VStack(spacing: 26) {
            Text("You're set.")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.ink)

            VStack(spacing: 10) {
                Text("Memoir is watching now.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.dim)
                HStack(spacing: 7) {
                    Text("Press")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.faint)
                    Text(flow.hotkeyLabel)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink))
                    Text("any time to ask it something.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.faint)
                }

                // Where to find it again.
                //
                // The one piece of the old ending worth keeping: Memoir has no dock icon and
                // no status item, so a user who closes this window and does not know about the
                // notch has no way back to their own settings. Everything else that screen
                // explained is discoverable from inside the app; this is the thing that makes
                // the app discoverable at all.
                Text("It lives in the notch, not the dock. Right-click it for settings.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            // The one offer worth making here, and the reason it is on the last screen
            // rather than a screen of its own: an agent that can read this memory is most of
            // why somebody installed it, and cutting the step meant first run stopped
            // mentioning it at all. Nothing is gated ("Done" is right there) and the
            // compact panel lists only clients actually on this Mac, so it is two rows on a
            // developer's machine and absent on everybody else's.
            if flow.connections.foundAnyClient {
                VStack(spacing: 12) {
                    Theme.hairline.padding(.vertical, 4)

                    Text("Let the agents you already use read it.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.dim)

                    ConnectionsPanel(model: flow.connections, compact: true)
                        .frame(maxWidth: 420)

                    Button("Install the skill") { flow.connections.installSkill() }
                        .buttonStyle(PillButton(emphasis: .secondary))

                    if let status = flow.connections.skillStatus {
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.faint)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 34)
    }
}


// MARK: - What people call you

/// The names the user is labelled by in chat apps, asked for once and saved as they type.
///
/// Saved on every add and every remove rather than behind a confirm button. That began as a
/// defence against this window closing itself the instant Accessibility arrived; the flow no
/// longer does that, but the property is worth keeping: a name typed and then abandoned by
/// closing the window is still a name the user meant.
@MainActor
final class IdentityStep: ObservableObject {

    /// Names already committed, in the order they were added.
    @Published private(set) var names: [String]

    /// What is currently in the field. Pre-filled, and freely editable or clearable.
    @Published var draft: String

    init() {
        let config = AppConfig.load()
        names = config.ownNames
        // A suggestion, never a decision. Most people are labelled with their full account
        // name in at least one app, so the field starts filled and Return is the entire
        // interaction. Nothing is stored until they actually add it, and they can clear it,
        // edit it, or ignore it and move on.
        draft = config.ownNames.isEmpty
            ? NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    /// The field's contents, trimmed. Empty when there is nothing worth adding.
    var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the field holds something new.
    var canAdd: Bool {
        let candidate = trimmedDraft
        guard !candidate.isEmpty else { return false }
        return !names.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
    }

    func add() {
        guard canAdd else { return }
        names.append(trimmedDraft)
        draft = ""
        persist()
    }

    func remove(_ name: String) {
        names.removeAll { $0 == name }
        persist()
    }

    /// Writes through a config loaded right now, not one captured at init: the app is running
    /// alongside this window and may have saved something of its own in between.
    private func persist() {
        var config = AppConfig.load()
        config.setOwnNames(names)
        config.save()
    }
}

/// The onboarding step that asks what the user is called, with the reason attached.
///
/// The reason is not decoration. A name field with nothing next to it reads as data
/// collection, and this app's entire promise is that it is not that.
struct IdentityStepView: View {
    @ObservedObject var step: IdentityStep

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Prose("Slack, Discord and group chats put a name in front of every message, including yours. Memoir ignores lines labelled with someone else's name, so it never tells you that you promised something a colleague did. Give it your own labels and it can keep the promises that really are yours.")

            VStack(alignment: .leading, spacing: 8) {
                ForEach(step.names, id: \.self) { name in
                    HStack(spacing: 7) {
                        Text(name)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink)
                        Button {
                            step.remove(name)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.faint)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(name)")
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.tile))
                }

                HStack(spacing: 9) {
                    TextField(
                        step.names.isEmpty ? "Your name in chat apps" : "Another name you go by",
                        text: $step.draft
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.tile))
                    .onSubmit { step.add() }

                    Button("Add") { step.add() }
                        .buttonStyle(PillButton(emphasis: .secondary))
                        .disabled(!step.canAdd)
                        .opacity(step.canAdd ? 1 : 0.4)
                }
            }

            Prose("Optional. Add as many as you like, one per app if they differ. Use the name the way it appears there, so a colleague who shares your first name is not mistaken for you. This stays on this Mac in Memoir's own settings file, like everything else here.")
                .opacity(0.75)
        }
    }
}
