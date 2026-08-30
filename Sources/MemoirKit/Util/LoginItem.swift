import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Whether Memoir starts itself when the Mac starts.
///
/// This is a capture-integrity feature, not a convenience. Memoir had no login item at all,
/// which means every restart (a system update at 3am, a battery running flat, a crash) ended
/// recording until the user happened to notice and launch the app again. Nothing said so. A
/// gap that starts at a reboot and ends whenever somebody thinks to look is the exact failure
/// the rest of this work exists to make impossible, and it was the most likely one.
///
/// `SMAppService` is used rather than a `LaunchAgents` plist because the plist approach is
/// deprecated, needs a file the user cannot see written into their Library, and gives no way
/// to find out that they later switched it off in System Settings. That last part matters
/// most: ``status`` distinguishes "registered" from "the user has disabled it", so a Mac that
/// will not relaunch Memoir can say so instead of looking fine.
public enum LoginItem {

    /// What macOS says about the login item right now.
    public enum State: String, Sendable, Equatable {
        /// It will launch at login.
        case enabled
        /// It is off.
        case disabled
        /// Registered, but the user has to allow it in System Settings → General → Login Items.
        case requiresApproval
        /// This build cannot register one: running from a build directory rather than a
        /// bundle, or on a system that refused. Never silently treated as "off".
        case unavailable

        public var willLaunch: Bool { self == .enabled }

        /// What Settings says next to the switch. Nil when there is nothing to add.
        public var caveat: String? {
            switch self {
            case .enabled, .disabled:
                return nil
            case .requiresApproval:
                return "macOS is holding this back. Allow Memoir in System Settings → General → Login Items."
            case .unavailable:
                return "macOS will not register Memoir to open at login from where it is running. Move Memoir.app to your Applications folder and try again."
            }
        }
    }

    /// The current state, read from macOS rather than from anything Memoir stored.
    public static func state() -> State {
        #if canImport(ServiceManagement)
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    /// Turns the login item on or off, and reports what macOS actually did.
    ///
    /// Never throws: a failure here must not stop the app launching, and the returned state is
    /// the honest answer either way. The caller shows it.
    @discardableResult
    public static func set(_ enabled: Bool) -> State {
        #if canImport(ServiceManagement)
        do {
            if enabled {
                // Registering an already-registered service throws, and that is not a failure.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.shared.error("login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
        let result = state()
        Log.shared.info("login item is \(result.rawValue)")
        return result
        #else
        return .unavailable
        #endif
    }

    /// Brings macOS in line with the user's setting, once, at launch.
    ///
    /// Called on every launch on purpose. A login item can be removed by a migration, a restore
    /// from backup, or the app being moved, and none of those tell Memoir. Re-asserting the
    /// user's own preference costs nothing when it already matches.
    @discardableResult
    public static func reconcile(wanted: Bool) -> State {
        let current = state()
        // `requiresApproval` is the user's decision to make in System Settings, and re-registering
        // will not change it. Leave it alone and let Settings report it.
        if current == .requiresApproval { return current }
        if wanted == current.willLaunch { return current }
        return set(wanted)
    }
}
