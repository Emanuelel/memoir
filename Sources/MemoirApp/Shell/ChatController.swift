import AppKit
import SwiftUI
import MemoirKit

/// What the conversation is currently doing.
///
/// The transcript survives collapsing the band (an accidental Escape must not cost
/// the user an answer), and it is never written to memory: the one write path out of
/// a conversation is the confirm card's Save, and nothing else.
@MainActor
final class ChatState: ObservableObject {
    @Published var query: String = ""
    @Published var isThinking: Bool = false
    /// The running conversation for this session. ⌘K is the only thing that clears it.
    @Published var exchanges: [Exchange] = []
    @Published var errorText: String?

    /// What the pending proposal's due-time field is holding.
    ///
    /// On the state rather than inside the card because Return is read by a key monitor
    /// that sits above SwiftUI, so the save path has to be able to fold this text into
    /// the proposal before it writes. A time the user typed and never saw applied is the
    /// same failure as a default they could not see, one step later.
    @Published var dueDraft: String = ""
    /// Why the last committed due edit was refused. nil when there is nothing to say.
    @Published var dueProblem: String?
    /// The day the pending proposal's parse produced, held unchanged for the life of the
    /// card. The anchor an edited time lands on; nil when the phrase named no day.
    @Published var dueDay: Date?

    /// The exchange waiting on a yes or a no, if any.
    ///
    /// While this is non-nil the composer is locked and the two keys belong to the card:
    /// Return saves, Escape discards. There is never more than one: `submit` refuses to
    /// start a second while one is open.
    var pendingPushIndex: Int? {
        exchanges.lastIndex {
            if case .pending = $0.push { return true }
            return false
        }
    }
}

/// One question and its reply, kept in the session transcript.
struct Exchange: Identifiable, Sendable {
    let id = UUID()
    let question: String
    var answer: String?
    var brain: BrainKind?
    var latency: TimeInterval = 0
    var errorText: String?
    /// Set instead of `answer` when the message was a push. A push is not a question, so
    /// no brain answers it and no bubble is right for it: it gets the confirm card.
    var push: PushStage?
}

/// Chat state and pipeline, free of any presentation.
///
/// The old ask bar owned a panel; this owns nothing but the conversation, the push
/// path and the microphone. The band (and later the window) render it wherever they
/// like, and the panel's key monitor calls into it for the card's keys.
@MainActor
final class ChatController: ObservableObject {

    /// Everything the chat needs to run the push path.
    ///
    /// Closures rather than a `MemoryService` reference because keeping `preview` and
    /// `commit` as two separate arrows makes CF-51 checkable by reading this type:
    /// there is exactly one call site for the write in this file, and it is the Save path.
    struct PushBridge: Sendable {
        /// Classifies the phrase. Only `.push` changes what the chat does with it.
        let route: @Sendable (String) async -> QuestionCategory
        /// Parses without writing. Must be `MemoryService.previewPush`.
        let preview: @Sendable (String) async -> PushIntent?
        /// Writes a proposal the user has explicitly accepted, and nothing else.
        let commit: @Sendable (PushIntent) async throws -> Void
    }

    let state = ChatState()
    /// On-device dictation. Owned here because the microphone must be closed by
    /// exactly the same events that close the band.
    let voice: VoiceInput

    private let onSubmit: @Sendable (String) async -> (String, BrainKind, TimeInterval)?
    /// nil turns the push path off entirely: the chat then treats a push like any other
    /// message and the answering side handles it. Never a stub that pretends to save.
    private let push: PushBridge?
    /// The face, for the wink on save.
    private let character: CharacterModel?

    /// Fired after a successful save, so the shell can refresh counts and show the
    /// saved moment when collapsed.
    var onPushSaved: (@MainActor (PushIntent) -> Void)?

    /// What happened to a deterministic chat command.
    enum CommandOutcome {
        /// The command ran; this is Memoir's one-line receipt for the transcript.
        case reply(String)
        /// The command was navigation: the pane switch IS the answer, so the
        /// sentence never enters the transcript.
        case navigated
    }

    /// Runs verbs the chat understands before any routing or model call: timers and
    /// navigation. Wired by the app delegate; nil leaves every sentence to the router.
    var onCommand: (@MainActor (ChatCommand) -> CommandOutcome?)?

    /// The conversation's brain toggle. Wired by the app delegate; nil hides the row.
    var brains: BrainSwitchModel?

    init(
        voice voiceConfig: VoiceConfig = VoiceConfig(),
        push: PushBridge? = nil,
        character: CharacterModel? = nil,
        onSubmit: @escaping @Sendable (String) async -> (String, BrainKind, TimeInterval)?
    ) {
        self.onSubmit = onSubmit
        self.push = push
        self.character = character
        self.voice = VoiceInput(config: voiceConfig)

        // Dictation reads and writes the same field the keyboard does. It appends;
        // it never replaces what was typed.
        voice.currentText = { [weak self] in self?.state.query ?? "" }
        voice.applyText = { [weak self] text in self?.state.query = text }
    }

    /// Applies changed voice settings. A language change ends any running session.
    func updateVoiceConfig(_ config: VoiceConfig) {
        voice.updateConfig(config)
    }

    /// The band opened. **Never** opens the microphone.
    ///
    /// It used to: landing on Ask started listening in one motion, on the argument that
    /// hands-free was the whole point of dictation. It is not: a hot mic nobody asked for
    /// is the one thing this product cannot afford to do by surprise. The mic button is the
    /// only thing that opens the mic, and collapsing is still the thing that closes it.
    func bandDidOpen() {
        state.isThinking = false
    }

    /// **Always** callable, always idempotent. Collapse, submit and Escape all route
    /// here: there is no path that leaves the band closed and the microphone open.
    func stopVoice() {
        voice.stop()
    }

    func toggleVoice() {
        voice.toggle()
    }

    /// Sends the composer's text: a push becomes a confirm card, everything else goes
    /// through the answer pipeline.
    func submit() {
        // Return commits what was said. The mic closes first so no stray word can
        // land in the field after the question has already been sent.
        voice.stop()
        let trimmed = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // One decision at a time. A new message arriving over a pending card would
        // leave the proposal on screen with nothing left to accept it.
        guard state.pendingPushIndex == nil else { return }

        // Verbs first: "start a 25 minute timer" and "what's on my list" are things
        // the shell does, not questions for a brain. Deterministic, zero-model.
        if let command = ChatCommand.detect(trimmed), let outcome = onCommand?(command) {
            state.query = ""
            switch outcome {
            case .navigated:
                return
            case .reply(let text):
                var exchange = Exchange(question: trimmed)
                exchange.answer = text
                state.exchanges.append(exchange)
                return
            }
        }

        state.isThinking = true
        state.errorText = nil
        state.query = ""
        state.exchanges.append(Exchange(question: trimmed))
        let index = state.exchanges.count - 1
        let id = state.exchanges[index].id

        Task { [weak self] in
            guard let self else { return }
            if await self.presentPushIfNeeded(trimmed, id: id) { return }

            let result = await self.onSubmit(trimmed)
            self.state.isThinking = false
            guard self.state.exchanges.indices.contains(index) else { return }
            if let (text, brain, latency) = result {
                self.state.exchanges[index].answer = text
                self.state.exchanges[index].brain = brain
                self.state.exchanges[index].latency = latency
            } else {
                self.state.exchanges[index].errorText = "Couldn't answer that. Check the brain settings."
            }
        }
    }

    // MARK: - PUSH

    /// Routes the message and, if the user was telling rather than asking, shows the
    /// proposal. **This path cannot write**: it calls `preview` and stops; the store is
    /// not touched until ``savePendingPush()`` runs. That split is CF-51.
    ///
    /// - Returns: true when the message was handled as a push and no brain should see it.
    private func presentPushIfNeeded(_ phrase: String, id: UUID) async -> Bool {
        guard let push else { return false }
        // Routing can escalate to the model, which is measured in seconds, so the
        // transcript may have been cleared underneath us by the time either await
        // returns. The exchange is found by identity, never by a stale index.
        guard await push.route(phrase) == .push else { return false }

        let intent = await push.preview(phrase)
        state.isThinking = false
        guard let index = state.exchanges.firstIndex(where: { $0.id == id }) else { return true }

        guard let intent else {
            // The user said something. Dropping it silently is the one unacceptable
            // outcome, so the parser's failure is reported in Memoir's own words. Not an
            // error bubble: this is guidance about phrasing, not something that broke.
            state.exchanges[index].answer = Grounding.unparsedPush
            return true
        }
        state.exchanges[index].push = .pending(intent, problem: nil)
        // The field starts out holding the proposal's own time, so the user edits a
        // value rather than filling in a blank. The anchor is the parse's day.
        state.dueDay = intent.dueAt
        state.dueDraft = DueEdit.editableText(for: intent)
        state.dueProblem = nil
        return true
    }

    /// Puts the caret in the due-time field, for people who reach for Tab.
    ///
    /// SwiftUI's hosted controls are not in the panel's key view loop, so Tab has
    /// nothing to walk to on its own; the panel's key monitor calls this instead.
    /// - Returns: true when the caret moved, so the key is consumed.
    static func moveCaretToDueField(in panel: NSWindow?, pendingPush: Bool) -> Bool {
        guard pendingPush,
              let panel,
              let field = DueTimeField.locate(in: panel.contentView)
        else { return false }
        if panel.firstResponder === field.currentEditor() { return false }
        return panel.makeFirstResponder(field)
    }

    /// Folds whatever is in the due field into the pending proposal.
    ///
    /// - Returns: false when the text could not be read, in which case **nothing
    ///   moved**: the proposal keeps the value it had and the reason is on screen.
    private func commitDueEdit(at index: Int) -> Bool {
        guard case .pending(let intent, let problem)? = state.exchanges[index].push else { return true }
        // An untouched field has nothing to apply, and asking it to apply anything is
        // a chance for a spurious refusal on a proposal the user never edited.
        guard state.dueDraft != DueEdit.editableText(for: intent) else {
            state.dueProblem = nil
            return true
        }

        switch DueEdit.apply(state.dueDraft, to: intent, day: state.dueDay) {
        case .applied(let edited):
            state.exchanges[index].push = .pending(edited, problem: problem)
            // Re-seeded from the result, so the field can never end up showing
            // something other than what was stored.
            state.dueDraft = DueEdit.editableText(for: edited)
            state.dueProblem = nil
            return true
        case .rejected(let why):
            state.dueProblem = why
            return false
        }
    }

    /// Commits the pending proposal. The only write in this file.
    ///
    /// - Returns: true when there was something to save, so the caller knows whether
    ///   the key was consumed.
    @discardableResult
    func savePendingPush() -> Bool {
        guard let push, let index = state.pendingPushIndex else { return false }

        // The due field first: saving is the moment the typed time either counts or
        // does not, and a refusal here must stop the write rather than quietly save
        // the hour the user was mid-correction on. The key is still consumed.
        guard commitDueEdit(at: index) else { return true }

        guard case .pending(let intent, _)? = state.exchanges[index].push else { return false }

        // Out of `.pending` before the await: "did my Return register?" is answered by
        // pressing Return again, and the second press must find nothing pending.
        state.exchanges[index].push = .saving(intent)
        let id = state.exchanges[index].id

        Task { [weak self] in
            guard let self else { return }
            do {
                try await push.commit(intent)
                guard let at = self.state.exchanges.firstIndex(where: { $0.id == id }) else { return }
                self.state.exchanges[at].push = .saved(intent)
                self.character?.set(.wink, for: 2)
                self.onPushSaved?(intent)
            } catch {
                Log.shared.error("push commit failed: \(error)")
                guard let at = self.state.exchanges.firstIndex(where: { $0.id == id }) else { return }
                // Back to pending, with the reason attached. A failed write costs a
                // keystroke rather than the sentence the user typed.
                self.state.exchanges[at].push = .pending(intent, problem: "Couldn't save that. Press return to try again.")
                self.character?.set(.concerned, for: 2)
            }
        }
        return true
    }

    /// Discards the pending proposal. Writes nothing, and says so.
    ///
    /// - Returns: true when there was something to discard.
    @discardableResult
    func discardPendingPush() -> Bool {
        guard let index = state.pendingPushIndex,
              case .pending(let intent, _)? = state.exchanges[index].push
        else { return false }
        state.exchanges[index].push = .discarded(intent)
        // Escape discards everything, the half-typed time included. Nothing was
        // written and nothing is kept waiting to be.
        clearDueEdit()
        return true
    }

    /// Clears the transcript. The only destructive action, and it is always explicit.
    func clearConversation() {
        state.exchanges.removeAll()
        state.query = ""
        state.errorText = nil
        clearDueEdit()
    }

    private func clearDueEdit() {
        state.dueDraft = ""
        state.dueProblem = nil
        state.dueDay = nil
    }
}
