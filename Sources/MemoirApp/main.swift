import AppKit
import SwiftUI
import MemoirKit

/// Memoir's entry point.
///
/// A menu-bar-notch app: no dock icon, no main window, no status item. The black band
/// anchored to the notch is Memoir's entire presence. Everything else (Memory, Settings,
/// Onboarding) is a window it can summon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = AppConfig.load()

    private var store: Store!
    private var captureLoop: CaptureLoop!
    private var memory: MemoryService!
    /// What unlocking the encrypted vault did at launch. Held so the recovery key can be
    /// shown once, by onboarding, and never again.
    private var vaultOpening: EncryptedVault.Opening?
    private var router: BrainRouter!
    private var restraint: RestraintEngine!

    /// Apple Reminders, for the todos the user writes themselves.
    ///
    /// One instance for the life of the app so its "already written" cache survives between
    /// pushes and a second accept does not produce a second reminder. Built unconditionally
    /// because building one asks for no permission: EventKit prompts on the first write, and
    /// the first write only happens once Settings > Reminders has been switched on.
    private let reminders = RemindersSync.system()

    private var character: CharacterModel!
    private var chat: ChatController!
    private var shell: ShellModel!
    private var brainSwitch: BrainSwitchModel!
    private var notchPanel: NotchPanelController!
    private var promotedWindow: PromotedWindowController!
    private var hotkey: HotkeyManager!

    private var onboardingWindow: NSWindow?
    /// The live onboarding flow, so the permission watcher can tell it the grant arrived.
    private var onboardingFlow: OnboardingFlow?
    /// Whether ``beginRunning()`` has already happened.
    ///
    /// It registers a global hotkey and starts three long-lived tasks, none of which survive
    /// being started twice. Onboarding no longer ends the moment Accessibility is granted, so
    /// the grant and the finish are two separate arrivals that both want the app running.
    private var isRunning = false

    private var memoryModel: MemoryBrowserModel!
    private var settingsModel: SettingsModel!

    private let questionRouter = QuestionRouter()
    private let rewriter = QueryRewriter()
    /// What answered last, when it was not the brain the user asked for. See `noteBrainOutcome`.
    private var degradedFrom: BrainKind?
    private var nudgeScanner: NudgeScanner!
    private var maintenanceTask: Task<Void, Never>?
    private var permissionWatch: Task<Void, Never>?
    private var nudgeTask: Task<Void, Never>?

    /// Watches whether captures are actually landing. See ``CaptureHealth``.
    private var healthTask: Task<Void, Never>?
    private var healthJudge = CaptureHealthJudge()
    /// When the band was last widened about a fault, so it can nag again without nagging often.
    private var lastHealthAnnouncement: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        // Same category of repair, one layer out. Any agent client the user connected holds an
        // absolute path to this bundle, and moving or updating the app leaves every one of them
        // launching a binary that is no longer there. Only entries that already exist are
        // repointed; nothing new is ever added without being asked for.
        //
        // Off the main thread because `~/.claude.json` is not small (60 KB on the machine this
        // was written on, and it grows with the number of projects), and nothing at launch
        // should wait on re-serialising it.
        if let mcpBinary = MCPInstaller.bundledBinary() {
            Task.detached(priority: .utility) {
                for outcome in MCPInstaller.repairStalePaths(binary: mcpBinary) where outcome.succeeded {
                    Log.shared.info("repointed \(outcome.surface.name) at \(mcpBinary.path)")
                }
            }
        }

        // Unlock before anything opens the database. On first run this creates the encrypted
        // container, moves an existing plaintext memory into it, and hands back the one and
        // only chance to show the recovery key.
        var opening = EncryptedVault.open()

        // A locked vault is not a reason to start a second memory beside it. Ask for the
        // recovery key, and keep asking until it opens or the user chooses otherwise:
        // `VaultKey.restore(fromRecoveryKey:)` was written and tested and, until now, called
        // from nothing at all, so the one thing a user in this position needed was the one
        // thing the app could not do.
        while opening.locked {
            switch presentRecoveryKeyPrompt(reason: opening.failure) {
            case .quit:
                // Terminate, not `return`. Returning leaves the process alive as an accessory
                // with no window, no menu bar item and no capture loop: a Memoir that is
                // running and recording nothing, which is the one failure this product cannot
                // have. Found by watching a launch after a re-sign: the app was in the process
                // list for four minutes and had written nothing since the previous run.
                Log.shared.error("user chose to quit rather than unlock; terminating")
                NSApp.terminate(nil)
                return
            case .startFresh:
                // The fork, but chosen rather than stumbled into. The container is left exactly
                // where it is: whoever finds their recovery key next week should still be able
                // to open it, and nothing here may make that impossible.
                Log.shared.error("user chose to start a new memory; the locked container is left untouched")
                opening = EncryptedVault.startingFresh(besides: opening)
            case .restore(let typed):
                do {
                    try VaultKey.restore(fromRecoveryKey: typed)
                    opening = EncryptedVault.open()
                    if opening.locked {
                        presentRecoveryKeyRejected(
                            "That is a valid recovery key, but it does not open this memory."
                        )
                    }
                } catch {
                    let reason = (error as? MemoirError)?.localizedDescription
                        ?? error.localizedDescription
                    presentRecoveryKeyRejected(reason)
                }
            }
        }
        vaultOpening = opening

        do {
            // The app is the only caller allowed to change the schema, because it is the
            // only one that can tell the user it happened and survive the result.
            store = try Store(path: opening.databaseURL, mayMigrate: true)
        } catch {
            presentFatal("Memoir could not open its database.\n\n\(error.localizedDescription)")
            return
        }

        router = BrainRouter(preferred: config.preferredBrain, store: store, config: config.brain)
        // Rules first and always, then the model pass on top of what they found.
        //
        // `LLMExtractor` was written, tested and documented as part of this pipeline and then
        // never actually handed to a `MemoryService`, so every entity the shipped app has ever
        // stored came from the rules alone. The doc was a year ahead of the wiring.
        //
        // Through `RouterBackedBrain`, never a concrete brain: extraction sees more of a
        // person's screen than anything else here, so it is the last stage that should be able
        // to route around the `allowCloud` veto. The router owns that decision and keeps it.
        memory = MemoryService(
            store: store,
            extractors: [RuleExtractor(), LLMExtractor(brain: RouterBackedBrain(router: router))]
        )
        restraint = RestraintEngine(config: config.restraint)

        character = CharacterModel()

        if let failure = opening.failure {
            // Never silent. A user who believes their memory is encrypted and is wrong is worse
            // off than one who was told plainly that it is not. Said after the character exists,
            // not before: the earlier version of this line spoke through a nil model.
            Log.shared.error("running unencrypted: \(failure)")
            character.say("Your memory is not encrypted. Settings → Data explains why.",
                          expression: .concerned, duration: 10)
        }
        checkPreferredBrainAtLaunch()
        // The push path is off until this argument is supplied, which is exactly how it
        // shipped the first time: PushIntent, previewPush and commitPush were all written,
        // tested and reachable from nothing. Tests prove code works; they do not prove
        // anyone calls it.
        chat = ChatController(
            voice: config.voice,
            push: ChatController.PushBridge(
                route: { [weak self] question in
                    guard let self else { return .recall }
                    return await self.routeCategory(question)
                },
                preview: { [weak self] question in
                    await self?.previewPush(question)
                },
                // The only write in the push path, and it runs only from Return or the Save
                // button on the confirm card. CF-51 is that separation.
                commit: { [weak self] intent in
                    guard let self else { return }
                    let saved = try await self.commitPush(intent)
                    await self.startReminderSync(for: saved)
                }
            ),
            character: character
        ) { [weak self] question in
            await self?.answer(question)
        }

        shell = ShellModel(
            store: store,
            memory: memory,
            character: character,
            chat: chat,
            hasAccessibility: Permissions.hasAccessibility()
        )
        // An expiry that passed while Memoir was closed is honoured here, before anything
        // reads the flag. Pausing for an hour and then rebooting must not come back to a Mac
        // that is still paused. That is the same silent gap in a friendlier hat.
        settlePause()
        shell.setCapturePaused(config.pause.isPaused(at: Date()))
        shell.setPauseLabel(config.pause.label(at: Date()))
        shell.onPromote = { [weak self] pane in self?.promote(pane) }
        shell.onTogglePause = { [weak self] in self?.toggleCapture() }
        shell.onPauseFor = { [weak self] choice in self?.pauseCapture(choice) }
        shell.onResume = { [weak self] in self?.resumeCapture() }
        shell.onGrantPermission = { [weak self] in self?.showPermissionHelp() }
        shell.onDemote = { [weak self] in self?.promotedWindow.demote() }
        // Settings, on the pane the caller named. The section lives on `SettingsModel` so a
        // link can aim at a switch rather than at a window.
        shell.onOpenSettings = { [weak self] section in
            guard let self else { return }
            self.settingsModel.section = section
            self.promote(.settings)
        }
        chat.onPushSaved = { [weak self] intent in
            guard let self else { return }
            // Saved from the open band the card itself is the receipt; this covers the
            // collapse-right-after case, where the strip briefly says what just landed.
            self.shell.presentMoment(.saved(title: intent.title, due: intent.dueAt))
        }
        chat.onCommand = { [weak self] command in self?.runChatCommand(command) }

        // The conversation's brain toggle. Selecting persists the preference exactly
        // as Settings does; unconfigured brains sit greyed until Settings fills them in.
        let brains = BrainSwitchModel(selection: config.preferredBrain)
        brains.onSelect = { [weak self] kind in
            guard let self else { return }
            self.config.preferredBrain = kind
            self.config.save()
            self.settingsModel?.config = self.config
            let router = self.router!
            Task { await router.setPreferred(kind) }
        }
        brains.refresh(config: config, apiKeySaved: BrainKeychain.hasKey())
        chat.brains = brains
        self.brainSwitch = brains
        nudgeScanner = NudgeScanner(store: store, restraint: restraint)
        shell.onNudgeDismissed = { [weak self] nudge in
            guard let self else { return }
            let restraint = self.restraint!
            Task { await restraint.recordDismissal(nudge, now: Date()) }
        }

        notchPanel = NotchPanelController(shell: shell, character: character, chat: chat)
        hotkey = HotkeyManager { [weak self] in self?.shell.toggleOpen() }

        memoryModel = MemoryBrowserModel(store: store)
        settingsModel = SettingsModel(
            config: config,
            store: store,
            router: router,
            restraint: restraint,
            memory: memory
        ) { [weak self] updated in
            self?.applyConfig(updated)
        }
        promotedWindow = PromotedWindowController(
            shell: shell,
            memoryModel: memoryModel,
            settingsModel: settingsModel
        )

        let source = AccessibilityCapture(config: config.capture)
        captureLoop = CaptureLoop(source: source, store: store, config: config.capture)

        // The band appears immediately: chat works without any permission; the
        // capture-dependent panes explain themselves until Accessibility is granted.
        notchPanel.show()

        // Bring the login item in line with the setting on every launch, not only when the
        // switch is flipped. See ``LoginItem/reconcile(wanted:)``.
        LoginItem.reconcile(wanted: config.openAtLogin)

        // Health watching starts before capture does and never stops. A missing permission is
        // not a reason to postpone the indicator: it is the first thing the indicator has to
        // report, and the version of this app without it looked perfectly healthy while doing
        // nothing at all.
        startHealthWatch()

        // Capture starts the moment it legally can, whether or not the user is still reading
        // the welcome. Onboarding is a conversation, not a gate: a granted permission going
        // unused while somebody types their name is a minute of their day gone unrecorded.
        let granted = Permissions.hasAccessibility()
        if granted { beginRunning() }
        // The third condition is the upgrade path. Somebody who set this Mac up before
        // encryption existed has a key they have never been shown, and hasCompletedOnboarding
        // is true for them, so nothing would ever offer it. Reopen first run for that one step.
        let owesRecoveryKey = !config.recoveryKeyAcknowledged && VaultKey.exists()
        if !config.hasCompletedOnboarding || !granted || owesRecoveryKey { showOnboarding() }
        if !granted { watchForPermission() }
    }

    /// An agent app shows no menu bar, so it is easy to forget it needs a menu at all,
    /// but ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z are *menu key equivalents*. Without an Edit menu they
    /// never reach the text field and copy/paste silently does nothing everywhere in Memoir.
    /// The items are left with `nil` targets on purpose: that sends them down the
    /// responder chain to whatever field is focused.
    private func installMainMenu() {
        let edit = NSMenu(title: "Edit")
        let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Paste and Match Style",
             #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for (title, action, key, modifiers) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }

        let editItem = NSMenuItem()
        editItem.submenu = edit

        // macOS always treats the first submenu as the application menu and never routes
        // key equivalents through it, so Edit cannot be first.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Memoir")

        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTask?.cancel()
        maintenanceTask?.cancel()
        permissionWatch?.cancel()
        nudgeTask?.cancel()
        hotkey?.invalidate()
        notchPanel?.invalidate()
        shell?.invalidate()
        let loop = captureLoop
        Task { await loop?.stop() }
        // Close the encrypted volume last, and never forcibly: SQLite may still be
        // checkpointing, and pulling the volume out from under it truncates the WAL.
        EncryptedVault.close()
    }

    // MARK: - Lifecycle

    private func beginRunning() {
        guard !isRunning else { return }
        isRunning = true
        // Pay the on-device model's cold start now, not on the user's first question.
        Log.shared.info("on-device generation timeout: \(AppleOnDeviceBrain.effectiveTimeout)s")
        Task.detached(priority: .utility) { await AppleOnDeviceBrain().prewarm() }
        shell.setAccessibility(true)
        hotkey.register(
            keyCode: config.hotkeyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: config.hotkeyModifierRaw)
        )
        if !config.pause.isPaused(at: Date()) {
            let loop = captureLoop
            Task { await loop?.start() }
        }
        startMaintenance()
        startNudgeLoop()
        // Speech arrives as a widening of the collapsed band, not a bubble.
        character.say("Hello. I'm listening quietly.", expression: .idle, duration: 4)
    }

    // MARK: - Capture health

    /// How often the verdict is recomputed. Fifteen seconds: fast enough that a revoked
    /// permission is on screen within a quarter minute, slow enough to cost nothing.
    private static let healthInterval: TimeInterval = 15

    /// How long a fault stays quiet before the band says it again.
    ///
    /// The strip shows the fault continuously, so this is only the *interruption*. Half an
    /// hour is the compromise between the user's own words (finding out a fortnight later is
    /// a disaster) and the certainty that anything more frequent gets learned and ignored.
    private static let healthRenagInterval: TimeInterval = 1_800

    /// The loop that answers "is this thing actually recording".
    ///
    /// Everything it needs is cheap: a permission check, an idle query, the frontmost bundle
    /// ID, and a counter the loop already keeps. No new capture-path bookkeeping, and nothing
    /// here reads the screen.
    private func startHealthWatch() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.sampleHealth() }
                try? await Task.sleep(for: .seconds(Self.healthInterval))
            }
        }
    }

    private func sampleHealth() {
        // Before the verdict, not after: a pause whose time is up must be over by the time
        // anything asks whether capture is running, or the notch reports "Paused" for up to
        // fifteen seconds after it has resumed.
        if settlePause() { applyConfig(config) }
        let paused = config.pause.isPaused(at: Date())
        let capture = config.capture
        let loop = captureLoop
        Task { [weak self] in
            let running = await loop?.isRunning ?? false
            let written = await loop?.capturesWritten ?? 0
            let sample = CaptureHealthProbe.sample(
                paused: paused,
                loopRunning: running,
                capturesWritten: written,
                config: capture
            )
            await MainActor.run { self?.applyHealth(sample) }
        }
    }

    private func applyHealth(_ sample: CaptureHealthSample) {
        let before = healthJudge.health
        let after = healthJudge.observe(sample, elapsed: Self.healthInterval)

        // The permission flag is re-read here rather than only at launch. It used to be set
        // once and never again, so a permission revoked after startup left the app believing
        // it still had it for the rest of the session, including in the pane copy that tells
        // the user everything is fine.
        shell.setAccessibility(sample.accessibilityGranted)
        shell.setPauseLabel(config.pause.label(at: Date()))
        shell.setHealth(after)
        character.setHealth(after)
        settingsModel?.health = after

        guard after != before else {
            renagIfStillBroken(after)
            return
        }
        Log.shared.info("capture health: \(before) → \(after)")

        if let sentence = after.announcement {
            lastHealthAnnouncement = Date()
            shell.presentMoment(.health(after, sentence))
        } else if before.isFault {
            // Recovery is announced too. Somebody who was told their memory had stopped is
            // owed the sentence that says it started again, or the only way to find out is to
            // keep checking, which is the habit this feature is supposed to remove.
            lastHealthAnnouncement = nil
            shell.presentMoment(.health(after, "Logging again"))
        }
    }

    /// Says it again, every half hour, for as long as it is still true.
    private func renagIfStillBroken(_ health: CaptureHealth) {
        guard let sentence = health.announcement, health.isFault else { return }
        let last = lastHealthAnnouncement ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.healthRenagInterval else { return }
        lastHealthAnnouncement = Date()
        shell.presentMoment(.health(health, sentence))
    }

    /// Drives the scanner once a minute. The engine inside it holds every rule
    /// (thresholds, quiet hours, focus suppression, backoff, caps), so this loop is
    /// deliberately dumb: ask, and deliver whatever survives as a band moment.
    private func startNudgeLoop() {
        nudgeTask?.cancel()
        let scanner = nudgeScanner
        nudgeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                guard await scanner?.scan(now: Date()) != nil else { continue }
                await MainActor.run {
                    guard let self else { return }
                    // The band may say something about itself. It may never say something
                    // about your life unasked.
                    //
                    // This used to widen the band and announce the commitment. A strip that
                    // volunteers "you promised Marco you would read his draft" while somebody
                    // is in the middle of another thought is not a memory, it is a supervisor.
                    // The distance between noticing and keeping score is the whole
                    // product. So the mark lights, and the sentence waits until it is opened.
                    self.character.set(.alert, for: 8)
                }
            }
        }
    }

    /// Consolidation every 5 minutes, retention once a day.
    private func startMaintenance() {
        maintenanceTask?.cancel()
        let memory = self.memory
        // The vault, once, at startup: the user's own note titles should be in memory
        // before the first question, not after the first maintenance tick.
        if let vaultPath = config.vaultPath {
            Task { [weak self] in
                _ = try? await self?.memory?.importVault(at: URL(fileURLWithPath: vaultPath))
            }
        }
        // Contacts, Calendar and Photos at startup, then hourly below.
        //
        // These used to be read exactly once, from the setup window, which meant a contact added
        // the following week never arrived and the calendar stopped on install day. Only sources
        // already granted are read (`LifeImporter.granted` checks status and never asks), so
        // this cannot produce a permission prompt out of nowhere.
        Task { [weak self] in
            await self?.refreshLifeSources()
        }
        // Retention at startup, before the loop.
        //
        // It used to run only on the 288th five-minute tick (24 hours of continuous uptime)
        // and never at launch, so anyone who quits Memoir overnight or reboots daily never had
        // retention applied at all and accumulated captures past the window forever. The
        // setting said 60 days and the database kept everything.
        Task { [weak self] in
            guard let days = self?.retentionDays else { return }
            do {
                let removed = try await memory?.applyRetention(captureDays: days) ?? 0
                if removed > 0 { Log.shared.info("retention removed \(removed) captures at startup") }
            } catch {
                Log.shared.error("retention failed at startup: \(error)")
            }
        }
        // Whether a newer Memoir exists, once at launch and once a day in the loop below.
        //
        // This was written, tested and documented as "the one thing that goes out without you
        // asking" long before anything called it, so PRIVACY.md described a request the app
        // never made. Nothing self-updates: it asks, and the answer becomes a band moment the
        // user can click. See `UpdateCheck` for why replacing our own binary is not on offer.
        checkForUpdate()
        runLaunchCleanup()

        maintenanceTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }

                let since = Date().addingTimeInterval(-3_600)
                if let touched = try? await memory?.consolidate(since: since), touched > 0 {
                    Log.shared.info("consolidated \(touched) entities")
                }

                // Re-read the vault every hour: cheap (mtime-keyed idempotent pass) and
                // keeps edited notes canon without asking the user to press anything.
                if ticks % 12 == 0, let vaultPath = self?.config.vaultPath {
                    _ = try? await memory?.importVault(at: URL(fileURLWithPath: vaultPath))
                }

                // The life sources on the same hourly beat, over a short window rather than
                // the decade the first run reads.
                if ticks % 12 == 0 {
                    await self?.refreshLifeSources()
                }

                // The invitation is checked every tick and offered at most once a day. Checking
                // hourly would mean a Mac woken at 21:30 waits until 22:00 to be asked.
                await MainActor.run { self?.offerJournalInvitation() }

                ticks += 1
                if ticks % 288 == 0 {   // roughly once a day
                    await MainActor.run { self?.checkForUpdate() }
                    // The task inherits this method's main-actor isolation, so no hop is needed.
                    guard let days = self?.retentionDays else { return }
                    _ = try? await memory?.applyRetention(captureDays: days)
                }
            }
        }
    }

    /// Asks whether a newer Memoir exists, and says so once if it does.
    ///
    /// Three rules, all enforced here rather than in copy:
    ///
    /// - **The switch is obeyed before the request is built**, not after it returns. A check
    ///   that fires and then discards its answer has still left the machine, and `allowUpdateCheck`
    ///   would be a lie to anyone reading the outbound count.
    /// - **Silence on every ordinary failure.** `UpdateCheck.latest` returns nil for no network,
    ///   a bad manifest, or the same version. Interrupting somebody to report that Memoir could
    ///   not check is worse than saying nothing.
    /// - **Once per launch per version.** The daily beat calls this again, and without the guard
    ///   a Mac left running for a fortnight would be told about the same release fourteen times.
    private func checkForUpdate() {
        guard config.allowUpdateCheck else { return }
        Task { [weak self] in
            guard let release = await UpdateCheck.latest() else { return }
            await MainActor.run {
                guard let self, self.announcedUpdate != release.version else { return }
                self.announcedUpdate = release.version
                Log.shared.info("update available: \(release.version)")
                self.shell.presentMoment(.update(release))
            }
        }
    }

    /// The version already announced in this run, so the daily beat does not repeat itself.
    private var announcedUpdate: String?

    /// The hour the nightly invitation becomes due. Evening, because the entry people actually
    /// write is the one before bed, and an invitation at 11am interrupts work to ask about a day
    /// that has not happened yet.
    private static let invitationHour = 20

    /// Offers to write, once a day, and says nothing about the user.
    ///
    /// Three rules from the product notes, all enforced here rather than in copy:
    ///
    /// - **It invites, it never discloses.** The sentence is `JournalPrompt.invitation`, which
    ///   carries no information at all. *"You were on the listings again"* is a disclosure and
    ///   waits until the user has opened the app themselves.
    /// - **It never notices a missed day.** The wording does not change if nothing has been
    ///   written for a month, and nothing counts streaks. Skip a year and this is identical.
    /// - **The face does not react.** `.idle`, not the `say` default of `.happy`. Somebody may be
    ///   about to write about the worst day of their year.
    private func offerJournalInvitation() {
        guard config.journalInvitation else { return }
        let now = Date()
        let calendar = Calendar.current
        guard calendar.component(.hour, from: now) >= Self.invitationHour else { return }

        // Quiet hours win. The default window is 22:00 to 07:00 so the invitation normally has
        // two hours to itself, but somebody who set silence from 20:00 has already answered this
        // question and must not be asked again by a different feature.
        //
        // It is deliberately *not* run through `RestraintEngine`, which would also count it
        // against the daily nudge cap and the cooldown: this is one invitation a day that the
        // user switched on for itself, and letting unrelated nudges crowd it out would make the
        // setting mean nothing on a busy day.
        guard !config.restraint.quietHours.contains(now, calendar: calendar) else { return }

        if let last = config.lastJournalInvitation, calendar.isDate(last, inSameDayAs: now) {
            return
        }
        // Not while the band is already open and being used, and not over a question in progress.
        guard shell.mode != .open else { return }

        config.lastJournalInvitation = now
        config.save()
        character.say(JournalPrompt.invitation, expression: .idle, duration: 8)
    }

    /// How far back the periodic life pass looks.
    ///
    /// A month, not a decade. Long enough that a machine switched off for three weeks still
    /// catches up on everything it missed; short enough that the pass is a few milliseconds of
    /// work rather than a full library walk every hour.
    private static let lifeRefreshWindow: TimeInterval = 30 * 24 * 60 * 60

    /// Re-reads whichever of Contacts, Calendar and Photos the user has already granted.
    ///
    /// Silent by design. It never asks for a permission (`LifeImporter.granted` reports status
    /// without prompting), because a system dialog appearing an hour into a session, with no
    /// click to explain it, is exactly the behaviour that gets a capture app distrusted.
    private func refreshLifeSources() async {
        let granted = LifeImporter.granted
        guard !granted.isEmpty, let memory else { return }
        do {
            _ = try await memory.importLife(
                sources: granted,
                since: Date().addingTimeInterval(-Self.lifeRefreshWindow)
            )
        } catch {
            Log.shared.error("life refresh failed: \(error)")
        }
    }

    private var retentionDays: Int { config.retentionDays }

    /// One-time repairs for an installation that predates a fix.
    ///
    /// Changing a default only ever helps the next person to install. Everything below exists
    /// because a shipped build wrote something it should not have, and the correction has to
    /// reach the machines that already have it:
    ///
    /// - captures *and sessions* from apps added to the exclusion list after this profile was
    ///   created. Sessions were missed until they were found on a real installation: the
    ///   captures were gone and 443 session rows were not, so the purge looked done and the
    ///   record of a credential sheet being frontmost for ten minutes was still there. This
    ///   pass runs unconditionally on every launch and the purge is idempotent, so the fix
    ///   clears the existing rows by itself — no separate repair,
    /// - the pre-migration snapshots, which nothing has ever deleted and which accumulate one
    ///   full plaintext copy of the memory per schema version,
    /// - a diagnostic log with no rotation, which on a real installation had reached 5.8 MB
    ///   and, while the `ax-dump` marker was present, contained on-screen text.
    ///
    /// Idempotent and quiet: each pass is a no-op once there is nothing left to repair.
    private func runLaunchCleanup() {
        guard let store = self.store else { return }
        // Deliberately NOT the whole exclusion list: only the identifiers Memoir added to the
        // defaults on the user's behalf. Purging everything on the list would quietly turn
        // Settings → Capture → Exclude into a retroactive delete button: a user excluding an
        // app from today onward would lose every capture they already had from it, having
        // been shown nothing that said so.
        let mistakes = CaptureConfig.exclusionsAdded(since: 1)
        Task.detached(priority: .utility) {
            do {
                let removed = try await store.purge(fromBundleIDs: mistakes)
                if removed > 0 {
                    Log.shared.info("launch cleanup removed \(removed) captures from newly excluded apps")
                }
                // No `else`: the store logs its own line covering sessions, and on an
                // installation whose captures were already purged that is the only line
                // there is to write.

                // The photo library was imported twice on any machine whose timezone moved,
                // because the day key was rendered in UTC from a local midnight. Clears the
                // twins and fills in the dates that were being recomputed at read time.
                do {
                    let repair = try await store.repairImportedDays()
                    if repair.removed > 0 || repair.dated > 0 {
                        Log.shared.info(
                            "launch cleanup repaired \(repair.removed) duplicate imported days, "
                            + "dated \(repair.dated) rows")
                    }
                } catch {
                    Log.shared.warn("launch cleanup could not repair imported days: \(error)")
                }

                // Journal entries written before schema v12 carry no filed date, so nothing
                // could ask for them. Fills it once from the accidental rule.
                do {
                    let filed = try await store.repairJournalFiling()
                    if filed > 0 { Log.shared.info("launch cleanup filed \(filed) journal entries") }
                } catch {
                    Log.shared.warn("launch cleanup could not file journal entries: \(error)")
                }

                // First names imported as aliases are a licence to attach one person's text
                // to another. The importer stopped writing them; this takes back the ones it
                // already wrote.
                do {
                    let dropped = try await store.repairGivenNameAliases()
                    if dropped > 0 { Log.shared.info("launch cleanup removed \(dropped) given-name aliases") }
                } catch {
                    Log.shared.warn("launch cleanup could not repair aliases: \(error)")
                }

                // Commitments read off a browser tab, written while an allowlist of hosts was
                // exempt from the reading rule. The extractor is fixed; this is the backlog.
                do {
                    let demoted = try await store.repairBrowserCommitments(
                        browserBundleIDs: RuleExtractor.browserBundleIDs)
                    if demoted > 0 {
                        Log.shared.info("launch cleanup demoted \(demoted) browser-read commitments")
                    }
                } catch {
                    Log.shared.warn("launch cleanup could not repair commitments: \(error)")
                }
            } catch {
                Log.shared.warn("launch cleanup could not purge excluded apps: \(error)")
            }

            // Keep the most recent snapshot: one spare copy is insurance against a bad
            // upgrade, four is just a second database nobody knows about.
            let reclaimed = await store.reapMigrationBackups(keepMostRecent: 1)
            if reclaimed > 0 {
                Log.shared.info("launch cleanup reclaimed \(reclaimed) bytes of migration backups")
            }

            Log.shared.trimIfOversized()
        }
    }

    /// Polls for Accessibility being granted so the user does not have to relaunch.
    private func watchForPermission() {
        permissionWatch?.cancel()
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard Permissions.hasAccessibility() else { continue }
                await MainActor.run {
                    guard let self else { return }
                    // Tell the flow rather than tearing it down. This used to close the
                    // window, which is why onboarding could only ever be the permission
                    // screen: every step after it was destroyed by the grant it was waiting
                    // for, mid-sentence.
                    self.onboardingFlow?.accessibilityGranted = true
                    self.beginRunning()
                    // Unless there is no flow to continue: a user who finished onboarding
                    // long ago and reopened this only to fix the permission has read it all
                    // before, and the fix is the whole errand.
                    if self.config.hasCompletedOnboarding {
                        self.onboardingWindow?.close()
                        self.onboardingWindow = nil
                        self.onboardingFlow = nil
                    }
                }
                return
            }
        }
    }

    private func applyConfig(_ updated: AppConfig) {
        config = updated
        LoginItem.reconcile(wanted: updated.openAtLogin)
        let loop = captureLoop
        let newCapture = updated.capture
        // Asked of the clock, not of the stored flag. A config saved with an hour's pause on
        // it is still "paused" as a boolean an hour later, and starting the loop is the one
        // decision here that must never be made from a stale answer.
        let paused = updated.pause.isPaused(at: Date())
        Task {
            await loop?.updateConfig(newCapture)
            if paused { await loop?.stop() } else { await loop?.start() }
        }
        hotkey.register(
            keyCode: updated.hotkeyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: updated.hotkeyModifierRaw)
        )
        chat.updateVoiceConfig(updated.voice)
        shell.setCapturePaused(paused)
        shell.setPauseLabel(updated.pause.label(at: Date()))
        // Settings may have configured or un-configured a brain; the toggle follows.
        brainSwitch?.refresh(config: updated, apiKeySaved: BrainKeychain.hasKey())
    }

    // MARK: - Chat commands

    /// The one verb the chat can do without a brain: navigation.
    private func runChatCommand(_ command: ChatCommand) -> ChatController.CommandOutcome? {
        switch command {
        case .navigate(let intent):
            // Navigation is a sentence: the pane switch is the whole answer.
            switch intent {
            // "todos" still parses as a thing to say: commitments did not stop existing,
            // they moved to the person they were promised to.
            case .todos: shell.open(pane: .portrait)
            case .today: shell.openToday()
            case .notes: shell.openToday()
            case .chat: shell.open(pane: .ask)
            }
            return .navigated
        }
    }

    // MARK: - PUSH

    /// Classifies a message so the chat knows whether it is being asked or told.
    ///
    /// This is the same classification `answer(_:)` performs, so a question pays for it
    /// twice. Measured at ~4ms when the embedding stage is confident, which is most of the
    /// time; the escalation path is the expensive one and is rare by construction. Worth it:
    /// the alternative is a brain answering "remind me to send the invoice friday" with prose
    /// instead of Memoir writing it down.
    private func routeCategory(_ question: String) async -> QuestionCategory {
        await route(question).routing.category
    }

    /// Normalise the phrasing, then route the normalised form.
    ///
    /// `memoir-ask` has done this for a while and the app never did, so the two surfaces
    /// classified the same sentence differently, which is the very failure `QueryRewriter`
    /// was written to fix, fixed only on the command line. "catch me up", "where was I" and
    /// "pick me up where I left off" mean one thing and were landing in three categories.
    ///
    /// Both callers go through here on purpose. They used to hold two copies of the routing
    /// call, which is how the app came to be missing a stage the CLI had.
    ///
    /// Skipped when a deterministic rule has already settled it, so the fast path never pays
    /// for a model call to learn something this code already knew. And a canonical form
    /// carries its own category, so it is never routed afterwards: routing it would spend a
    /// full model call re-deriving a decision already made.
    private func route(
        _ question: String
    ) async -> (routing: Routing, canonical: QueryRewriter.Canonical?) {
        let certain = QuestionRouter.asksAboutCommitments(question)
        if let canonical = await rewriter.canonical(for: question, alreadyCertain: certain) {
            return (Routing(category: canonical.category, margin: 1, wasFree: true), canonical)
        }
        return (await questionRouter.route(question) { await GuidedClassifier().classify($0) }, nil)
    }

    /// Parses a push phrase without writing anything.
    private func previewPush(_ phrase: String) async -> PushIntent? {
        memory.previewPush(phrase)
    }

    /// Writes a proposal the user has explicitly accepted.
    private func commitPush(_ intent: PushIntent) async throws -> Entity {
        try await memory.commitPush(intent)
    }

    /// Starts the Reminders mirror and returns immediately.
    ///
    /// Deliberately not awaited by the commit path. The confirm card is about the database
    /// write, and that has already happened; the very first sync after the toggle goes on can
    /// sit behind a TCC dialog that nobody answers, and `requestFullAccessToReminders` simply
    /// never calls back until they do. Awaiting it would leave "Saving" on screen forever for
    /// a todo that is already safely stored.
    private func startReminderSync(for entity: Entity) {
        Task { await self.syncAcceptedPush(entity) }
    }

    /// Mirrors an accepted push into Reminders, when the user has asked for that in Settings.
    ///
    /// Never throws and never reports upward. The entity is already in the database by the
    /// time this runs, so a Reminders problem that made the chat say "couldn't save that"
    /// would be a lie about the one thing the user actually cares about. The outcome goes to
    /// the Reminders tab instead, where the message sits next to the switch that turned this
    /// on and next to the button that opens the pane it names.
    private func syncAcceptedPush(_ entity: Entity) async {
        let outcome: ReminderSyncOutcome
        do {
            outcome = try await reminders.push(entity, enabled: config.reminders.syncToReminders)
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        if case .failed(let reason) = outcome {
            Log.shared.warn("reminders sync failed for an accepted push: \(reason)")
        }
        settingsModel.recordReminderOutcome(outcome)
    }

    // MARK: - Answering

    private func answer(_ question: String) async -> (String, BrainKind, TimeInterval)? {
        character.set(.thinking)
        defer { character.set(.idle) }


        do {
            // Classify first: ~4ms of on-device embeddings decides what kind of context to
            // build and which tier can answer, instead of every question getting the same
            // 2000-token dump and the same model call.
            let (routing, canonical) = await route(question)
            Log.shared.debug("routed as \(routing.category.rawValue) (margin \(String(format: "%.3f", routing.margin))\(routing.wasFree ? "" : ", escalated"))")

            // The canonical form is a SEARCH KEY and nothing more. The original question is
            // what reaches the answer prompt and the grounding guards, because the user asked
            // what they asked, and a figure they typed themselves is evidence the rewrite
            // could have dropped.
            let forRetrieval = canonical?.rawValue ?? question
            let packet = try await memory.context(
                for: forRetrieval, budget: 2_000, category: routing.category)
            let reply = try await router.answer(
                question: question, context: packet, category: routing.category,
                canonicalQuestion: canonical?.rawValue)
            // The outbound count is deliberately NOT incremented here. It used to be, from
            // `reply.brain.isCloud`, which counted answers rather than requests, missed every
            // send that did not come through this handler, and missed every send that failed.
            // The brains record their own egress now; see `MemoirKit.OutboundMonitor`.
            // Recorded locally so answer quality can actually be reviewed: the question,
            // what the brain was shown, and what came back.
            AskLog.shared.record(
                question: question,
                answer: reply.text,
                brain: reply.brain,
                latency: reply.latency,
                context: packet
            )
            noteBrainOutcome(reply.brain)
            return (reply.text, reply.brain, reply.latency)
        } catch {
            Log.shared.error("answer failed: \(error)")
            character.set(.concerned, for: 2)
            return nil
        }
    }

    /// Asks at launch whether the chosen brain is reachable, rather than waiting to be asked.
    ///
    /// `noteBrainOutcome` only fires when a question is asked, so a machine that went away
    /// overnight stays hidden until the first question of the day, and that question gets the
    /// worse answer, silently, which is the wrong order. A model on another box fails in ways
    /// that have nothing to do with Memoir: asleep, Tailscale down, the server not started
    /// after a reboot. Those are worth knowing before you rely on it.
    ///
    /// Off the main path deliberately. `available()` probes every brain, and a network one
    /// means a request with a timeout; blocking launch on a sleeping Mac mini would make the
    /// unreachable case also the slow-to-start case.
    private func checkPreferredBrainAtLaunch() {
        let wanted = config.preferredBrain
        guard wanted != .rulesOnly else { return }
        Task { [weak self] in
            guard let self else { return }
            let reachable = await self.router.available().contains(wanted)
            guard !reachable else { return }
            Log.shared.warn("preferred brain \(wanted.rawValue) is not reachable at launch")
            self.character.say(
                "\(wanted.displayName) isn't reachable. Answers will use whatever is left.",
                expression: .concerned, duration: 10)
        }
    }

    /// Says so when the brain that answered is not the brain the user chose.
    ///
    /// `BrainRouter` falls back on purpose and that is the right behaviour: an answer from a
    /// weaker brain beats no answer. But it did it **silently**: the only trace was a
    /// `Log.shared.warn` nobody reads. A model on your own machine that has quietly stopped
    /// being reachable (the box asleep, Tailscale down, LM Studio not running) looks exactly
    /// like a model that is working, except the answers get worse. That is the failure this
    /// product least wants to hide, because the whole argument is that you can check it.
    ///
    /// Said on the CHANGE, not on every answer. A sentence repeated after each question would
    /// be nagging, and *answer when asked, never nag* is a rule here rather than a preference.
    /// Recovery is announced too: a warning you are never told has cleared is one you learn to
    /// ignore.
    ///
    /// `rulesOnly` as the preference is not a degradation: it is someone who asked for no
    /// model at all, and telling them their choice came true would be absurd.
    private func noteBrainOutcome(_ answered: BrainKind) {
        let wanted = config.preferredBrain
        guard wanted != .rulesOnly else { return }

        if answered == wanted {
            if degradedFrom != nil {
                degradedFrom = nil
                character.say("\(wanted.displayName) is answering again.",
                              expression: .idle, duration: 5)
            }
            return
        }

        // One notice per episode. `degradedFrom` holds what actually answered, so a slide from
        // the chosen brain to on-device and then on to no model at all is worth saying twice:
        // those are different situations and the second is much worse.
        guard degradedFrom != answered else { return }
        degradedFrom = answered
        character.say(
            "\(wanted.displayName) didn't answer. Using \(answered.displayName) instead.",
            expression: .concerned, duration: 8)
        Log.shared.warn("preferred brain \(wanted.rawValue) unavailable; answered by \(answered.rawValue)")
    }

    // MARK: - Promotion and windows

    /// The ⤢ control and the window-only panes land here: the band collapses and the
    /// same pane opens in the promoted window: same panes, plus what a band can't hold.
    private func promote(_ pane: ShellModel.PaneID) {
        shell.collapse()
        promotedWindow.show(pane: pane)
    }

    /// Reopens the permission explainer. Reachable from the band's right-click menu at
    /// any time, so a dismissed or buried onboarding window never leaves the app inert.
    private func showPermissionHelp() {
        let granted = Permissions.hasAccessibility()
        if granted {
            shell.setAccessibility(true)
            // Granting the permission is not the same as having finished the welcome. This
            // used to return here unconditionally, which meant a first run interrupted after
            // the permission step could never be resumed: the one menu item that reopens
            // this window refused to, precisely because the user had done the hard part.
            guard !config.hasCompletedOnboarding else { return }
        }
        showOnboarding()
        if !granted { watchForPermission() }
    }

    /// The bare toggle. Pausing means pausing for an hour; resuming means resuming.
    private func toggleCapture() {
        if config.pause.isPaused(at: Date()) { resumeCapture() } else { pauseCapture(.default) }
    }

    /// Switches capture off for a chosen length of time.
    private func pauseCapture(_ pause: CapturePause) {
        config.pause = .paused(pause, from: Date())
        config.save()
        settingsModel.config = config
        applyConfig(config)
        Log.shared.info("capture paused: \(pause.rawValue)")
    }

    private func resumeCapture() {
        config.pause = .running
        config.save()
        settingsModel.config = config
        applyConfig(config)
        Log.shared.info("capture resumed")
    }

    /// Brings the stored pause in line with the clock, resuming capture if its time is up.
    ///
    /// Evaluated rather than scheduled, and called from the health tick that already runs every
    /// fifteen seconds: a timer would not survive the app being quit, which is precisely the
    /// case that has to work.
    ///
    /// - Returns: whether anything changed.
    @discardableResult
    private func settlePause() -> Bool {
        let settled = config.pause.settled(at: Date())
        guard settled != config.pause else { return false }
        config.pause = settled
        config.save()
        settingsModel?.config = config
        Log.shared.info("capture pause expired; resuming")
        return true
    }

    private func showOnboarding() {
        // Bring the existing one forward rather than stacking a second copy: the band's
        // right-click menu can ask for this at any time, including while it is already open
        // behind something.
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let flow = OnboardingFlow(
            accessibilityGranted: Permissions.hasAccessibility(),
            hotkeyLabel: HotkeyManager.describe(
                keyCode: config.hotkeyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: config.hotkeyModifierRaw)
            ),
            requestAccessibility: { Permissions.requestAccessibility() },
            finish: { [weak self] in self?.finishOnboarding() }
        )
        // The history step runs an import, so it needs the live service. Handed over here
        // rather than reached for from the view, which keeps the step testable on its own.
        flow.history.provideMemory = { [weak self] in self?.memory }

        // The recovery key exists only on the launch that created the vault. Handed over once;
        // on every later launch this is nil and the step skips itself.
        flow.recovery.adopt(vaultOpening?.recoveryKey)
        // Nothing else to ask an existing user for; they came back only for the key.
        flow.recoveryOnly = config.hasCompletedOnboarding && !config.recoveryKeyAcknowledged
        if flow.recoveryOnly { flow.step = .recovery }
        onboardingFlow = flow

        let window = Self.makeWindow(
            title: "Welcome to Memoir",
            size: NSSize(width: 560, height: 620),
            content: OnboardingView(flow: flow)
        )
        // The ghost is white-on-black; the window joins the family. The background is set
        // explicitly because the hosting view's own black stops at the content rect and the
        // titlebar would otherwise sit on the system's grey.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        // The flow lays out at one size and steps through it. Resizing only ever produced
        // letterboxing, and minimising a window the user has not finished reading loses it
        // in a dock the app does not appear in.
        window.styleMask.remove(.resizable)
        window.styleMask.remove(.miniaturizable)

        onboardingWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The end of the flow: remember that it happened, and put the window away.
    ///
    /// Only the explicit Done records completion. Closing the window early leaves the flag
    /// alone, so an interrupted first run is offered again next launch rather than silently
    /// counting as read.
    private func finishOnboarding() {
        config.hasCompletedOnboarding = true
        // Seed what the user is called, because first run no longer asks.
        //
        // This is not cosmetic. `RuleExtractor` uses these names to tell a promise the user
        // made from one made to them in the same chat window, and CF-79 found that most
        // stored commitments were somebody else's words when it had nothing to match on.
        // The step that asked was pre-filled with exactly this value and Return was the whole
        // interaction, so taking the screen away and keeping the default is a fair trade,
        // and Settings › Data can correct it, which the one-shot screen never could.
        if config.ownNames.isEmpty {
            let account = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
            if !account.isEmpty { config.ownNames = [account] }
        }
        config.save()
        settingsModel.config = config
        onboardingWindow?.close()
        onboardingWindow = nil
        onboardingFlow = nil
    }

    private static func makeWindow(title: String, size: NSSize, content: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Asks for the recovery key when the memory is there and shut.
    ///
    /// Deliberately modal and deliberately before anything opens a database. The alternative
    /// this replaces was to carry on into a fresh plaintext memory, which reads to the user as
    /// "my memory is empty" and quietly starts overwriting the ground truth of what happened.
    ///
    /// What the user decided about a memory that will not unlock.
    enum RecoveryChoice {
        /// Try this recovery key.
        case restore(String)
        /// Leave the locked memory alone and begin a new one, knowingly.
        case startFresh
        /// Do nothing at all today.
        case quit
    }

    /// - Returns: the user's choice. Never a silent fallback: starting a second memory is a
    ///   button somebody pressed, and the locked container survives whichever way this goes.
    private func presentRecoveryKeyPrompt(reason: String?) -> RecoveryChoice {
        let alert = NSAlert()
        alert.messageText = "Memoir can't unlock your memory"
        alert.informativeText = """
        Your memory is still here and still encrypted, but the key that opens it is not in \
        this Mac's keychain any more.

        Enter the recovery key you were shown when encryption was set up. It looks like \
        A1B2-C3D4-E5F6-…

        If you don't have it, you can start a new memory instead. The locked one stays on \
        disk untouched, so it can still be opened if the key turns up later\
        \(reason.map { ".\n\n\($0)" } ?? ".")
        """
        alert.alertStyle = .critical

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "A1B2-C3D4-E5F6-G7H8-…"
        alert.accessoryView = field

        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Start a new memory")
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .restore(field.stringValue)
        case .alertThirdButtonReturn:
            return .startFresh
        default:
            NSApp.terminate(nil)
            return .quit
        }
    }

    /// Says why a recovery key was refused, without giving up on the next attempt.
    private func presentRecoveryKeyRejected(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "That didn't unlock it"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Try again")
        alert.runModal()
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Memoir can't start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
