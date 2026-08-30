import Foundation
import ApplicationServices
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// TCC permission checks for the capture pipeline.
///
/// Note on the constant `kAXTrustedCheckOptionPrompt`: it is imported from C as a mutable
/// global and is therefore not usable under Swift 6 strict concurrency. The literal string
/// value of that constant ("AXTrustedCheckOptionPrompt") is used instead. Same key, same behaviour.
public enum Permissions {

    /// The options-dictionary key for `AXIsProcessTrustedWithOptions`.
    private static let trustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"

    /// Whether this process is trusted for Accessibility. Never prompts.
    ///
    /// Accessibility permission is bound to the bundle identifier *and* the code signature,
    /// so re-signing the app resets it. That is expected and documented in the README.
    public static func hasAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions([trustedCheckOptionPrompt: false] as CFDictionary)
    }

    /// Asks for Accessibility permission.
    ///
    /// Fires the system prompt (which only appears once per signature) and then opens the
    /// Privacy & Security → Accessibility pane so the user can flip the switch. Safe to call
    /// from any thread; the pane is opened on the main actor.
    public static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([trustedCheckOptionPrompt: true] as CFDictionary)
        openPrivacyPane("com.apple.preference.security?Privacy_Accessibility")
    }

    /// Whether this process may read window titles from the window server.
    ///
    /// Capture works without it; only `kCGWindowName` in the window-list fallback needs it,
    /// and its absence degrades silently to a `nil` window title.
    public static func hasScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks for Screen Recording permission and opens the matching Settings pane.
    ///
    /// Optional: window titles are a nicety, not a requirement. Returns the value reported by
    /// `CGRequestScreenCaptureAccess()`, which is `true` only if access was already granted.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            openPrivacyPane("com.apple.preference.security?Privacy_ScreenCapture")
        }
        return granted
    }

    /// Opens a System Settings privacy pane by its `x-apple.systempreferences:` identifier.
    ///
    /// Public because a refusal is a dead end without it: once macOS has recorded a "no" it
    /// stops prompting, so the only way back is the pane itself, and a message that names the
    /// pane without opening it leaves the user to go and find it.
    public static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        #if canImport(AppKit)
        if Thread.isMainThread {
            MainActor.assumeIsolated { _ = NSWorkspace.shared.open(url) }
        } else {
            Task { @MainActor in _ = NSWorkspace.shared.open(url) }
        }
        #endif
    }
}
