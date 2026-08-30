import Foundation
import MemoirKit

/// Everything the user can change, persisted as one JSON file.
///
/// The Anthropic API key is deliberately not in here: it lives in the Keychain and is
/// merged in at load time. Nothing in this file is ever sent anywhere.
struct AppConfig: Codable, Sendable {
    var capture: CaptureConfig
    var restraint: RestraintConfig
    var brain: BrainConfig
    var voice: VoiceConfig
    var reminders: RemindersConfig
    var preferredBrain: BrainKind
    var retentionDays: Int
    var capturePaused: Bool

    /// When a pause ends by itself. Nil while capture is running, and nil for the one pause
    /// the user asked to be indefinite. See ``CapturePause``.
    var capturePauseExpiresAt: Date?
    var hotkeyCode: UInt16
    var hotkeyModifierRaw: UInt
    /// Path to a markdown folder (an Obsidian vault, a notes directory) whose titles
    /// and aliases are imported as authored entities. Nil means no vault configured.
    var vaultPath: String?

    /// What people call the user in chat apps. Empty until they say so.
    ///
    /// A list because one string cannot describe a person: full name in Slack, a handle in
    /// Discord, a first name in iMessage. `RuleExtractor` reads these to tell the user's own
    /// messages apart from everyone else's in a transcript where every line carries a name.
    /// Set it with ``setOwnNames(_:)``, never by assignment, so the extractor hears about it.
    var ownNames: [String]

    /// Whether the user has been all the way through onboarding.
    ///
    /// Not the same question as "is Accessibility granted". Onboarding used to be shown
    /// whenever the permission was missing and torn down the instant it arrived, which made
    /// the permission the only step that could exist: anything after it was destroyed
    /// mid-sentence by the grant it was waiting for. This flag is what lets the flow outlive
    /// its own first step.
    var hasCompletedOnboarding: Bool

    /// Whether the user has been given their recovery key and said they kept it.
    ///
    /// Not "have we shown it once". The first version handed the key to onboarding only on the
    /// launch that created it, which meant a relaunch (or an upgrade that skips first run
    /// because this Mac was already set up) silently threw away the only thing that can
    /// recover the memory if the keychain goes. It stays false until somebody copies or saves
    /// it, and everything that can offer it keeps offering it until then.
    var recoveryKeyAcknowledged: Bool

    /// Whether the band offers a nightly invitation to write in the journal.
    ///
    /// On by default, because a journal nobody is invited to open is a journal nobody writes in:
    /// the blank page is the category's known failure mode and forgetting is the other half of it.
    /// One switch, off, forever, no follow-up question.
    var journalInvitation: Bool

    /// Whether Memoir starts itself when the Mac does.
    ///
    /// On by default, and it is the one default in this file that is about correctness rather
    /// than taste. Capture that stops at a reboot and waits to be noticed is the failure mode
    /// with the longest fuse: nothing is wrong on screen, nothing is logged, and the first
    /// symptom is an answer about the wrong week.
    var openAtLogin: Bool

    /// Whether the journal may ask what the weather was.
    ///
    /// **Off by default, and it is the third network switch rather than an exception to the
    /// other two.** Weather is the one thing the journal shows that is not already on this Mac,
    /// so it cannot be answered without telling somebody roughly where you are. See `Weather`
    /// for the shape that takes, and PRIVACY.md for the row it adds to the table.
    ///
    /// Off means off: nothing is fetched, no location is requested, and the tile does not
    /// appear. An upgrade must never be the thing that starts a new kind of request.
    var allowWeather: Bool

    /// Whether Memoir may ask whether a newer version exists.
    ///
    /// **On by default, and the only request the app makes without being asked**, which is why
    /// it gets a switch of its own rather than living under the cloud brains. What it sends is
    /// argued for in `UpdateCheck` and in PRIVACY.md: a plain GET for a static file, carrying
    /// no version, no machine id and no account, with the comparison done on this Mac.
    ///
    /// Off means off. Memoir then never learns that a fix exists, and neither does the user,
    /// which is the honest cost of the switch rather than a reason to hide it.
    var allowUpdateCheck: Bool

    /// The last day the invitation was offered, so it is offered once and not on every tick.
    ///
    /// Stored rather than held in memory: a relaunch would otherwise invite again, and an app
    /// that asks twice in one evening is a nag whatever the copy says.
    var lastJournalInvitation: Date?

    init(
        capture: CaptureConfig = CaptureConfig(),
        restraint: RestraintConfig = .default,
        brain: BrainConfig = BrainConfig(),
        voice: VoiceConfig = VoiceConfig(),
        reminders: RemindersConfig = RemindersConfig(),
        preferredBrain: BrainKind = .appleOnDevice,
        retentionDays: Int = 0,
        capturePaused: Bool = false,
        capturePauseExpiresAt: Date? = nil,
        hotkeyCode: UInt16 = 49,
        hotkeyModifierRaw: UInt = 524_288,   // .option
        ownNames: [String] = [],
        vaultPath: String? = nil,
        hasCompletedOnboarding: Bool = false,
        recoveryKeyAcknowledged: Bool = false,
        journalInvitation: Bool = true,
        openAtLogin: Bool = true,
        allowWeather: Bool = false,
        allowUpdateCheck: Bool = true,
        lastJournalInvitation: Date? = nil
    ) {
        self.capture = capture
        self.restraint = restraint
        self.brain = brain
        self.voice = voice
        self.reminders = reminders
        self.preferredBrain = preferredBrain
        self.retentionDays = retentionDays
        self.capturePaused = capturePaused
        self.capturePauseExpiresAt = capturePauseExpiresAt
        self.hotkeyCode = hotkeyCode
        self.hotkeyModifierRaw = hotkeyModifierRaw
        self.ownNames = ownNames
        self.vaultPath = vaultPath
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.recoveryKeyAcknowledged = recoveryKeyAcknowledged
        self.journalInvitation = journalInvitation
        self.openAtLogin = openAtLogin
        self.allowWeather = allowWeather
        self.allowUpdateCheck = allowUpdateCheck
        self.lastJournalInvitation = lastJournalInvitation
    }

    /// The pause, as the rest of the app wants to think about it.
    ///
    /// Stored as two fields because that is what round-trips through JSON without inventing a
    /// custom coder; read as one value everywhere else, so no call site has to remember that a
    /// nil expiry means two different things depending on the boolean beside it.
    var pause: CapturePauseState {
        get { CapturePauseState(isPaused: capturePaused, expiresAt: capturePauseExpiresAt) }
        set {
            capturePaused = newValue.isPaused
            capturePauseExpiresAt = newValue.expiresAt
        }
    }

    /// Sets the user's own names and publishes them to the extraction layer in one step.
    ///
    /// The two must never disagree: `RuleExtractor` reads `UserNames.current`, and a name that
    /// only reached the config file would do nothing until the next launch.
    mutating func setOwnNames(_ names: [String]) {
        let cleaned = UserNames(names)
        ownNames = cleaned.entered
        UserNames.install(cleaned)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case capture, restraint, brain, voice, reminders, preferredBrain
        case retentionDays, capturePaused, capturePauseExpiresAt, hotkeyCode, hotkeyModifierRaw
        case ownNames, vaultPath, hasCompletedOnboarding, recoveryKeyAcknowledged
        case journalInvitation, openAtLogin, allowWeather, allowUpdateCheck
        case lastJournalInvitation
    }

    /// Decodes tolerantly, filling in defaults for any key the file omits.
    ///
    /// A `config.json` written before a setting existed must still load: the alternative is
    /// `load()` silently falling back to a wholly default config and wiping the user's exclusion
    /// list, hotkey and retention the first time a new field ships.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        capture = try c.decodeIfPresent(CaptureConfig.self, forKey: .capture) ?? defaults.capture
        restraint = try c.decodeIfPresent(RestraintConfig.self, forKey: .restraint) ?? defaults.restraint
        brain = try c.decodeIfPresent(BrainConfig.self, forKey: .brain) ?? defaults.brain
        voice = try c.decodeIfPresent(VoiceConfig.self, forKey: .voice) ?? defaults.voice
        // Absent in every config.json written before Reminders sync shipped, and absent means
        // off. An upgrade must never be the thing that starts writing into a task list.
        reminders = try c.decodeIfPresent(RemindersConfig.self, forKey: .reminders) ?? defaults.reminders
        preferredBrain = try c.decodeIfPresent(BrainKind.self, forKey: .preferredBrain) ?? defaults.preferredBrain
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? defaults.retentionDays
        capturePaused = try c.decodeIfPresent(Bool.self, forKey: .capturePaused) ?? defaults.capturePaused
        capturePauseExpiresAt = try c.decodeIfPresent(Date.self, forKey: .capturePauseExpiresAt)
        hotkeyCode = try c.decodeIfPresent(UInt16.self, forKey: .hotkeyCode) ?? defaults.hotkeyCode
        hotkeyModifierRaw = try c.decodeIfPresent(UInt.self, forKey: .hotkeyModifierRaw) ?? defaults.hotkeyModifierRaw
        ownNames = try c.decodeIfPresent([String].self, forKey: .ownNames) ?? defaults.ownNames
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath) ?? defaults.vaultPath
        // `true`, not `defaults.hasCompletedOnboarding`, and the difference is the whole point.
        // A config file that exists but predates this key was written by somebody who already
        // came through the old onboarding; taking the struct's default would march every
        // existing user back through a welcome screen on upgrade. Only a machine with no
        // config file at all (a genuinely new install) gets the `false` from `init`.
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? true
        // `false`, and deliberately the opposite reasoning to the line above. A config file
        // that predates this key belongs to somebody who has never been shown a recovery key,
        // because there was nothing to show them until encryption shipped. Defaulting to true
        // here would mean every existing user silently keeps a memory only their keychain can
        // open, which is the failure this whole flag exists to prevent.
        recoveryKeyAcknowledged = try c.decodeIfPresent(Bool.self, forKey: .recoveryKeyAcknowledged) ?? false
        journalInvitation = try c.decodeIfPresent(Bool.self, forKey: .journalInvitation) ?? defaults.journalInvitation
        // `true` for an existing config file as well as a new one, and that is a deliberate
        // change of behaviour on upgrade. Every user who installed Memoir before this shipped
        // has a Mac that silently stops recording at every restart; leaving them opted out
        // would keep them there, and the switch is one line away in Settings for anyone who
        // disagrees.
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? defaults.openAtLogin
        // `false` for an existing config file, and the opposite reasoning to the line above.
        // That one turns on something the user already consented to: recording their own Mac.
        // This one would start a kind of outbound request they have never agreed to, on
        // upgrade, silently. Off unless somebody says otherwise.
        allowWeather = try c.decodeIfPresent(Bool.self, forKey: .allowWeather) ?? false
        // `true` for an existing config file, unlike the weather line above, because this is
        // not a new kind of request to that user: PRIVACY.md has described the update check as
        // the one thing that goes out unasked since before they installed. What was missing was
        // the code that made it true. Defaulting an upgrade to `false` would leave exactly the
        // people who have been running Memoir longest as the ones who never hear about a fix.
        allowUpdateCheck = try c.decodeIfPresent(Bool.self, forKey: .allowUpdateCheck) ?? true
        lastJournalInvitation = try c.decodeIfPresent(Date.self, forKey: .lastJournalInvitation)

        // Retention: a stored 60 is the old default rather than a choice anyone made, and the
        // product decision is now to keep everything. Migrate that one value and leave every
        // other number alone, because any other number was typed by somebody on purpose.
        if retentionDays == 60 { retentionDays = 0 }
    }

    /// Loads from disk, falling back to defaults, then merges the Keychain key in.
    static func load() -> AppConfig {
        var config: AppConfig
        var migrated = false
        if let data = try? Data(contentsOf: Paths.configURL()),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
            // `init(from:)` rewrites a stored 60 to 0. Persist that, or the file keeps saying
            // sixty days for ever while the app behaves as if it says nothing, and the next
            // person to open config.json is told something untrue about their own memory.
            if let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               stored["retentionDays"] as? Int == 60, config.retentionDays == 0 {
                migrated = true
            }
        } else {
            config = AppConfig()
        }
        config.brain.anthropicAPIKey = BrainKeychain.load()
        // The one channel between this file and the extraction layer. MemoirKit has no idea a
        // config file exists, and loading is the only moment the app knows what is in it.
        UserNames.install(UserNames(config.ownNames))
        if migrated {
            config.save()
            Log.shared.info("retention migrated from the old 60-day default to keeping everything")
        }
        return config
    }

    /// Writes to disk. The API key is stripped by `BrainConfig`'s own encoder.
    ///
    /// `ownNames` is written from the live value rather than from this instance. The app
    /// loads one config at launch and hands copies to the settings window, while onboarding
    /// asks what the user is called *after* that: saving a hotkey change from a copy that
    /// predates the question would silently wipe the names they had just typed.
    func save() {
        do {
            var out = self
            out.ownNames = UserNames.current.entered
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(out).write(to: Paths.configURL(), options: .atomic)
        } catch {
            Log.shared.error("could not save config: \(error)")
        }
    }
}

/// Draws the honesty panel. **Observes the count; never produces it.**
///
/// This class used to own the number and increment it in the ask handler from
/// `reply.brain.isCloud`, i.e. inferred from which brain answered, after it answered, in a
/// target the networking code cannot import. Every send site outside that one handler was
/// therefore uncounted. `MemoirKit.OutboundMonitor` now owns the truth and is incremented by
/// the brains themselves at the moment they send; this is a view model over it, so the panel
/// can only ever under-report if a *brain* forgets, not if a caller does.
@MainActor
final class OutboundCounter: ObservableObject {
    static let shared = OutboundCounter()
    @Published private(set) var count: Int = 0
    @Published private(set) var lastDestination: String?

    private init() {
        OutboundMonitor.shared.observe { [self] snapshot in
            Task { @MainActor in self.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: OutboundMonitor.Snapshot) {
        count = snapshot.count
        lastDestination = snapshot.lastDestination
    }
}
