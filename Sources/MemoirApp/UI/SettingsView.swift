import SwiftUI
import MemoirKit

/// Backing model for the settings window.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: AppConfig
    @Published var stats: StoreStats?
    @Published var availability: [BrainKind: String] = [:]
    @Published var restraintDebug: String = ""
    @Published var apiKeyField: String = ""
    @Published var keySaved: Bool = BrainKeychain.hasKey()
    @Published var newExclusion: String = ""

    /// Which pane Settings opens on.
    ///
    /// On the model rather than in the view's `@State` so something else can send the user
    /// *to a specific switch*. A link that opens Settings and leaves somebody hunting through
    /// eight tabs is the reason a feature stays undiscovered, which is the exact problem the
    /// journal's weather tile exists to solve, so it must not reintroduce it one click later.
    @Published var section: SettingsSection = .capture

    // Your own model (LocalNetworkBrain). Consent is the act of typing an address.
    @Published var localHostField: String = ""
    @Published var localModelField: String = ""
    @Published var localEndpointProblem: String?

    // Voice
    @Published var voiceLocales: [VoiceLocaleOption] = []
    @Published var voiceModelStatus: String = "Checking…"
    @Published var voiceModelInstalled: Bool = false
    @Published var voiceDownloading: Bool = false
    @Published var voiceDownloadProgress: Double = 0
    @Published var voiceDownloadError: String?

    // Reminders
    /// The last thing that happened between Memoir and Reminders, in the user's words. Nil until
    /// something has. Set both by the access check and by every accepted push that tried.
    @Published var reminderStatus: String?
    /// Whether that last thing was a problem, i.e. whether it wants the eye.
    @Published var reminderStatusIsProblem: Bool = false
    @Published var reminderChecking: Bool = false

    /// The real Reminders. Built at init because building one asks for nothing: EventKit
    /// prompts on the first write or the first access check, never on construction.
    private let reminders = RemindersSync.system()

    // Coverage: how much of each app Memoir is actually reading.
    @Published var coverage: [AppCaptureQuality] = []

    /// What capture is doing right now, handed in by the app delegate's health watch. The
    /// same verdict the notch is showing, so the two surfaces can never disagree.
    @Published var health: CaptureHealth = .starting
    /// What macOS says about the login item, read from macOS on every appearance rather than
    /// mirrored from the config file: the file records an intention, and the whole point of
    /// this row is to show when the intention did not take.
    @Published var loginItem: LoginItem.State = .disabled

    // Vault: the user's own notes, read as authored memory.
    @Published var vaultStatus: String = ""
    @Published var vaultImporting: Bool = false
    @Published var lifeStatus: String = ""
    @Published var lifeImporting: Bool = false
    /// The sources macOS is withholding, set after every attempt. Non-empty is what turns the
    /// status line into a problem with a way out of it, rather than a caption.
    @Published var lifeWithheld: [LifeImporter.Source] = []
    /// Sources macOS has granted only in part. Separate from `lifeWithheld` because the fix is
    /// different: the switch is already on, and what has to change is how much it covers.
    @Published var lifePartial: [LifeImporter.Source] = []
    /// True when the attempt read nothing at all, so the block can lead with the failure
    /// instead of appending the fix to a success.
    @Published var lifeReadNothing: Bool = false
    /// Vaults Memoir found by itself, so the common case never opens a file dialog.
    @Published var discoveredVaults: [DiscoveredVault] = []
    @Published var dailyNoteDraft: String?
    @Published var dailyNoteStatus: String = ""

    // Agent proposals awaiting review.
    @Published var proposals: [MemoryProposal] = []
    @Published var proposalStatus: String = ""
    /// Set only when a wipe failed, so the failure is visible rather than swallowed.
    @Published var purgeStatus: String?
    @Published var exportStatus: String?
    @Published var exportProblem: Bool = false

    private let store: Store
    private let router: BrainRouter
    private let restraint: RestraintEngine
    private let memory: MemoryService

    /// The memory service, for the history import that now lives in Settings rather than in
    /// first run. Exposed rather than reached for, the way every other step is wired.
    var memoryService: MemoryService { memory }
    let onConfigChanged: (AppConfig) -> Void

    init(
        config: AppConfig,
        store: Store,
        router: BrainRouter,
        restraint: RestraintEngine,
        memory: MemoryService,
        onConfigChanged: @escaping (AppConfig) -> Void
    ) {
        self.config = config
        self.store = store
        self.router = router
        self.restraint = restraint
        self.memory = memory
        self.onConfigChanged = onConfigChanged
        if let endpoint = config.brain.localNetworkEndpoint {
            localHostField = endpoint.baseURL.absoluteString
            localModelField = endpoint.model
        }
    }

    /// Saves the local-network model host. This is what lights up the Qwen pill in
    /// the conversation's brain toggle.
    func saveLocalEndpoint() {
        let host = localHostField.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = localModelField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: host), url.scheme != nil, url.host != nil else {
            localEndpointProblem = "That doesn't read as a URL. Try http://192.168.1.20:1234/v1"
            return
        }
        guard !modelName.isEmpty else {
            localEndpointProblem = "Name the model as the server reports it, e.g. qwen3-30b-a3b-instruct-2507-mlx"
            return
        }
        localEndpointProblem = nil
        config.brain.localNetworkEndpoint = LocalNetworkBrain.Endpoint(baseURL: url, model: modelName)
        apply()
    }

    /// Forgets the host. The pill greys out again.
    func removeLocalEndpoint() {
        config.brain.localNetworkEndpoint = nil
        localHostField = ""
        localModelField = ""
        localEndpointProblem = nil
        apply()
    }

    func refresh() async {
        // Read from macOS, never from the config file. See ``loginItem``.
        loginItem = LoginItem.state()
        stats = try? await store.stats()
        availability = await router.availabilityReport()
        restraintDebug = await restraint.debugState()
        coverage = (try? await store.captureQuality(
            since: Date().addingTimeInterval(-7 * 86_400)
        )) ?? []
        reloadProposals()
    }

    // MARK: - Vault

    private var proposalsURL: URL { ProposalStore.url(alongsideDatabase: Paths.databaseURL()) }

    /// Looks for vaults so the pane can offer them outright.
    func refreshDiscoveredVaults() {
        discoveredVaults = VaultDiscovery.discover()
    }

    /// One click, no dialog. This is the path almost every user should take, and it
    /// imports immediately: choosing a vault and then waiting an hour for the first
    /// import would read as nothing having happened.
    func useVault(_ vault: DiscoveredVault) {
        config.vaultPath = vault.url.path
        apply()
        Task { await importVaultNow() }
    }

    /// The manual escape hatch, for a vault Memoir could not find.
    ///
    /// Two settings matter, and both were missing the first time this shipped. The most
    /// common vault on a Mac lives under `~/Library/Mobile Documents/iCloud~md~obsidian/`,
    /// and `~/Library` is hidden, so without `showsHiddenFiles` the user genuinely
    /// cannot click their way to their own notes, which is exactly the report that came
    /// back. Starting the panel where vaults actually live saves the search when
    /// discovery half-worked.
    func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a folder of markdown notes. Memoir reads it; it never writes into it."
        if let first = discoveredVaults.first {
            panel.directoryURL = first.url.deletingLastPathComponent()
        } else {
            let iCloud = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Mobile Documents/iCloud~md~obsidian/Documents")
            panel.directoryURL = FileManager.default.fileExists(atPath: iCloud.path)
                ? iCloud
                : FileManager.default.homeDirectoryForCurrentUser
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.vaultPath = url.path
        apply()
        Task { await importVaultNow() }
    }

    /// Forgets the folder. Entities already imported stay: they are the user's own
    /// notes, and deleting memory is the Memories browser's job, done deliberately.
    func removeVault() {
        config.vaultPath = nil
        vaultStatus = ""
        apply()
    }

    func importVaultNow() async {
        guard let path = config.vaultPath, !vaultImporting else { return }
        vaultImporting = true
        defer { vaultImporting = false }
        do {
            let summary = try await memory.importVault(at: URL(fileURLWithPath: path))
            vaultStatus = "Read \(summary.notesRead) note\(summary.notesRead == 1 ? "" : "s"); \(summary.entitiesCommitted) entities updated."
        } catch {
            vaultStatus = "Import failed: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Grants whatever is still ungranted and reads the full decade from every source allowed.
    ///
    /// This is the control the onboarding screen promises to anyone who declines there, and for
    /// eighteen months it did not exist: the message said "you can turn these on later in
    /// Settings" and there was nothing to turn on. Someone who wanted to think about it first
    /// had no way back short of reinstalling.
    ///
    /// Always a full pass, never the incremental window the hourly refresh uses: a user pressing
    /// this has just granted something for the first time, and wants their history, not the
    /// last month of it.
    func importLifeNow() async {
        guard !lifeImporting else { return }
        lifeImporting = true
        defer { lifeImporting = false }

        let contacts = await LifeImporter.requestContactsAccess()
        let calendar = await LifeImporter.requestCalendarAccess()
        let photos = await LifeImporter.requestPhotosAccess()
        let sources = LifeImporter.Sources(contacts: contacts, calendar: calendar, photos: photos)

        // Recorded on every path, success included: two sources granted and one refused is
        // still a switch the user has to be shown, and it used to vanish behind a count.
        lifeWithheld = LifeImporter.withheld
        lifePartial = LifeImporter.partial

        guard !sources.isEmpty else {
            lifeReadNothing = true
            lifeStatus = "Nothing was read. macOS is withholding all three, and it will not ask again."
            return
        }
        do {
            let summary = try await memory.importLife(sources: sources)
            lifeReadNothing = false
            lifeStatus = Self.describe(summary)
        } catch {
            lifeReadNothing = true
            lifeStatus = "Import failed: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Opens the one pane that holds this switch, and re-reads the grants when the user comes
    /// back. TCC changes are not published to us, so without the re-read the block would keep
    /// naming a permission the user has just switched on.
    func openLifeSettings(_ source: LifeImporter.Source) {
        source.openSettings()
    }

    /// Re-reads the three grants without asking for anything. Cheap, and it is what makes the
    /// problem block disappear by itself after a trip to System Settings.
    func refreshLifeGrants() {
        lifeWithheld = LifeImporter.withheld
        lifePartial = LifeImporter.partial
    }

    /// The same sentence the setup window shows, so the two never describe one import
    /// differently.
    static func describe(_ summary: LifeImporter.Summary) -> String {
        var parts: [String] = []
        if summary.peopleImported > 0 { parts.append("\(summary.peopleImported) people") }
        if summary.eventsImported > 0 { parts.append("\(summary.eventsImported) calendar events") }
        if summary.photoDaysImported > 0 { parts.append("\(summary.photoDaysImported) days with photographs") }
        if summary.placesFound > 0 { parts.append("\(summary.placesFound) places") }
        guard !parts.isEmpty else { return "There was nothing to read." }

        let what = parts.joined(separator: ", ")
        guard let back = summary.reachesBackTo else { return "Read \(what)." }
        let year = Calendar.current.component(.year, from: back)
        return "Read \(what). Reaches back to \(year)."
    }

    /// Builds today's note for review. Writes nothing anywhere.
    func draftDailyNote() async {
        do {
            dailyNoteDraft = try await memory.dailyNoteDraft(for: Date())
            dailyNoteStatus = ""
        } catch {
            dailyNoteStatus = "Could not draft: \(error.localizedDescription)"
        }
    }

    /// The explicit accept: the only path that writes into the vault, and only into
    /// its `Memoir/` subfolder.
    func acceptDailyNote() {
        guard let draft = dailyNoteDraft, let path = config.vaultPath else { return }
        do {
            let url = try VaultWriteBack.write(
                draft: draft, vaultRoot: URL(fileURLWithPath: path), day: Date()
            )
            dailyNoteStatus = "Written to \(VaultWriteBack.folderName)/\(url.lastPathComponent)."
            dailyNoteDraft = nil
        } catch {
            dailyNoteStatus = "Write failed: \(error.localizedDescription)"
        }
    }

    func discardDailyNote() {
        dailyNoteDraft = nil
        dailyNoteStatus = "Draft discarded. Nothing was written."
    }

    // MARK: - Agent proposals

    func reloadProposals() {
        proposals = ProposalStore.load(at: proposalsURL)
    }

    /// Accepting is what turns a suggestion into memory, marked authored, because
    /// the acceptance is the act of authorship.
    func accept(_ proposal: MemoryProposal) async {
        do {
            _ = try await memory.accept(proposal: proposal)
            try ProposalStore.remove(id: proposal.id, at: proposalsURL)
            proposalStatus = "Accepted \"\(proposal.title)\". It is yours now."
        } catch {
            proposalStatus = "Could not accept: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Rejecting deletes the proposal and leaves no trace.
    func reject(_ proposal: MemoryProposal) {
        try? ProposalStore.remove(id: proposal.id, at: proposalsURL)
        proposalStatus = "Rejected. Nothing was written."
        reloadProposals()
    }

    func apply() {
        config.save()
        onConfigChanged(config)
        Task {
            await router.setPreferred(config.preferredBrain)
            await router.setConfig(config.brain)
            await restraint.updateConfig(config.restraint)
            await refresh()
        }
    }

    func saveAPIKey() {
        let trimmed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try BrainKeychain.save(apiKey: trimmed)
            config.brain.anthropicAPIKey = trimmed
            apiKeyField = ""
            keySaved = true
            apply()
        } catch {
            Log.shared.error("keychain save failed: \(error)")
        }
    }

    func deleteAPIKey() {
        try? BrainKeychain.delete()
        config.brain.anthropicAPIKey = nil
        keySaved = false
        apply()
    }

    /// Reloads the speech-model picture. Cheap enough to run whenever the tab appears.
    func refreshVoice() async {
        voiceLocales = await VoiceCatalog.options()
        let locale = config.voice.locale
        voiceModelStatus = await VoiceCatalog.status(for: locale)
        voiceModelInstalled = await VoiceCatalog.isInstalled(locale)
    }

    /// Downloads the on-device model for the selected language.
    ///
    /// A missing model is a state, not a crash: the user can trigger the download here and
    /// watch it, rather than discovering it the first time they hold down the shortcut.
    func downloadVoiceModel() async {
        guard !voiceDownloading else { return }
        voiceDownloading = true
        voiceDownloadProgress = 0
        voiceDownloadError = nil
        do {
            try await VoiceCatalog.downloadModel(for: config.voice.locale) { [weak self] fraction in
                self?.voiceDownloadProgress = fraction
            }
        } catch {
            voiceDownloadError = error.localizedDescription
            Log.shared.error("speech model download failed: \(error)")
        }
        voiceDownloading = false
        await refreshVoice()
    }

    // MARK: - Reminders

    /// Turns sync on or off, and walks straight into the permission wall when it goes on.
    ///
    /// The check is deliberately here rather than on the first push. Access is granted in a
    /// pane of System Settings, and the only moment the user is thinking about Reminders at
    /// all is the moment they flip this switch. Finding out days later, from a todo that
    /// silently never reached the phone, is the failure this feature would be judged by.
    func setRemindersSync(_ on: Bool) {
        config.reminders.syncToReminders = on
        apply()
        if on {
            Task { await checkRemindersAccess() }
        } else {
            reminderStatus = nil
            reminderStatusIsProblem = false
        }
    }

    /// Checks access when the Reminders tab appears, and only when there is nothing to show
    /// yet. Re-asking on every appearance would put the same question to EventKit forever for
    /// no new information, and would leave the tab unable to display a stale-but-true answer.
    func checkRemindersAccessIfNeeded() async {
        guard config.reminders.syncToReminders, reminderStatus == nil else { return }
        await checkRemindersAccess()
    }

    /// Asks Reminders whether Memoir may write, and reports the answer in place.
    func checkRemindersAccess() async {
        guard !reminderChecking else { return }
        reminderChecking = true
        defer { reminderChecking = false }
        if let problem = await reminders.prepare() {
            reminderStatus = problem
            reminderStatusIsProblem = true
        } else {
            reminderStatus = "Memoir can write to Reminders."
            reminderStatusIsProblem = false
        }
    }

    /// Records what an accepted push actually did, so a sync that failed after the fact has
    /// somewhere to say so. Silent outcomes leave the previous line alone rather than
    /// blanking it, because "nothing happened" is not news and a cleared line reads as one.
    func recordReminderOutcome(_ outcome: ReminderSyncOutcome) {
        guard let message = outcome.userMessage else { return }
        reminderStatus = message
        if case .failed = outcome {
            reminderStatusIsProblem = true
        } else {
            reminderStatusIsProblem = false
        }
    }

    /// Writes an export, and reports what happened either way.
    ///
    /// The counterweight to "Delete everything". Until this existed the only exit from Memoir
    /// was destroying the memory, which is a strange thing to offer for data the product
    /// insists is yours.
    func export(as format: MemoryExportFormat) async {
        guard let url = format.runSavePanel() else { return }
        do {
            let bytes = try await MemoryExport.write(from: store, to: url)
            exportStatus = "Exported \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) to \(url.lastPathComponent)."
            exportProblem = false
        } catch {
            exportStatus = "Could not export: \(error.localizedDescription)"
            exportProblem = true
            Log.shared.error("export failed: \(error)")
        }
    }

    /// The sentence under the outbound count.
    ///
    /// Names both switches, because reporting only the cloud one made "everything runs on this
    /// Mac" appear above a count that a network-model request had just incremented.
    func egressSummary(lastDestination: String?) -> String {
        switch (config.brain.allowCloud, config.brain.allowLocalNetwork) {
        case (false, false):
            return "Cloud and network brains are both off. Everything runs on this Mac."
        case (true, false):
            return "Cloud brains are on. Answers may be sent to \(lastDestination ?? "a cloud provider")."
        case (false, true):
            return "A model on your network is on. Answers may be sent to \(lastDestination ?? "that host")."
        case (true, true):
            return "Cloud and network brains are both on. Answers may be sent to \(lastDestination ?? "either")."
        }
    }

    /// What the current retention setting will cost on disk, from this user's own rate.
    ///
    /// Deliberately measured rather than assumed: `bytesPerActiveDay` comes from the real
    /// database divided by the days that actually produced captures. A capture costs about
    /// 25 KB fully indexed and only ~3 KB of that is the text (the rest is the FTS index and
    /// the passage vectors), so the intuition "it is only text, how big can it get" is wrong
    /// by roughly 8x, and 365 days is several gigabytes. That number belongs next to the
    /// control that sets it, not in a source comment nobody reads.
    struct RetentionProjection {
        let sentence: String
        let isLarge: Bool
    }

    var retentionProjection: RetentionProjection? {
        guard let stats, let perDay = stats.bytesPerActiveDay else { return nil }
        let rate = ByteCountFormatter.string(fromByteCount: perDay, countStyle: .file)

        // Keeping everything is the default, so this is the sentence most people read. Give
        // them the number that actually matters at that setting: not a window, a decade.
        guard config.retentionDays > 0 else {
            let decade = ByteCountFormatter.string(fromByteCount: perDay * 250 * 10, countStyle: .file)
            return RetentionProjection(
                sentence: "Kept for as long as you want it. At \(rate) per working day that is "
                    + "about \(decade) after ten years.",
                isLarge: false
            )
        }

        let projected = perDay * Int64(config.retentionDays)
        let size = ByteCountFormatter.string(fromByteCount: projected, countStyle: .file)
        // The exemption belongs in front of whoever is setting the window, not only in
        // PRIVACY.md: without it this sentence reads as "your imported decade is about to go".
        let sentence = "About \(size) at this setting, based on \(rate) per day you work. "
            + "Older captured text is deleted and does not come back. What you imported from "
            + "Contacts, Calendar, Photos and your notes is kept either way."
        return RetentionProjection(sentence: sentence, isLarge: false)
    }

    /// Whether raw captures are kept for ever. Zero is how the config spells that, and the
    /// zero must never reach the screen: the shipping default rendered as "keep raw captures
    /// for 0 days" next to a sentence saying everything is kept, and once anyone touched the
    /// stepper (floor 1) there was no way back to keeping everything at all.
    var keepsEverything: Bool { config.retentionDays == 0 }

    /// Where the stepper lands when deletion is switched back on. Remembered from the last
    /// window the user had, so flipping the toggle twice does not eat the number they chose;
    /// 90 only for someone who never had one.
    private var lastRetentionWindow = 90

    func setKeepsEverything(_ keep: Bool) {
        if keep {
            if config.retentionDays > 0 { lastRetentionWindow = config.retentionDays }
            config.retentionDays = 0
        } else {
            config.retentionDays = lastRetentionWindow
        }
        apply()
    }

    func purgeOld() async {
        // Never a no-op that silently wipes: zero means keep everything, and the sweep in
        // MemoryService guards on it too.
        guard config.retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(config.retentionDays) * 86_400)
        _ = try? await store.purgeCaptures(olderThan: cutoff)
        await refresh()
    }

    /// Everything Memoir has written, in one action.
    ///
    /// The tables and the pre-migration snapshots are the store's job; these three files are
    /// this layer's, because they are written outside it. `asks.jsonl` in particular held the
    /// full context packet sent to every brain (raw capture text), and its own doc comment
    /// claimed it was "deleted by Delete everything along with the rest" while `AskLog.purge()`
    /// had no callers anywhere in the project.
    func purgeEverything() async {
        do {
            try await store.purgeEverything()
        } catch {
            // Previously `try?`. A wipe that fails and says nothing is the worst version of
            // this button: the user believes their memory is gone and it is all still there.
            purgeStatus = "Could not delete everything: \(error.localizedDescription)"
            Log.shared.error("purge everything failed: \(error)")
            await refresh()
            return
        }
        // The review queue is Memoir data too. Surviving a full wipe would betray what
        // the button says. So is the record of deep passes: it says when this Mac was in use
        // and how much was on screen, which is the user's day in summary form.
        try? FileManager.default.removeItem(at: proposalsURL)
        PassRecordStore.purge(at: PassRecordStore.url(alongsideDatabase: Paths.databaseURL()))
        AskLog.shared.purge()
        Log.shared.purge()
        purgeStatus = nil
        await refresh()
    }
}

/// The two shapes an export can take, and the save panel for each.
///
/// Named rather than a bare `Bool` so the button, the panel and the file extension cannot
/// disagree about which one the user asked for.
enum MemoryExportFormat {
    /// Everything, losslessly, for another program to read.
    case archive
    /// What Memoir believes plus the words behind each belief, for a person to read.
    case readable

    var buttonTitle: String {
        switch self {
        case .archive: return "Export everything (JSON)…"
        case .readable: return "Export as Markdown…"
        }
    }

    private var suggestedName: String {
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        let stamp = day.string(from: Date())
        switch self {
        case .archive: return "memoir-export-\(stamp).json"
        case .readable: return "memoir-memory-\(stamp).md"
        }
    }

    @MainActor
    func runSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Your memory, in a format you can take somewhere else."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Which settings pane is showing. A named type so the pill row and the switch can
/// never drift apart.
enum SettingsSection: String, CaseIterable {
    case capture = "Capture"
    case voice = "Voice"
    case brain = "Brain"
    case vault = "Vault"
    case agents = "Agents"
    case restraint = "Restraint"
    case reminders = "Reminders"
    case data = "Data"
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    /// Reads and writes `model.section`, so the pill row still works and a deep link from
    /// elsewhere in the app lands on the pane it asked for.
    private var section: SettingsSection {
        get { model.section }
        nonmutating set { model.section = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The band's own tab language (white pill selected, tile ghosts otherwise)
            // instead of the stock TabView chrome that made this pane look like a
            // different app wearing the system accent.
            HStack(spacing: 5) {
                ForEach(SettingsSection.allCases, id: \.self) { candidate in
                    Button { section = candidate } label: {
                        Text(candidate.rawValue)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(section == candidate ? Color.black : Color(white: 0.62))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(
                                section == candidate ? Color.white : Color(white: 0.16)
                            ))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Rectangle().fill(Color(white: 0.12)).frame(height: 1)

            Group {
                switch section {
                case .capture: CaptureTab(model: model)
                case .voice: VoiceTab(model: model)
                case .brain: BrainTab(model: model)
                case .vault: VaultTab(model: model)
                case .agents: ConnectionsTab()
                case .restraint: RestraintTab(model: model)
                case .reminders: RemindersTab(model: model)
                case .data: DataTab(model: model)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // One accent, and it is not the system's: controls read green-on-black like
        // every other live indicator in the shell.
        .tint(Color(red: 0.24, green: 0.81, blue: 0.49))
        .background(Color.black)
        // Wide enough for the pill row to lay out in one line. An eighth tab pushed the last
        // pill past the edge at 560, where it read as a missing feature rather than a clipped one.
        .frame(minWidth: 620, minHeight: 460)
        .task {
            // The settings window is cached and reused, so `.task` fires only once per
            // launch. Poll while it is on screen so the counters are never stale.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct CaptureTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            // First, before any setting. Somebody who opens this tab is usually here to find
            // out whether it is working, and making them infer that from an unticked "Pause
            // capture" box is how the answer gets guessed wrong.
            Section {
                CaptureStatusRow(health: model.health)
            }

            Section {
                Toggle("Open Memoir when I log in", isOn: Binding(
                    get: { model.loginItem.willLaunch },
                    set: { wanted in
                        model.config.openAtLogin = wanted
                        model.loginItem = LoginItem.set(wanted)
                        model.apply()
                    }
                ))
                if let caveat = model.loginItem.caveat {
                    Text(caveat).font(.caption).foregroundStyle(Color.orange)
                }
            } footer: {
                Text("Memoir cannot record anything while it is not running, and a Mac restarts on its own: a system update, a flat battery. Left off, capture stops at the next restart and stays stopped until you notice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                PauseRow(model: model)
                Toggle("Read window titles (needs Screen Recording)", isOn: Binding(
                    get: { model.config.capture.captureWindowTitles },
                    set: { model.config.capture.captureWindowTitles = $0; model.apply() }
                ))
            } header: {
                Text("Capture")
            } footer: {
                // There used to be an interval stepper here. Capture stopped running on a timer,
                // and the stepper went on promising one: at every value below ten seconds it
                // changed nothing whatsoever, and above ten it only widened session rotation.
                // What it was really being asked is answered here instead, in words.
                Text("""
                Memoir reads on-screen text through the accessibility system. It never takes \
                screenshots, records the screen, or listens to audio.

                It reads when something changes: you switch app, you switch window, or you stop \
                typing. While you are only reading, it takes one every \
                \(Int(model.config.capture.idleCaptureIntervalSeconds)) seconds, so a long page \
                is still recorded.
                """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if model.coverage.isEmpty {
                    Text("Nothing captured in the last week yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.coverage.prefix(12)) { app in
                        CoverageRow(
                            app: app,
                            excluded: model.config.capture.excludedBundleIDs.contains(app.bundleID)
                        )
                    }
                }
            } header: {
                Text("How well each app is being read · last 7 days")
            } footer: {
                Text("Native apps publish their text in full. Electron apps publish only what is rendered. Canvas apps publish almost nothing. If something you rely on reads poorly, what Memoir remembers from it will be thin. Better to know than to assume.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Never read these apps") {
                List {
                    ForEach(Array(model.config.capture.excludedBundleIDs).sorted(), id: \.self) { id in
                        HStack {
                            Text(id).font(.system(size: 11, design: .monospaced))
                            Spacer()
                            Button {
                                model.config.capture.excludedBundleIDs.remove(id)
                                model.apply()
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Read \(id) again")
                                .accessibilityLabel("Stop excluding \(id)")
                        }
                    }
                }
                .frame(height: 120)
                HStack {
                    TextField("com.example.app", text: $model.newExclusion)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let id = model.newExclusion.trimmingCharacters(in: .whitespaces)
                        guard !id.isEmpty else { return }
                        model.config.capture.excludedBundleIDs.insert(id)
                        model.newExclusion = ""
                        model.apply()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One app's coverage verdict: a dot, plain words, and the numbers behind them.
/// Pausing, as a length of time rather than a switch.
///
/// The switch was the problem. Somebody turns capture off to read something private, gets on
/// with their day, and the memory stops for a fortnight, the switch doing exactly what it was
/// told, with nothing ever asking whether it was still meant to. Every choice here except the
/// last one comes back by itself.
private struct PauseRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let pause = model.config.pause
        if pause.isPaused(at: Date()) {
            LabeledContent(pause.label(at: Date()) ?? "Paused") {
                Button("Resume now") {
                    model.config.pause = .running
                    model.apply()
                }
            }
        } else {
            LabeledContent("Pause capture") {
                Menu("Choose how long") {
                    ForEach(CapturePause.allCases, id: \.self) { choice in
                        Button(choice.menuTitle) {
                            model.config.pause = .paused(choice, from: Date())
                            model.apply()
                        }
                    }
                }
                .fixedSize()
            }
        }
    }
}

/// The plain answer, in the plainest words available: is this recording or is it not.
private struct CaptureStatusRow: View {
    let health: CaptureHealth

    private var tint: Color {
        if health.isHealthy { return .green }
        return health.isFault ? .pink : .orange
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(health.isHealthy ? "Recording" : health.shortLabel)
                    .font(.system(size: 13, weight: .semibold))
                // The sentence names the fix when there is one. A status light that says
                // "problem" and nothing else just moves the search to the user.
                if let sentence = health.detail {
                    Text(sentence).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CoverageRow: View {
    let app: AppCaptureQuality
    let excluded: Bool

    private var dotColor: Color {
        if excluded { return Color(white: 0.4) }
        switch app.grade {
        case .good: return Color(red: 0.24, green: 0.81, blue: 0.49)
        case .partial: return .yellow
        case .poor: return .orange
        case .nothing: return .red
        case .unknown: return Color(white: 0.4)
        }
    }

    private var verdict: String { excluded ? "Excluded by you" : app.grade.label }

    private var detail: String {
        let minutes = Int(app.activeSeconds / 60)
        let time = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
        guard app.captureCount > 0 else { return "\(time) of use, nothing captured" }
        return "\(time) · \(app.captureCount) captures · ~\(Int(app.charsPerActiveMinute)) chars/min"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.appName)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(verdict).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The vault: a folder of the user's own notes, read as authored memory, plus the one
/// write path: a daily note they explicitly accept.
private struct VaultTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                if let path = model.config.vaultPath {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button(model.vaultImporting ? "Importing…" : "Import now") {
                            Task { await model.importVaultNow() }
                        }
                        .disabled(model.vaultImporting)
                        Button("Choose another…") { model.chooseVault() }
                        Spacer()
                        Button("Forget this folder", role: .destructive) { model.removeVault() }
                    }
                    if !model.vaultStatus.isEmpty {
                        Text(model.vaultStatus).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Point Memoir at a folder of markdown notes: an Obsidian vault, a notes directory. The titles and aliases you already wrote become names Memoir can recognise on screen, from the first session rather than the third week.")
                        .font(.callout)

                    if model.discoveredVaults.isEmpty {
                        Button("Choose a folder…") { model.chooseVault() }
                    } else {
                        // Found ones lead. The file dialog is the fallback, not the
                        // first thing a user is asked to fight.
                        ForEach(model.discoveredVaults) { vault in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(Color(red: 0.24, green: 0.81, blue: 0.49))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(vault.name).font(.system(size: 12, weight: .medium))
                                    Text("\(vault.noteCount) note\(vault.noteCount == 1 ? "" : "s") · \(vault.source.label)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button("Use this") { model.useVault(vault) }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                            }
                        }
                        Button("Choose a different folder…") { model.chooseVault() }
                    }
                }
            } header: {
                Text("Your notes as memory")
            } footer: {
                Text("Read-only, on this Mac, on demand: at launch and hourly. Memoir never edits, moves or uploads your notes. What comes from the vault is marked as yours and can never be overwritten by anything Memoir merely inferred.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Your contacts, your calendar and your photo library already hold years of your life. Memoir reads them for names, dates, and the places you keep going back to, then keeps reading them hourly so it stays current.")
                    .font(.callout)
                HStack {
                    Button(model.lifeImporting ? "Reading…" : "Read them now") {
                        Task { await model.importLifeNow() }
                    }
                    .disabled(model.lifeImporting)
                    Spacer()
                }
                if !model.lifeStatus.isEmpty && model.lifeWithheld.isEmpty && model.lifePartial.isEmpty {
                    // Not a caption. A nine-year import that reports itself in secondary grey
                    // under the button reads as nothing having happened, which is the same
                    // complaint the refusal message earned, and it was true of both.
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: model.lifeReadNothing
                              ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(model.lifeReadNothing ? .orange : .green)
                        Text(model.lifeStatus)
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !model.lifePartial.isEmpty {
                    PartialBlock(
                        partial: model.lifePartial,
                        status: model.lifeStatus,
                        open: { model.openLifeSettings($0) }
                    )
                }
                if !model.lifeWithheld.isEmpty {
                    WithheldBlock(
                        withheld: model.lifeWithheld,
                        readNothing: model.lifeReadNothing,
                        status: model.lifeStatus,
                        open: { model.openLifeSettings($0) }
                    )
                }
            } header: {
                Text("Your life on this Mac")
            } footer: {
                Text("From Contacts: names only, no numbers, no addresses, no birthdays. From Calendar: what an event was, where, and who was there; Google and Exchange accounts included if they are set up in the Mac's Calendar app. From Photos: dates and rough locations only, never an image, and screenshots are skipped. Nothing is ever written back to any of the three.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.config.vaultPath != nil {
                Section {
                    if let draft = model.dailyNoteDraft {
                        ScrollView {
                            Text(draft)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 170)
                        HStack {
                            Button("Write to vault") { model.acceptDailyNote() }
                                .buttonStyle(.borderedProminent)
                            Button("Discard") { model.discardDailyNote() }
                            Spacer()
                        }
                    } else {
                        Button("Draft today's note") {
                            Task { await model.draftDailyNote() }
                        }
                    }
                    if !model.dailyNoteStatus.isEmpty {
                        Text(model.dailyNoteStatus).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Daily note: a proposal, never a sync")
                } footer: {
                    Text("Memoir drafts, you read, and only your accept writes, into the \(VaultWriteBack.folderName)/ folder inside your vault and nowhere else. Your own notes are never touched, and Memoir never reads its own writing back as memory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Cheap and local: a vault may be added in Obsidian while this pane is open.
        .task { model.refreshDiscoveredVaults() }
        // TCC never tells us it changed, so the block would otherwise keep naming a switch the
        // user has already flipped. Re-read when the window comes back to the front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.lifeWithheld.isEmpty { model.refreshLifeGrants() }
        }
    }
}

/// Granted, but only for the photographs the user hand-picked.
///
/// A separate block from ``WithheldBlock`` because the switch is already on and the fix is a
/// different one: the user has to change *how much* the switch covers. Reported at all because
/// the counts either side of it are not comparable: 202 images and 14,683 images produce the
/// same sentence otherwise, and the smaller one is not a smaller life.
private struct PartialBlock: View {
    let partial: [LifeImporter.Source]
    let status: String
    let open: (LifeImporter.Source) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(partial) { source in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(source.label) is set to Limited Access.")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("macOS is handing over only the photographs you picked, so what Memoir read is a slice of the library rather than the record of it. Set it to Full Access and read them again.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Open \(source.label) settings") { open(source) }
                        .controlSize(.small)
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

/// What to do about a permission macOS is withholding.
///
/// Replaces a caption that said "use System Settings → Privacy & Security" and left the user
/// to go and find it. Once TCC has recorded a refusal it stops prompting, so the button that
/// failed cannot succeed on a second press: the pane is the only way forward, and it is one
/// click per switch here.
///
/// Shared with the history step in first run rather than copied into it: the two screens ask
/// for the same three permissions, and a refusal has to end the same way in both. Internal,
/// not private, for exactly that reason.
struct WithheldBlock: View {
    let withheld: [LifeImporter.Source]
    /// True when nothing at all was read, which changes the headline from "some of this" to
    /// "none of this": the difference between a partial import and a dead button.
    let readNothing: Bool
    let status: String
    let open: (LifeImporter.Source) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(headline)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(withheld) { source in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.label).font(.system(size: 12, weight: .medium))
                        Text("Without it, Memoir cannot read \(source.whatItCosts).")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Open \(source.label) settings") { open(source) }
                        .controlSize(.small)
                }
            }

            Text("macOS records a refusal and then stops asking, so pressing the button again changes nothing. Switch Memoir on in the pane, come back, and read them again.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The count still matters when two of three came through: the import was not a
            // failure, and saying so stops the warning reading as "nothing worked".
            if !readNothing && !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var headline: String {
        let names = withheld.map(\.label)
        let listed: String
        switch names.count {
        case 1: listed = names[0]
        case 2: listed = "\(names[0]) and \(names[1])"
        default: listed = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
        return readNothing
            ? "macOS is withholding \(listed), so nothing was read."
            : "macOS is withholding \(listed)."
    }
}

private struct VoiceTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Text("Click the microphone on the Ask tab, say what you want, press Return to send. The microphone never opens on its own, and it closes the moment the band goes away. Typing still works exactly as before: dictated words are added to whatever you have already typed.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Dictation")
            }

            Section {
                Picker("Language", selection: Binding(
                    get: { model.config.voice.localeIdentifier },
                    set: {
                        model.config.voice.localeIdentifier = $0
                        model.apply()
                        Task { await model.refreshVoice() }
                    }
                )) {
                    if model.voiceLocales.isEmpty {
                        Text(model.config.voice.localeIdentifier)
                            .tag(model.config.voice.localeIdentifier)
                    }
                    ForEach(model.voiceLocales) { option in
                        Text(option.installed ? option.name : "\(option.name) (not downloaded)")
                            .tag(option.identifier)
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(model.voiceModelInstalled ? .green : .orange)
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    Text(model.voiceModelStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.voiceDownloading {
                    ProgressView(value: model.voiceDownloadProgress) {
                        Text("Downloading… \(Int(model.voiceDownloadProgress * 100))%")
                            .font(.caption)
                    }
                } else {
                    Button(model.voiceModelInstalled ? "Re-check model" : "Download speech model") {
                        Task {
                            if model.voiceModelInstalled {
                                await model.refreshVoice()
                            } else {
                                await model.downloadVoiceModel()
                            }
                        }
                    }
                }

                if let error = model.voiceDownloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Language and model")
            } footer: {
                Text("Speech models are downloaded once from Apple and then run on this Mac. Your voice is transcribed locally: no audio and no transcript is ever uploaded, and nothing is written to disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                Text("Voice needs two permissions the first time you use it: \(VoicePermissions.speechPane) and \(VoicePermissions.microphonePane). Memoir asks for both, and says so in the ask bar if either is refused.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshVoice() }
    }
}

private struct BrainTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Which brain answers") {
                Picker("Preferred", selection: Binding(
                    get: { model.config.preferredBrain },
                    set: { model.config.preferredBrain = $0; model.apply() }
                )) {
                    ForEach(BrainKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                ForEach(BrainKind.allCases, id: \.self) { kind in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(model.availability[kind]?.hasPrefix("available") == true ? .green : .secondary)
                            .frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(kind.displayName).font(.system(size: 12, weight: .medium))
                                if kind.isCloud {
                                    Text("leaves this Mac")
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.orange.opacity(0.22), in: Capsule())
                                }
                            }
                            Text(model.availability[kind] ?? "checking…")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Toggle("Allow a model on my network", isOn: Binding(
                    get: { model.config.brain.allowLocalNetwork },
                    set: { model.config.brain.allowLocalNetwork = $0; model.apply() }
                ))
                TextField("http://192.168.1.20:1234/v1", text: $model.localHostField)
                    .textFieldStyle(.roundedBorder)
                TextField("qwen3-30b-a3b-instruct-2507-mlx", text: $model.localModelField)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { model.saveLocalEndpoint() }
                        .disabled(model.localHostField.isEmpty || model.localModelField.isEmpty)
                    if model.config.brain.localNetworkEndpoint != nil {
                        Button("Remove", role: .destructive) { model.removeLocalEndpoint() }
                    }
                }
                if let problem = model.localEndpointProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Your own model")
            } footer: {
                Text("""
                    An OpenAI-compatible server on a machine you own: LM Studio, Ollama, vLLM. \
                    Base URL including /v1, and the model id as the server reports it.

                    Not a cloud service: no third party, no account, nobody's retention policy \
                    but yours. It is still a request leaving this Mac, usually over plain HTTP, \
                    so it has its own switch and is counted like any other. Typing an address \
                    is not consent to use it.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Allow brains that send data off this Mac", isOn: Binding(
                    get: { model.config.brain.allowCloud },
                    set: { model.config.brain.allowCloud = $0; model.apply() }
                ))
                if model.config.brain.allowCloud {
                    HStack {
                        SecureField(model.keySaved ? "•••••••• (saved)" : "sk-ant-…", text: $model.apiKeyField)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") { model.saveAPIKey() }
                            .disabled(model.apiKeyField.isEmpty)
                        if model.keySaved {
                            Button("Remove", role: .destructive) { model.deleteAPIKey() }
                        }
                    }
                    Text("Stored in the macOS Keychain. Never written to Memoir's database, config file or logs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Cloud")
            } footer: {
                Text("Off by default. While this is off, Memoir will never fall back to a cloud brain no matter which one is selected above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RestraintTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Quiet hours", isOn: Binding(
                    get: { model.config.restraint.quietHours.enabled },
                    set: { model.config.restraint.quietHours.enabled = $0; model.apply() }
                ))
                Stepper("From \(model.config.restraint.quietHours.start):00",
                        value: $model.config.restraint.quietHours.start, in: 0...23)
                    .onChange(of: model.config.restraint.quietHours.start) { _, _ in model.apply() }
                Stepper("Until \(model.config.restraint.quietHours.end):00",
                        value: $model.config.restraint.quietHours.end, in: 0...23)
                    .onChange(of: model.config.restraint.quietHours.end) { _, _ in model.apply() }
            } header: {
                Text("When Memoir may speak")
            }

            Section {
                Toggle("Ask once each evening whether you want to write", isOn: Binding(
                    get: { model.config.journalInvitation },
                    set: { model.config.journalInvitation = $0; model.apply() }
                ))
            } footer: {
                Text("One invitation a day, after 20:00, and never during quiet hours. It says the same thing every time and says nothing about you: no counts, no streaks, and no mention of days you did not write. Turn it off here and it never asks again.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper("Cooldown \(Int(model.config.restraint.cooldownSeconds / 60)) min",
                        value: $model.config.restraint.cooldownSeconds, in: 60...7200, step: 60)
                    .onChange(of: model.config.restraint.cooldownSeconds) { _, _ in model.apply() }
                Stepper("At most \(model.config.restraint.maxNudgesPerDay) a day",
                        value: $model.config.restraint.maxNudgesPerDay, in: 0...40)
                    .onChange(of: model.config.restraint.maxNudgesPerDay) { _, _ in model.apply() }
                Toggle("Stay silent during focus", isOn: Binding(
                    get: { model.config.restraint.suppressDuringFocus },
                    set: { model.config.restraint.suppressDuringFocus = $0; model.apply() }
                ))
            }

            Section("Why it is or isn't speaking") {
                ScrollView {
                    Text(model.restraintDebug.isEmpty ? "\u{2014}" : model.restraintDebug)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 90)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RemindersTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Send the todos you write to Apple Reminders", isOn: Binding(
                    get: { model.config.reminders.syncToReminders },
                    set: { model.setRemindersSync($0) }
                ))
            } header: {
                Text("Reminders")
            } footer: {
                Text("Off until you switch it on. Memoir sends only the todos you typed and confirmed yourself, never anything it guessed, and it never reads the reminders you already have. It goes one way: Memoir writes into Reminders and never back.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // The access section only exists once sync is on. Offering a permission check for
            // a feature that is switched off is asking the user to grant something for no
            // reason, which is exactly the prompt this app avoids everywhere else.
            if model.config.reminders.syncToReminders {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(statusColour)
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Button("Check access") {
                            Task { await model.checkRemindersAccess() }
                        }
                        .disabled(model.reminderChecking)
                        Button("Open System Settings") {
                            RemindersPermissions.openPane()
                        }
                    }
                } header: {
                    Text("Access")
                } footer: {
                    Text("If macOS never shows a prompt, it has decided not to ask rather than been told no. Add Memoir yourself in \(RemindersPermissions.pane) and check again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.checkRemindersAccessIfNeeded() }
    }

    /// Never a claim about permission that has not been checked. "Checking…" while nothing is
    /// checking is the small lie that makes a user trust the green dot next to it less.
    private var statusText: String {
        if let status = model.reminderStatus { return status }
        return model.reminderChecking ? "Checking…" : "Access has not been checked yet."
    }

    private var statusColour: Color {
        if model.reminderStatus == nil { return .secondary }
        return model.reminderStatusIsProblem ? .orange : .green
    }
}

/// One staged proposal, with the two verbs that resolve it.
private struct ProposalRow: View {
    let proposal: MemoryProposal
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(proposal.kind.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color(white: 0.16)))
                Text(proposal.title).font(.system(size: 12, weight: .medium))
            }
            if let detail = proposal.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("from \(proposal.origin) · \(proposal.ts.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Accept", action: onAccept)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Reject", role: .destructive, action: onReject)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DataTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var outbound = OutboundCounter.shared
    @State private var confirmWipe = false

    /// The one onboarding step that had nowhere else to go.
    ///
    /// Owned here rather than by the flow that no longer shows it: it was a gate in front of
    /// an app the user had not seen yet, and it is a thing somebody may want to change later,
    /// which a first-run screen by construction cannot offer.
    ///
    /// Importing Contacts and Calendar deliberately does **not** appear here. Settings › Vault
    /// has offered exactly that under "Your life on this Mac" all along, and its version also
    /// reads the photo library, so a second copy in this pane was a weaker duplicate of a
    /// feature that already had a home.
    @StateObject private var identity = IdentityStep()

    var body: some View {
        Form {
            Section("Nothing has left this Mac") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(outbound.count == 0 ? .green : .orange)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outbound.count == 0
                             ? "0 outbound requests this session"
                             : "\(outbound.count) outbound request\(outbound.count == 1 ? "" : "s") this session")
                            .font(.system(size: 12, weight: .medium))
                        Text(model.egressSummary(lastDestination: outbound.lastDestination))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Weather") {
                Toggle("Let the journal look up the weather", isOn: Binding(
                    get: { model.config.allowWeather },
                    set: { model.config.allowWeather = $0; model.apply() }
                ))
                Text("The one thing the journal shows that is not already on this Mac. Off, it "
                     + "asks nothing and no location is requested. On, it asks open-meteo.com "
                     + "what the weather was, with your location rounded to about 11 km and "
                     + "nothing else attached, counted above like every other request.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check whether a newer Memoir exists", isOn: Binding(
                    get: { model.config.allowUpdateCheck },
                    set: { model.config.allowUpdateCheck = $0; model.apply() }
                ))
                Text("The only request Memoir makes without being asked. It fetches one small "
                     + "static file that says what the current version is, with no version of "
                     + "yours, no machine id and no account attached, and the comparison happens "
                     + "on this Mac. It is counted above like every other request. Memoir never "
                     + "downloads or installs anything: it tells you, and you decide. Off, it "
                     + "asks nothing, and you will not hear when a bug is fixed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What's stored") {
                if let s = model.stats {
                    LabeledContent("Captures", value: "\(s.captureCount)")
                    LabeledContent("Things remembered", value: "\(s.entityCount)")
                    LabeledContent("Sessions", value: "\(s.sessionCount)")
                    LabeledContent("Database size", value: ByteCountFormatter.string(
                        fromByteCount: s.fileSizeBytes, countStyle: .file))
                    if let oldest = s.oldestCapture {
                        LabeledContent("Oldest capture",
                                       value: oldest.formatted(date: .abbreviated, time: .omitted))
                    }
                } else {
                    Text("Loading…").foregroundStyle(.secondary)
                }
                Text(Paths.databaseURL().path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                if model.proposals.isEmpty {
                    Text("Nothing waiting. An agent connected over MCP can suggest a memory with `propose_memory`; it lands here and enters memory only when you accept it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.proposals) { proposal in
                        ProposalRow(
                            proposal: proposal,
                            onAccept: { Task { await model.accept(proposal) } },
                            onReject: { model.reject(proposal) }
                        )
                    }
                }
                if !model.proposalStatus.isEmpty {
                    Text(model.proposalStatus).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(model.proposals.isEmpty
                     ? "Agent proposals"
                     : "Agent proposals · \(model.proposals.count) waiting")
            } footer: {
                Text("Accepting writes the entry as yours; rejecting deletes it and leaves no trace. The MCP server cannot write to memory at all: agents propose, only you record.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(MemoryExportFormat.archive.buttonTitle) {
                    Task { await model.export(as: .archive) }
                }
                Button(MemoryExportFormat.readable.buttonTitle) {
                    Task { await model.export(as: .readable) }
                }
                if let status = model.exportStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(model.exportProblem ? .red : .secondary)
                }
            } header: {
                Text("Take it with you")
            } footer: {
                Text("""
                    The JSON archive is everything: what Memoir has learned, the quotes behind \
                    each belief, every capture and every session, with nothing filtered out. \
                    The Markdown copy is the reading version (what it believes and where each \
                    belief came from), and drops straight into Obsidian or any notes app.

                    Leaving should cost you nothing. Export first, then delete below if you want to.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            SpareKeySection()

            Section {
                IdentityStepView(step: identity)
            } header: {
                Text("What you are called")
            } footer: {
                Text("""
                    Chat clients label your own messages with your name. Memoir needs to know \
                    which label is yours, or it records your friend's promises as though you \
                    had made them. Pre-filled from this Mac's account name; add every form you \
                    are labelled with.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }


            Section {
                Toggle("Keep everything", isOn: Binding(
                    get: { model.keepsEverything },
                    set: { model.setKeepsEverything($0) }
                ))
                if !model.keepsEverything {
                    Stepper(
                        "Keep raw captures for \(model.config.retentionDays) "
                            + (model.config.retentionDays == 1 ? "day" : "days"),
                        value: $model.config.retentionDays, in: 1...365
                    )
                    .onChange(of: model.config.retentionDays) { _, _ in model.apply() }
                }
                if let projection = model.retentionProjection {
                    Text(projection.sentence)
                        .font(.caption)
                        .foregroundStyle(projection.isLarge ? .orange : .secondary)
                }
                if !model.keepsEverything {
                    // At keep-everything this button is a guarded no-op, and a button that
                    // does nothing is worse than no button.
                    Button("Purge captures older than that now") {
                        Task { await model.purgeOld() }
                    }
                }
                Button("Delete everything", role: .destructive) { confirmWipe = true }
                if let problem = model.purgeStatus {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Retention")
            } footer: {
                Text(model.keepsEverything
                     ? "Nothing rolls off at this setting. Every capture stays until you delete it."
                     : """
                       Raw captures roll off. Short quoted snippets kept as evidence for what \
                       Memoir learned do not, and neither does what it has learned: those stay \
                       until you delete them.
                       """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete everything Memoir has stored?", isPresented: $confirmWipe) {
            Button("Delete everything", role: .destructive) {
                Task { await model.purgeEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                Captures, memory, provenance and sessions are removed, along with the pending \
                review queue, the pre-upgrade database snapshots, the ask log and the \
                diagnostic log. This cannot be undone.
                """)
        }
        .task { await model.refresh() }
    }
}

// MARK: - The spare key

/// Shows the spare key on demand, and takes one back.
///
/// Both halves were missing, and each absence cost something real. The key was shown exactly
/// once during first run and never again, a rule that sounds careful and in practice
/// guarantees that anyone who clicked past it is holding nothing. And `VaultKey.restore`
/// existed, tested, called from nowhere at all, so a user with their key written down on
/// paper had no way to type it in.
///
/// Revealing is behind a press rather than shown by default: this is the one string that
/// opens everything, and a settings pane is a thing people screen-share.
private struct SpareKeySection: View {
    @State private var revealed: String?
    @State private var entering = false
    @State private var typed = ""
    @State private var note: String?
    @State private var noteIsProblem = false

    var body: some View {
        Section {
            if let revealed {
                Text(revealed)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Save to a file…") { save(revealed) }
                Button("Hide") { self.revealed = nil }
            } else {
                Button("Show my spare key") { show() }
            }

            if entering {
                TextField("A1B2-C3D4-E5F6-…", text: $typed)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Unlock with this key") { restore() }
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { entering = false; typed = ""; note = nil }
                }
            } else {
                Button("Open a memory from another Mac…") { entering = true; note = nil }
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(noteIsProblem ? .red : .secondary)
            }
        } header: {
            Text("Spare key")
        } footer: {
            Text("""
                If this Mac is ever lost or wiped, this key opens your memory again. Nobody \
                else has a copy (not us, not a server), so a key that is only on this Mac is \
                not a spare.
                """)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func show() {
        do {
            revealed = try VaultKey.recoveryKey()
            note = nil
        } catch {
            note = "Could not read the key: \(error.localizedDescription)"
            noteIsProblem = true
        }
    }

    private func save(_ key: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Memoir spare key.txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Somewhere that is not this Mac: a printer, another machine, a safe."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let body = """
        Memoir spare key

        \(key)

        This opens your Memoir memory if this Mac is lost, wiped, or will not start.
        Without it, and without this Mac, the memory cannot be opened by anyone, including us.
        """
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            var config = AppConfig.load()
            config.recoveryKeyAcknowledged = true
            config.save()
            note = "Saved to \(url.lastPathComponent)."
            noteIsProblem = false
        } catch {
            note = "Could not write that file: \(error.localizedDescription)"
            noteIsProblem = true
        }
    }

    private func restore() {
        do {
            try VaultKey.restore(fromRecoveryKey: typed)
            note = "Key accepted. Quit and reopen Memoir to unlock that memory."
            noteIsProblem = false
            entering = false
            typed = ""
        } catch {
            let reason = (error as? MemoirError)?.localizedDescription ?? error.localizedDescription
            note = reason
            noteIsProblem = true
        }
    }
}
