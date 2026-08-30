import Foundation

/// Tuning for the accessibility capture pipeline.
///
/// The defaults are deliberately conservative: a quarter-second sampling of cheap signals,
/// a two minute idle threshold, and an exclusion list that covers password managers, the
/// keychain and common banking / crypto / health apps. Nothing here ever leaves the machine.
///
/// There is no "capture interval" here, and there has not been one since capture became
/// event-driven. What used to be `intervalSeconds` was retired in favour of the trigger
/// floors below; a `config.json` that still holds the key decodes fine and drops it.
///
/// The type is `Codable` so it can round-trip through `~/Library/Application Support/Memoir/config.json`.
/// Decoding tolerates a partial or hand-edited file: every missing key falls back to its default.
public struct CaptureConfig: Sendable, Codable, Equatable {

    /// Seconds without HID input after which the user is considered idle.
    /// While idle, no text is read at all; only the session row is maintained.
    public var idleThresholdSeconds: Double = 120

    /// Bundle identifiers that are never read from. See ``defaultExcludedBundleIDs``.
    public var excludedBundleIDs: Set<String> = CaptureConfig.defaultExcludedBundleIDs

    /// Which revision of the default exclusion list this configuration has been seeded with.
    /// Persisted so a new default reaches an existing installation exactly once.
    /// See ``currentExclusionsRevision``.
    public var exclusionsRevision: Int = CaptureConfig.currentExclusionsRevision

    /// Whether the focused window's title is recorded alongside the text.
    /// The title is read through the accessibility API first; the Screen Recording
    /// backed window list is only a fallback, and its absence degrades to `nil`.
    public var captureWindowTitles: Bool = true

    /// Hard ceiling on the characters collected in a single snapshot.
    /// Clamped to `1...20_000` by the capture actor; the accessibility tree can be enormous.
    public var maxTextLength: Int = 20_000

    // MARK: - Event-driven capture
    //
    // Capture fires on meaningful events, not on a fixed timer. Timer polling walked the
    // accessibility tree every interval regardless of whether anything had changed, which
    // is what filled the context with eight copies of the same page and burned CPU on a
    // static screen. The loop now samples only CHEAP signals on its tick (frontmost app,
    // window title, seconds-since-last-keystroke) and pays for a tree walk only when one
    // of them actually moves.

    /// How often the cheap signals are sampled. Not how often a capture happens.
    public var pollIntervalSeconds: Double = 0.25

    /// Hard floor between any two captures. Non-negotiable: prevents capture storms.
    public var minCaptureIntervalSeconds: Double = 0.2

    /// Higher floor for burst-prone triggers (typing pauses). Continuous typing would
    /// otherwise chain a full tree walk per keystroke.
    public var checkpointIntervalSeconds: Double = 1.5

    /// Fallback capture while nothing is happening, so a long read is still recorded.
    public var idleCaptureIntervalSeconds: Double = 30

    /// Quiet keyboard time after which typing counts as having paused.
    public var typingPauseSeconds: Double = 1.2

    /// How long a hole in the tick stream has to be before it splits the session in two.
    ///
    /// Sessions are maintained on every tick, not on every capture, so ticks arrive
    /// ``pollIntervalSeconds`` apart (a quarter second) whatever the triggers decide. A gap of
    /// thirty seconds therefore never means "nothing happened"; it means the loop was not
    /// running — the machine slept, capture was paused, or the app was quit — and claiming
    /// that time as work is the lie CF-13 exists to prevent.
    ///
    /// A constant, deliberately. It used to be `max(intervalSeconds * 3, 30)`, which made the
    /// user-facing interval stepper a session-rotation control in disguise: at every value it
    /// offered below ten it changed nothing at all, and above ten it silently widened this.
    public static let sessionGapSeconds: Double = 30


    /// Creates a configuration. Every parameter has the documented default.
    public init(
        idleThresholdSeconds: Double = 120,
        excludedBundleIDs: Set<String> = CaptureConfig.defaultExcludedBundleIDs,
        captureWindowTitles: Bool = true,
        maxTextLength: Int = 20_000,
        exclusionsRevision: Int = CaptureConfig.currentExclusionsRevision
    ) {
        self.idleThresholdSeconds = idleThresholdSeconds
        self.excludedBundleIDs = excludedBundleIDs
        self.captureWindowTitles = captureWindowTitles
        self.maxTextLength = maxTextLength
        self.exclusionsRevision = exclusionsRevision
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case idleThresholdSeconds, excludedBundleIDs, captureWindowTitles, maxTextLength
        case exclusionsRevision
    }

    /// Decodes a configuration, filling in defaults for any key the file omits.
    ///
    /// Also brings an older `config.json` forward: any identifier added to the default
    /// exclusion list since the revision this file was written with is seeded in, once. See
    /// ``exclusionsAddedByRevision``.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptureConfig()
        idleThresholdSeconds = try c.decodeIfPresent(Double.self, forKey: .idleThresholdSeconds) ?? defaults.idleThresholdSeconds
        captureWindowTitles = try c.decodeIfPresent(Bool.self, forKey: .captureWindowTitles) ?? defaults.captureWindowTitles
        maxTextLength = try c.decodeIfPresent(Int.self, forKey: .maxTextLength) ?? defaults.maxTextLength

        // A file written before exclusion revisions existed is revision 1 by definition.
        let writtenWith = try c.decodeIfPresent(Int.self, forKey: .exclusionsRevision) ?? 1
        var excluded = try c.decodeIfPresent(Set<String>.self, forKey: .excludedBundleIDs)
            ?? defaults.excludedBundleIDs
        excluded.formUnion(Self.exclusionsAdded(since: writtenWith))
        excludedBundleIDs = excluded
        exclusionsRevision = Self.currentExclusionsRevision
    }

    // MARK: - Derived, clamped values

    /// ``idleThresholdSeconds`` clamped so idle can never be detected instantly.
    public var effectiveIdleThreshold: Double { min(max(idleThresholdSeconds, 5), 3600) }

    /// ``maxTextLength`` clamped to the module's hard 20k character ceiling.
    public var effectiveMaxTextLength: Int { min(max(maxTextLength, 1), CaptureLimits.maxCharacters) }

    /// True when the given bundle identifier must never be read from.
    public func isExcluded(_ bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }

    // MARK: - Exclusions

    /// Apps Memoir never reads text from, by bundle identifier.
    ///
    /// Password managers, the keychain, Apple Passwords, System Settings (which surfaces
    /// saved passwords), plus widely used banking, accounting and crypto wallet apps.
    /// The user can add to this list; nothing here is ever captured, not even a window title.
    public static let defaultExcludedBundleIDs: Set<String> = [
        // Password managers
        "com.1password.1password",
        "com.1password.1password-launcher",
        "com.agilebits.onepassword",
        "com.agilebits.onepassword4",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.kyleneideck.keepassx",
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop",
        "com.dashlane.Dashlane",
        "com.dashlane.dashlanephonefinal",
        "com.nordpass.macos",
        "in.sinew.Enpass-Desktop",
        "com.mSeven.mSecure5",
        "com.apple.Passwords",
        "com.apple.PasswordManager",
        "com.apple.keychainaccess",
        // The system's own credential prompts. Excluding Keychain Access covered the app the
        // user opens and missed the sheet macOS puts in front of them: SecurityAgent draws
        // every "enter your keychain password" and admin-authorisation panel, loginwindow the
        // unlock screen, UserNotificationCenter the alerts they arrive in. Measured on a real
        // database before this line existed: 40 captures across the three, 23 of them holding
        // the text of a credential prompt. The secure-field skip did its job (no password
        // value was ever stored), but "security codesign wants to access key … enter the
        // login keychain password" is not something a memory of your work should contain.
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
        "com.apple.UserNotificationCenter",
        // Settings surfaces credentials and full-disk secrets
        "com.apple.systempreferences",
        // Messaging: SMS/iMessage carries 2FA codes and private conversations. The INPS
        // verification code that Memoir read back to the user came from here. Web WhatsApp in
        // a browser is NOT excluded (it is the browser bundle), so "last WhatsApp message"
        // still works; only the native SMS/2FA firehose is dropped.
        "com.apple.MobileSMS",
        "com.apple.iChat",
        "com.apple.notificationcenterui",
        // Health
        "com.apple.Health",
        // Banking / accounting / tax
        "com.moneymoney-app.retail",
        "com.iggsoftware.banktivity",
        "com.iggsoftware.ibank5",
        "com.intuit.quickbooks.mac",
        "com.quicken.Quicken",
        "com.ynab.desktop",
        "com.youneedabudget.YNAB4",
        "org.gnucash.Gnucash",
        "com.intuit.turbotax",
        // Crypto wallets
        "com.ledger.live",
        "com.exodus.desktop",
        "org.electrum.electrum",
        "com.trezor.suite",
    ]

    // MARK: - Seeding new exclusions into an existing installation

    /// The revision of ``defaultExcludedBundleIDs`` this build ships.
    ///
    /// Raise it whenever an identifier is *added* to the default list, and record the addition
    /// in ``exclusionsAddedByRevision``. Adding to the default alone reaches nobody who has
    /// already run Memoir: `excludedBundleIDs` is persisted whole in `config.json`, so an
    /// existing installation keeps the list it was created with forever.
    public static let currentExclusionsRevision = 2

    /// What each revision added, so an older configuration can be brought forward.
    ///
    /// Deliberately additive-once rather than a union on every load. The exclusion list is
    /// editable (Settings → Capture can *remove* an entry), and re-adding on every launch
    /// would quietly overrule a choice the user made on purpose, which is the same sin as
    /// letting extraction overwrite a correction. Seeding once per revision means a new
    /// default reaches everyone, and a user who then removes it is obeyed.
    public static let exclusionsAddedByRevision: [Int: Set<String>] = [
        2: ["com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.UserNotificationCenter"],
    ]

    /// The identifiers introduced after `revision`.
    public static func exclusionsAdded(since revision: Int) -> Set<String> {
        exclusionsAddedByRevision
            .filter { $0.key > revision }
            .values
            .reduce(into: Set<String>()) { $0.formUnion($1) }
    }
}

/// Hard, non-configurable ceilings on a single accessibility snapshot.
///
/// These exist so a pathological accessibility tree can never hang the app.
/// They are enforced in addition to whatever ``CaptureConfig`` asks for.
public enum CaptureLimits {
    /// Maximum depth of the accessibility tree walk.
    public static let maxDepth = 40
    /// Maximum number of accessibility elements visited per snapshot.
    public static let maxNodes = 12_000
    /// Maximum characters collected per snapshot.
    public static let maxCharacters = 20_000
    /// Wall-clock budget for one snapshot, in seconds.
    public static let deadlineSeconds: Double = 1.2
    /// Per-message accessibility timeout, in seconds. Keeps one wedged app from stalling the walk.
    public static let messagingTimeoutSeconds: Float = 0.25
    /// Backstop after which the snapshot returns whatever it has, even if the walk is still running.
    public static let watchdogSeconds: Double = 1.6
}
