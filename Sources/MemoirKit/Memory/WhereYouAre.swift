import CoreLocation
import Foundation

/// Roughly where this Mac is, for the one thing that needs it: asking what the weather was.
///
/// ## Reduced accuracy, always
///
/// `CLLocationManager` is asked for `kCLLocationAccuracyReduced` and never asks for temporary
/// full accuracy. macOS then hands over a coarse location (a district, not an address) and
/// `Weather` rounds it further before anything leaves the machine. Memoir has no use for a
/// precise position and no code that could develop one: nothing here writes to the store, and
/// the only caller is the weather tile.
///
/// This also changes what the permission dialog means. Under reduced accuracy the system says
/// the app is asking for approximate location, which is the true description of what it does.
///
/// ## Nothing is remembered
///
/// The location is fetched when the journal needs it and held for as long as the answer takes.
/// It is never written to the database, the config file or the log. Memoir stores the places
/// you go from your own photographs and calendar, which you can see and delete; it does not
/// keep a second record of where the Mac happens to be.
public final class WhereYouAre: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    public static let shared = WhereYouAre()

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    private let lock = NSLock()

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Whether macOS will hand over a location right now. Never prompts.
    public var isGranted: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    /// Whether the user has been asked at all. A refusal is remembered by the system, so
    /// asking again does nothing and the only way back is System Settings.
    public var wasAsked: Bool {
        manager.authorizationStatus != .notDetermined
    }

    /// The `x-apple.systempreferences:` pane holding the switch, for a refusal that has to be
    /// actionable: the same reasoning `LifeImporter.Source` gives for its three.
    public static let settingsPane = "com.apple.preference.security?Privacy_LocationServices"

    /// Asks once, and returns a coarse location if one arrives inside `timeout`.
    ///
    /// Returns nil for every refusal, every timeout, and every machine with Location Services
    /// switched off. The caller's job in all of those cases is the same: one fewer tile.
    public func coarseLocation(timeout: TimeInterval = 6) async -> CLLocation? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }

        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        default:
            break
        }

        if let cached = manager.location { return cached }

        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { continuation in
                    guard let self else { return continuation.resume(returning: nil) }
                    self.lock.lock()
                    self.waiting.append(continuation)
                    self.lock.unlock()
                    self.manager.requestLocation()
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Hands a location to whoever is waiting, once.
    private func deliver(_ location: CLLocation?) {
        lock.lock()
        let pending = waiting
        waiting = []
        lock.unlock()
        for continuation in pending { continuation.resume(returning: location) }
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        deliver(locations.last)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.shared.warn("location: \(error.localizedDescription)")
        deliver(nil)
    }
}
