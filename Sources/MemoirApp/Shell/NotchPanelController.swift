import AppKit
import Combine
import SwiftUI
import MemoirKit

/// The one resident panel the band lives in.
///
/// Borderless, non-activating, and *conditionally* able to become key: false while
/// collapsed so the band can never steal a keystroke, true while open so the composer
/// takes typing, without `NSApp.activate`, so the frontmost app stays frontmost.
final class NotchPanel: NSPanel {
    /// Flipped by the controller as the band opens and collapses.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that only exists where the band is drawn.
///
/// The panel spans the maximum band frame permanently; everything outside the black
/// shape must behave as if the panel were not there: menu bar items, desktop icons,
/// other apps' windows all stay clickable. `hitTest` answers nil outside the rect the
/// shape currently occupies.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// The band's current rect in this view's (flipped, top-left origin) coordinates.
    var bandRect: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bandRect().insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// One click is enough, even when the band was not the key window.
    ///
    /// The band deliberately does not collapse when you click away, so it is routinely
    /// non-key while fully visible, and AppKit spends the first click on a non-key
    /// window making it key, then throws it away. That is exactly why ticking a todo
    /// did nothing until the second attempt: the control never heard about the press.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel, the screen geometry, the Escape monitor and the key-status dance.
/// Everything visual lives in `BandRootView`; this is a thin AppKit shim.
@MainActor
final class NotchPanelController {

    private let shell: ShellModel
    private let chat: ChatController
    private var panel: NotchPanel?
    private let holder: GeometryHolder
    private var keyMonitor: Any?
    private var modeSink: AnyCancellable?
    private var screenObserver: NSObjectProtocol?

    init(shell: ShellModel, character: CharacterModel, chat: ChatController) {
        self.shell = shell
        self.chat = chat

        let screen = NSScreen.main
        self.holder = GeometryHolder(
            geometry: Self.geometry(for: screen),
            screenWidth: screen?.frame.width ?? 1512
        )

        let panel = Self.makeBandPanel()

        let root = BandRootView(
            shell: shell, character: character, holder: holder, chat: chat
        )
        let hosting = PassthroughHostingView(rootView: root)
        hosting.bandRect = { [weak shell, weak holder, weak hosting] in
            guard let shell, let holder, let hosting else { return .zero }
            let size = BandRootView.bandSize(
                mode: shell.mode,
                geometry: holder.geometry,
                screenWidth: holder.screenWidth,
                health: shell.health
            )
            return CGRect(
                x: (hosting.bounds.width - size.width) / 2,
                y: holder.geometry.topOffset,
                width: size.width,
                height: size.height
            )
        }
        panel.contentView = hosting
        self.panel = panel

        if let screen { anchor(to: screen) }

        // The controller reacts to mode changes: key status and the Escape monitor.
        modeSink = shell.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in self?.apply(mode) }

        // Displays come and go; the band re-anchors to whatever is main.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let screen = NSScreen.main else { return }
                self.anchor(to: screen)
            }
        }
    }

    /// Detaches monitors and observers. Deinit cannot touch main-actor state, so the
    /// app delegate calls this before letting go.
    func invalidate() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        modeSink?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// Puts the band on screen. It never takes focus by appearing.
    func show() {
        panel?.orderFrontRegardless()
    }

    /// The window, with nothing in it yet.
    ///
    /// Static and separate from `init` so a test can build the exact window the confirm
    /// card's due field has to work inside. `.nonactivatingPanel` is one of the two
    /// settings that historically decided whether a click reached a control at all, so a
    /// test against a plain `NSWindow` would prove nothing about the window that ships.
    static func makeBandPanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One level above the menu bar: the strip paints over the bar's empty centre
        // beside the camera, while system menus and Spotlight still draw above us.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The collapsed band must fuse with the bezel; SwiftUI draws the open shadow.
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.animationBehavior = .none
        return panel
    }

    // MARK: - Geometry

    private static func geometry(for screen: NSScreen?) -> NotchGeometry {
        guard let screen else {
            return NotchGeometry(
                screenWidth: 1512, safeAreaTopInset: 0,
                auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 24
            )
        }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(
            screenWidth: screen.frame.width,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: menuBarHeight
        )
    }

    /// Re-derives the notch numbers and moves the resident frame to a screen.
    private func anchor(to screen: NSScreen) {
        let geometry = Self.geometry(for: screen)
        holder.geometry = geometry
        holder.screenWidth = screen.frame.width
        panel?.setFrame(BandLayout.panelFrame(on: screen.frame, geometry: geometry), display: true)
    }

    /// The screen the mouse is on, for ⌥Space from a second display.
    private var screenUnderMouse: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }

    // MARK: - Mode

    private func apply(_ mode: ShellModel.Mode) {
        guard let panel else { return }
        switch mode {
        case .open:
            if let screen = screenUnderMouse { anchor(to: screen) }
            panel.allowsKey = true
            // No NSApp.activate: a non-activating key panel takes typing while the
            // frontmost app stays active. That is the entire trick.
            panel.makeKeyAndOrderFront(nil)
            installKeyMonitor()

        case .collapsed, .moment:
            removeKeyMonitor()
            let wasKey = panel.isKeyWindow
            panel.allowsKey = false
            // Let go of the caret before refusing key status, or the window server can
            // leave a dead field editor holding the keyboard.
            panel.makeFirstResponder(nil)
            if wasKey {
                // Hand the keyboard straight back to whoever had it. The app was
                // never activated, so deactivating is a no-op belt-and-braces.
                NSApp.deactivate()
            }
        }
    }

    /// The band's keys while it is open. Read here rather than from the text field,
    /// because the composer is disabled while a confirm card is up, and a disabled
    /// field has no `onSubmit` to hang Return on.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // The key code is lifted out first because `NSEvent` is not Sendable and
            // so cannot cross into the isolated hop. Only the decision comes back.
            let keyCode = event.keyCode
            let shifted = event.modifierFlags.contains(.shift)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                switch keyCode {
                case 48 where !shifted:                    // Tab → the card's due field
                    return ChatController.moveCaretToDueField(
                        in: self.panel,
                        pendingPush: self.chat.state.pendingPushIndex != nil
                    )
                case 53:                                   // Escape
                    // A pending card gets the first Escape. Discarding a proposal
                    // must not also take the band away: "it discarded, so did it
                    // save?" needs somewhere to be answered, and that somewhere is
                    // the card saying nothing was written. A second Escape collapses.
                    if self.chat.discardPendingPush() { return true }
                    self.shell.collapse()
                    return true
                case 36, 76:                               // Return, keypad Enter
                    return self.chat.savePendingPush()
                default:
                    return false
                }
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
