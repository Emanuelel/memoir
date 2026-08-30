import AppKit
import SwiftUI
import MemoirKit

/// Which pane the promoted window is showing. Separate from the band's selection
/// because the window carries two panes a band can't hold (Memories, Settings), and
/// closing the window must not yank the band onto a pane it cannot render.
@MainActor
final class WindowState: ObservableObject {
    @Published var pane: ShellModel.PaneID = ShellModel.PaneID.home
}

/// The band, promoted: the same panes with a vertical list on the left, plus the
/// things a band can't hold. It is the browser Memoir already has, not a second home:
/// the band stays the default surface, and this exists for digging.
@MainActor
final class PromotedWindowController: NSObject, NSWindowDelegate {

    private let shell: ShellModel
    private let windowState = WindowState()
    private var window: NSWindow?
    private let memoryModel: MemoryBrowserModel
    private let settingsModel: SettingsModel

    init(shell: ShellModel, memoryModel: MemoryBrowserModel, settingsModel: SettingsModel) {
        self.shell = shell
        self.memoryModel = memoryModel
        self.settingsModel = settingsModel
        super.init()
    }

    /// True while the window is on screen, so the strip's control can say "collapse"
    /// rather than offering to promote something that is already promoted.
    var isVisible: Bool { window?.isVisible == true }

    /// Fronts the window on a pane. Promoting collapses the band: one surface has
    /// the user's attention at a time.
    func show(pane: ShellModel.PaneID) {
        windowState.pane = pane
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        shell.setPromoted(true)
    }

    /// Demotes back to the band: the window goes away and the band opens on whatever
    /// pane the window was showing, so the eye lands where it left off.
    func demote() {
        window?.orderOut(nil)
        shell.setPromoted(false)
        NSApp.deactivate()
        let pane = windowState.pane
        shell.open(pane: pane.inBand ? pane : ShellModel.PaneID.home)
    }

    /// Closing the window with the red button is a demotion too, but a quiet one:
    /// the band stays collapsed rather than springing open unasked.
    func windowWillClose(_ notification: Notification) {
        shell.setPromoted(false)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Memoir"
        // The chrome is the sidebar, not a title bar: the traffic lights float over
        // the black and everything else is the content.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor.black
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.center()
        window.delegate = self
        window.contentView = NSHostingView(rootView: WindowRootView(
            shell: shell,
            windowState: windowState,
            character: shell.character,
            chat: shell.chat,
            memoryModel: memoryModel,
            settingsModel: settingsModel
        ))
        return window
    }
}

/// The window's whole surface: sidebar, hairline, pane.
struct WindowRootView: View {
    @ObservedObject var shell: ShellModel
    @ObservedObject var windowState: WindowState
    @ObservedObject var character: CharacterModel
    let chat: ChatController
    let memoryModel: MemoryBrowserModel
    let settingsModel: SettingsModel

    /// Journal entries, not notes. These are two different numbers now: the store holds a note
    /// row for every markdown file the vault importer has ever read, and none of those are
    /// journal entries. The badge said 76 next to a tab showing 5. It sits beside Calendar
    /// now, which is where writing lives.
    @State private var notesCount = 0
    @State private var memoriesCount = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
            Theme.vHairline
            VStack(spacing: 0) {
                paneHeader
                Theme.hairline
                paneHost
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The window ends somewhere: a closing hairline and a margin, so the
                // content reads as bounded instead of running off the bottom edge.
                Theme.hairline
                Color.clear.frame(height: 10)
            }
        }
        .background(Theme.bg)
        .environment(\.memoirSurface, .window)
        .task { await loadCounts() }
        .onChange(of: windowState.pane) { _, _ in Task { await loadCounts() } }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights, which float over the black.
            Color.clear.frame(height: 40)

            HStack(spacing: 9) {
                FoldMark(
                    traits: character.traits,
                    gaze: character.gaze,
                    blink: character.blink
                )
                .frame(width: 24, height: 26)
                .animation(.easeInOut(duration: 0.18), value: character.expression)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memoir")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(statusLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)

            ForEach(bandPanes, id: \.self) { pane in
                SidebarRow(
                    title: pane.title,
                    badge: badge(for: pane),
                    badgeIsAccent: pane == .portrait,
                    selected: windowState.pane == pane
                ) { windowState.pane = pane }
            }

            Spacer(minLength: 0)

            Theme.hairline.padding(.horizontal, 12).padding(.bottom, 8)

            SidebarRow(
                title: ShellModel.PaneID.memories.title,
                badge: memoriesCount > 0 ? "\(memoriesCount)" : nil,
                badgeIsAccent: false,
                selected: windowState.pane == .memories
            ) { windowState.pane = .memories }
            SidebarRow(
                title: ShellModel.PaneID.settings.title,
                badge: nil,
                badgeIsAccent: false,
                selected: windowState.pane == .settings
            ) { windowState.pane = .settings }
        }
        .padding(.bottom, 12)
    }

    private var bandPanes: [ShellModel.PaneID] { ShellModel.PaneID.bandTabs }

    private var statusLine: String {
        if !shell.hasAccessibility { return "needs permission" }
        if shell.capturePaused { return shell.pauseLabel?.lowercased() ?? "capture paused" }
        return "listening quietly"
    }

    private func badge(for pane: ShellModel.PaneID) -> String? {
        switch pane {
        case .calendar: return notesCount > 0 ? "\(notesCount)" : nil
        default: return nil
        }
    }

    private func loadCounts() async {
        let store = shell.store
        notesCount = ((try? await store.notes(
            written: true, from: .distantPast, to: .distantFuture
        )) ?? []).count
        memoriesCount = (try? await store.stats().entityCount) ?? 0
    }

    // MARK: - Header

    /// Title on the left; the running timer and the trust line on the right. Trust is
    /// a fact here, not decoration: the line reflects the outbound counter.
    private var paneHeader: some View {
        HStack(spacing: 10) {
            Text(windowState.pane.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            // The way back. The band's ⤢ is out of sight while this window is up, so
            // the inverse control has to live here; otherwise promoting is one-way.
            Button { shell.onDemote?() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the notch")
            TrustLine()
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 12)
    }

    // MARK: - Panes

    @ViewBuilder
    private var paneHost: some View {
        switch windowState.pane {
        case .portrait:
            PortraitPane(model: shell.portrait)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        case .calendar:
            CalendarPane(model: shell.calendar)
                .padding(.horizontal, 20)
        case .ask:
            ChatPane(chat: chat)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        case .journal:
            // Not reachable: `inBand` sends it home and no row selects it. The case remains so
            // a preference saved when Journal was a tab still decodes.
            CalendarPane(model: shell.calendar)
                .padding(.horizontal, 20)
        case .memories:
            // The existing browser, whole: kinds sidebar, search, provenance, edit.
            // It is the digging surface this window exists for.
            MemoryBrowserView(model: memoryModel)
        case .settings:
            SettingsView(model: settingsModel)
        }
    }
}

/// One sidebar entry: white pill when selected, quiet text otherwise, a count on the
/// right when there is one worth saying.
private struct SidebarRow: View {
    let title: String
    let badge: String?
    let badgeIsAccent: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.bg : Theme.dim)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(badgeIsAccent ? Theme.accent : Theme.faint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                selected ? Theme.bg.opacity(0.12)
                                    : badgeIsAccent ? Theme.accent.opacity(0.13) : Theme.tile
                            )
                        )
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.ink : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
    }
}

/// "Local · nothing leaves the Mac", or the honest alternative when it has.
private struct TrustLine: View {
    @ObservedObject private var outbound = OutboundCounter.shared

    var body: some View {
        Text(outbound.count == 0
             ? "Local · nothing leaves the Mac"
             : "\(outbound.count) sent to \(outbound.lastDestination ?? "the cloud")")
            .font(.system(size: 11))
            .foregroundStyle(outbound.count == 0 ? Theme.faint : Theme.warn)
    }
}
