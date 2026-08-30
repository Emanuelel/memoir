import Foundation
import CoreGraphics
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Anything that can produce a single point-in-time reading of what is on screen.
///
/// Implementations return `nil` (rather than throwing) for the ordinary "nothing to record"
/// cases: the frontmost app is excluded, the user is looking at an empty window, or the text is
/// byte-identical to the previous capture. Throwing is reserved for conditions the user must fix,
/// principally ``MemoirError/accessibilityPermissionDenied``.
public protocol CaptureSource: Sendable {
    /// Reads the current screen state, or returns `nil` when there is nothing worth storing.
    func snapshot() async throws -> CaptureEvent?
}

/// The application currently in front, as three plain `Sendable` values.
///
/// Reading this needs no permission at all: `NSWorkspace` publishes it to every process.
struct FrontmostApp: Sendable, Equatable {
    /// Bundle identifier, e.g. `com.apple.Safari`.
    let bundleID: String
    /// Localised display name, falling back to the bundle identifier.
    let name: String
    /// Unix process identifier, used as the root for the accessibility walk.
    let pid: pid_t

    /// The app currently in front, or `nil` if there is none or it has no bundle identifier.
    /// The focused window's title, read with a single accessibility call.
    ///
    /// Deliberately does NOT walk the tree: two attribute reads, microseconds, safe to call
    /// on every 250 ms tick. It is the signal that catches "same app, different document".
    static func focusedWindowTitle() -> String? {
        #if canImport(ApplicationServices)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(element, 0.1)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
            let windowRef else { return nil }
        // CFTypeRef from the AX API is an AXUIElement here by contract.
        let window = unsafeDowncast(windowRef, to: AXUIElement.self)
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef) == .success,
            let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
        #else
        return nil
        #endif
    }

    static func current() -> FrontmostApp? {
        #if canImport(AppKit)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
        return FrontmostApp(
            bundleID: bundleID,
            name: app.localizedName ?? bundleID,
            pid: app.processIdentifier
        )
        #else
        return nil
        #endif
    }
}

/// User idleness, measured without ever installing an event tap.
///
/// `CGEventSource.secondsSinceLastEventType` is a passive query against the window server's
/// HID state. Memoir never creates a `CGEventTap` and never synthesizes an event.
enum IdleMonitor {
    /// Seconds since the last keyboard, mouse or trackpad event. `0` if the query fails.
    static func idleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        let seconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// Seconds since the last key press.
    ///
    /// Drives typing-pause detection. Uses the same HID counter as ``idleSeconds()``: it
    /// reports *when* a key was last pressed, never *which* key, and needs no event tap and
    /// no Input Monitoring permission. Memoir must never be able to read keystrokes.
    static func secondsSinceKeystroke() -> TimeInterval {
        let seconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        return seconds.isFinite && seconds >= 0 ? seconds : .greatestFiniteMagnitude
    }
}
