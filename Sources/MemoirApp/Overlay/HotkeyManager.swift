import AppKit
import MemoirKit

/// Watches for the activation shortcut.
///
/// Deliberately **listen-only**: it observes key events and never synthesizes or posts
/// them. The global monitor needs Accessibility permission, which Memoir already asks for
/// to read on-screen text; the local monitor covers the case where Memoir itself is frontmost.
@MainActor
public final class HotkeyManager {

    /// The default shortcut, ⌥Space.
    public static let defaultKeyCode: UInt16 = 49
    public static let defaultModifiers: NSEvent.ModifierFlags = .option

    private let onActivate: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyCode: UInt16 = HotkeyManager.defaultKeyCode
    private var modifiers: NSEvent.ModifierFlags = HotkeyManager.defaultModifiers

    public init(onActivate: @escaping @MainActor () -> Void) {
        self.onActivate = onActivate
    }

    /// Removes both monitors. Called from `AppDelegate` on teardown; not done in
    /// `deinit` because Swift 6 forbids touching non-Sendable state there.
    public func invalidate() { unregister() }

    /// Registers (or re-registers) the shortcut. Safe to call repeatedly.
    public func register(
        keyCode: UInt16 = HotkeyManager.defaultKeyCode,
        modifiers: NSEvent.ModifierFlags = HotkeyManager.defaultModifiers
    ) {
        unregister()
        self.keyCode = keyCode
        self.modifiers = modifiers

        // NSEvent is not Sendable, so only the primitive fields cross into the
        // main-actor closure, never the event object itself.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                guard let self, self.matches(keyCode: code, flags: flags) else { return }
                self.onActivate()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.matches(keyCode: code, flags: flags) else { return false }
                self.onActivate()
                return true
            }
            return handled ? nil : event
        }

        Log.shared.info("hotkey registered: \(Self.describe(keyCode: keyCode, modifiers: modifiers))")
    }

    public func unregister() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }

    /// True when the global monitor is installed. Requires Accessibility permission.
    public var isRegistered: Bool { globalMonitor != nil }

    private func matches(keyCode code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard code == keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return flags.intersection(relevant) == modifiers
    }

    /// Human-readable shortcut, for the menu and settings.
    public static func describe(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += keyName(keyCode)
        return s
    }

    private static func keyName(_ code: UInt16) -> String {
        switch code {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Esc"
        case 0: return "A"
        case 1: return "S"
        case 8: return "C"
        case 46: return "M"
        case 31: return "O"
        case 35: return "P"
        default: return "Key \(code)"
        }
    }
}
