import SwiftUI
import MemoirKit

/// The conversation, in the band's language: what you said is a white bubble, what
/// Memoir says is plain text on the black: the panel itself is Memoir's speech bubble.
/// No gradients, no avatars, no bubble for the machine.
struct ChatPane: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var state: ChatState
    @ObservedObject var voice: VoiceInput
    @Environment(\.memoirSurface) private var surface
    @FocusState private var focused: Bool

    init(chat: ChatController) {
        self.chat = chat
        self.state = chat.state
        self.voice = chat.voice
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .onAppear { focused = true }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if state.exchanges.isEmpty && !state.isThinking {
                        emptyState
                    }
                    ForEach(state.exchanges) { exchange in
                        VStack(alignment: .leading, spacing: 10) {
                            MeBubble(text: exchange.question)
                            if let push = exchange.push {
                                // A push is a decision, not a reply, so it gets the card
                                // rather than text. Nothing is written while it is pending.
                                PushConfirmView(
                                    stage: push,
                                    dueDay: state.dueDay,
                                    dueDraft: $state.dueDraft,
                                    dueProblem: state.dueProblem,
                                    onSave: { chat.savePendingPush() },
                                    onDiscard: { chat.discardPendingPush() }
                                )
                            } else if let error = exchange.errorText {
                                Text(error)
                                    .font(.system(size: fontSize))
                                    .foregroundStyle(Theme.accent)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if let answer = exchange.answer {
                                MemoirReply(text: answer, brain: exchange.brain, latency: exchange.latency)
                            } else {
                                ThinkingDots()
                            }
                        }
                        .id(exchange.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: state.exchanges.count) { scrollToBottom(proxy) }
            .onChange(of: state.isThinking) { scrollToBottom(proxy) }
        }
    }

    private static let bottomAnchor = "bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Ask about your day, your list, or anything you've seen.")
                .font(.system(size: fontSize))
                .foregroundStyle(Theme.dim)
            Text("Return to send · ⌘K clears the conversation")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ghost)
        }
        .padding(.top, surface == .band ? 22 : 40)
    }

    private var fontSize: CGFloat { surface == .band ? 13 : 14 }

    // MARK: - Composer

    /// A hairline and a bare field. The band is already the container; a boxed
    /// composer inside it would be a card in a card.
    private var composer: some View {
        VStack(spacing: 0) {
            Theme.hairline

            if let brains = chat.brains {
                BrainPickerRow(model: brains)
                    .padding(.top, 7)
            }

            VoiceStatusBar(state: voice.state)
                .padding(.top, 7)

            HStack(alignment: .center, spacing: 9) {
                MicButton(state: voice.state) { chat.toggleVoice() }

                TextField(placeholder, text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize + 1))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { chat.submit() }

                if state.isThinking {
                    ProgressView().controlSize(.small)
                } else if state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("⏎")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ghost)
                } else {
                    Button { chat.submit() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.bg, Theme.ink)
                    }
                    .buttonStyle(.plain)
                    .help("Send")
                    .transition(.scale.combined(with: .opacity))
                }

                if !state.exchanges.isEmpty {
                    Button { chat.clearConversation() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ghost)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear conversation (⌘K)")
                    .keyboardShortcut("k", modifiers: .command)
                }
            }
            .animation(.easeOut(duration: 0.15), value: state.query.isEmpty)
            .padding(.top, 9)
            .padding(.bottom, surface == .band ? 2 : 8)
            // Locked, not hidden, while a proposal is on screen: the composer keeps
            // its place and the field stops competing for the Return that belongs to
            // the card.
            .disabled(awaitingPush)
            .opacity(awaitingPush ? 0.45 : 1)
        }
        // The field gives up focus when it is disabled and does not take it back on
        // its own, which would leave the user typing into nothing after the card is
        // resolved.
        .onChange(of: awaitingPush) { _, waiting in if !waiting { focused = true } }
    }

    private var awaitingPush: Bool { state.pendingPushIndex != nil }

    private var placeholder: String {
        if awaitingPush { return PushConfirmFormat.pendingKeys }
        return voice.state.isListening ? "Listening… speak, then press Return" : "Ask, or tell me something"
    }
}

// MARK: - Pieces

/// What the user said: white bubble, black text, hugging the right edge.
private struct MeBubble: View {
    let text: String
    @Environment(\.memoirSurface) private var surface

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(size: surface == .band ? 13 : 14, weight: .medium))
                .foregroundStyle(Theme.bg)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(Theme.meBubble)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rBubble, style: .continuous))
        }
    }
}

/// What Memoir said: plain text, no bubble (the black panel is the bubble), with a
/// one-line dim receipt naming the brain. Trust is a caption now, not a badge.
private struct MemoirReply: View {
    let text: String
    let brain: BrainKind?
    let latency: TimeInterval
    @Environment(\.memoirSurface) private var surface

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownText(markdown: text, size: surface == .band ? 13 : 14, color: Theme.memoirInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let brain {
                Text(receipt(for: brain))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ghost)
            }
        }
        .padding(.trailing, 24)
    }

    private func receipt(for brain: BrainKind) -> String {
        var parts = [brain.isCloud ? "sent off this Mac" : "on this Mac"]
        if brain.isCloud { parts.append(brain.displayName) }
        if latency > 0 { parts.append(String(format: "%.1fs", latency)) }
        return parts.joined(separator: " · ")
    }
}

/// Three dots while an answer is on its way. No bubble here either.
private struct ThinkingDots: View {
    @State private var phase = 0
    private static let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.ink.opacity(phase == index ? 0.85 : 0.25))
                    .frame(width: 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: phase)
            }
        }
        .padding(.vertical, 6)
        .onReceive(Self.timer) { _ in phase = (phase + 1) % 3 }
        .accessibilityLabel("Memoir is thinking")
    }
}

/// The mic toggle. Its whole job is to make "the microphone is open" unmistakable.
struct MicButton: View {
    let state: VoiceState
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if state.isListening {
                    Circle()
                        .fill(Color.red.opacity(0.22))
                        .frame(width: 28, height: 28)
                        .scaleEffect(pulse ? 1.18 : 0.92)
                        .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: pulse)
                }
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(state.isListening ? "Stop listening" : state.shortLabel)
        .accessibilityLabel(state.isListening ? "Listening. Click to stop." : state.shortLabel)
        .onAppear { pulse = state.isListening }
        .onChange(of: state.isListening) { _, listening in pulse = listening }
    }

    private var symbol: String {
        switch state {
        case .listening: return "mic.fill"
        case .requestingPermission, .downloadingModel: return "mic.badge.plus"
        case .unavailable: return "mic.slash"
        case .idle: return "mic"
        }
    }

    private var tint: Color {
        switch state {
        case .listening: return .red
        case .requestingPermission, .downloadingModel: return Theme.warn
        case .unavailable: return Theme.ghost
        case .idle: return Theme.dim
        }
    }
}

/// The line above the field that says, in words, what the microphone is doing.
///
/// Silent when idle. Everything else (hot mic, model download, refusal) gets said
/// out loud, because "am I being recorded right now?" is not a question a user should
/// have to guess at.
struct VoiceStatusBar: View {
    let state: VoiceState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .requestingPermission:
            row(color: Theme.warn) {
                Text("Waiting for permission to listen…")
            }

        case .downloadingModel(let progress):
            row(color: Theme.warn) {
                HStack(spacing: 8) {
                    Text("Downloading the speech model… \(Int(progress * 100))%")
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                }
            }

        case .listening(let level):
            row(color: .red) {
                HStack(spacing: 8) {
                    Text("Listening on this Mac. Press Return to send.")
                        .fontWeight(.medium)
                    LevelMeter(level: level)
                }
            }

        case .unavailable(let reason):
            row(color: Theme.faint) {
                Text(reason).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(color: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6)
            content()
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(color == Theme.faint ? Theme.faint : color)
    }
}

/// Eight bars that rise with the microphone input. Proof the mic is actually hearing
/// you, which is the difference between "it is broken" and "you are muted".
struct LevelMeter: View {
    let level: Float

    private static let bars = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.bars, id: \.self) { index in
                let threshold = Float(index + 1) / Float(Self.bars)
                Capsule()
                    .fill(level >= threshold ? Color.red : Theme.ink.opacity(0.20))
                    .frame(width: 2.5, height: 4 + CGFloat(index) * 1.4)
            }
        }
        .frame(height: 16, alignment: .center)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
