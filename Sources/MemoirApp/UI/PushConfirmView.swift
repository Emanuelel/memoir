import AppKit
import SwiftUI
import MemoirKit

/// Where a push proposal has got to.
///
/// Only `.pending` carries buttons. The others are the record of a decision already made,
/// kept in the transcript on purpose: "did that actually save?" should be answerable by
/// scrolling up, not by opening the memory browser and hunting for a row.
enum PushStage: Equatable, Sendable {
    /// Parsed and on screen. **Nothing has been written in this state**: CF-51 is the whole
    /// reason the confirm step exists. `problem` is set when a previous save attempt failed,
    /// so the retry is offered exactly where the failure happened.
    case pending(PushIntent, problem: String?)
    /// The write is in flight. Buttons are gone so one decision cannot be taken twice.
    case saving(PushIntent)
    case saved(PushIntent)
    /// The user said no. Nothing was written, and the card says so rather than vanishing.
    case discarded(PushIntent)

    var intent: PushIntent {
        switch self {
        case .pending(let intent, _), .saving(let intent),
             .saved(let intent), .discarded(let intent):
            return intent
        }
    }

    /// True once the user has decided. Decided cards stay in the transcript but step back
    /// visually, so the eye lands on whatever is still asking for an answer.
    var isResolved: Bool {
        switch self {
        case .pending, .saving: return false
        case .saved, .discarded: return true
        }
    }
}

/// The card's text, as pure functions over a value type.
///
/// Split out of the view because the formatting is the part that can silently hide a
/// mis-parse, which is the single failure this whole step exists to prevent: a nil due date
/// rendered as an empty row reads as "no due date shown", not "no due date was parsed".
/// Being static and free of SwiftUI, it is also the only part of this file a test can reach.
enum PushConfirmFormat {

    /// Which field a row is, for the one row that is more than text.
    enum Role: Equatable, Sendable { case type, title, due, source }

    /// One labelled row. `given` is false when the parse produced nothing for that field:
    /// the view dims those, and never drops them. `note` is the quiet aside after the value,
    /// used for the one thing a value cannot say about itself: whose idea it was.
    struct Field: Identifiable, Equatable, Sendable {
        let role: Role
        let label: String
        let value: String
        let given: Bool
        var note: String? = nil
        var id: String { label }
    }

    /// Every field of the intent, in display order.
    ///
    /// Nothing is omitted for being empty. CF-52 says a parse never invents a field, and the
    /// user can only check that promise if the blank ones are on screen saying they are blank.
    /// An omitted row is indistinguishable from a row nobody looked at.
    ///
    /// - Parameter draft: what the due field is holding, when it is on screen. Only used to
    ///   decide whether the "Memoir's default" aside still applies.
    static func fields(
        for intent: PushIntent,
        draft: String? = nil,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [Field] {
        [
            Field(role: .type, label: "Type", value: typeText(intent.kind), given: true),
            Field(role: .title, label: "Title",
                  value: intent.title.isEmpty ? noTitle : intent.title,
                  given: !intent.title.isEmpty),
            Field(role: .due, label: "Due",
                  value: dueText(intent.dueAt, locale: locale, timeZone: timeZone),
                  given: intent.dueAt != nil,
                  note: DueEdit.note(for: intent, draft: draft, timeZone: timeZone)),
            // The user's whole phrase, kept even though their message bubble is right above
            // this card. The title is a slice of it, and putting the two side by side is what
            // makes a bad cut obvious at a glance instead of three days later.
            Field(role: .source, label: "You said",
                  value: intent.source.isEmpty ? noSource : intent.source,
                  given: !intent.source.isEmpty),
        ]
    }

    /// "Todo" or "Note", the same two words `BrainRouter.proposal` already uses for these two
    /// kinds. The text proposal and the card must not disagree about what is being saved.
    static func typeText(_ kind: EntityKind) -> String {
        kind == .commitment ? "Todo" : "Note"
    }

    /// The due date spelled out, or the words that say there is not one.
    ///
    /// Delegates to `DueEdit` rather than formatting here, because the edit field previews the
    /// time the user is typing and the two renderings must not disagree about the same
    /// instant. Absolute, never relative, for the reason recorded there.
    static func dueText(
        _ due: Date?,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        DueEdit.absoluteText(due, locale: locale, timeZone: timeZone)
    }

    /// Said out loud rather than left blank, so a date nobody mentioned cannot be mistaken
    /// for a date nobody displayed.
    static let noDate = DueEdit.noDateText
    static let noTitle = "nothing recognised"
    static let noSource = "nothing recorded"

    /// The heading, which is also the state of the write.
    static func headline(for stage: PushStage) -> String {
        switch stage {
        case .pending: return "Save this?"
        case .saving: return "Saving"
        case .saved: return "Saved"
        case .discarded: return "Discarded"
        }
    }

    /// What a pending proposal answers to. Named once because the locked composer repeats
    /// it as its placeholder, and two copies of a contract drift.
    ///
    /// The click is named first because the click is the interaction: the time is a text
    /// field, and clicking a text field puts the caret in it the way it does everywhere else
    /// on this machine. This line said "Tab to edit" once, and Tab did nothing. A footnote
    /// that advertises a keystroke the panel does not honour is worse than no footnote, so
    /// nothing goes in here that has not been made to work.
    ///
    /// Tab is honoured too, and deliberately left out of the line: it is the fallback for
    /// people who reach for it, and the space is better spent on the two keys that decide
    /// whether anything is written.
    static let pendingKeys = "Click the time to edit · Return to save · Escape to discard"

    /// The line under the fields. Every one of these is a statement about what is or is not
    /// in the database, because that is the only question the user actually has here.
    static func footnote(for stage: PushStage) -> String {
        switch stage {
        case .pending: return pendingKeys
        case .saving: return "Writing it down."
        // CF-54, in the one place where saying it is worth something: this is the moment the
        // user learns that what they type outranks everything Memoir guesses.
        case .saved: return "You wrote this one, so nothing Memoir infers can overwrite it."
        case .discarded: return "Nothing was written."
        }
    }
}

/// The confirm step: everything Memoir is about to write, before it writes it.
///
/// Deliberately not a chat bubble. A bubble is something Memoir said; this is a decision the
/// user has to make, and it should not look like more conversation.
struct PushConfirmView: View {
    let stage: PushStage
    /// The day the parse produced, held for the life of the card and never edited.
    ///
    /// Kept separately from `stage.intent.dueAt` so that clearing the field and typing a time
    /// again lands on the day the user actually said, instead of needing a day to be invented
    /// for it. nil when the phrase named no day at all, which is also what hides the editor:
    /// a field that could only ever reject what you type is not a field.
    let dueDay: Date?
    /// What the due field is holding. Owned by the controller because Return is read by a key
    /// monitor above SwiftUI, and the save path has to be able to fold this in before writing.
    @Binding var dueDraft: String
    /// Why the last committed edit was refused, if it was. Sits under the field it belongs to.
    let dueProblem: String?
    let onSave: () -> Void
    let onDiscard: () -> Void

    /// Whether the caret is in the due field. Plain `@State` fed by the field itself rather
    /// than `@FocusState`, because the field is an `NSTextField` now and the truth about focus
    /// is `NSWindow.firstResponder`. One source for it, and it is the one the panel can act on.
    @State private var dueFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            VStack(alignment: .leading, spacing: 5) {
                ForEach(PushConfirmFormat.fields(for: stage.intent, draft: isEditable ? dueDraft : nil)) { field in
                    row(field)
                    if field.role == .due, isEditable, let dueProblem {
                        Text(dueProblem)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 68)
                    }
                }
            }

            if case .pending(_, let problem) = stage, let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A tile on the black band: one fill, no border. The surface vocabulary is
        // "no card in a card", so a resolved card steps back by fading, not by chrome.
        .background(Theme.tile)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rChip, style: .continuous))
        .opacity(stage.isResolved ? 0.55 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PushConfirmFormat.headline(for: stage))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(symbolColor)
            Text(PushConfirmFormat.headline(for: stage))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            if case .saving = stage {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var symbol: String {
        switch stage {
        case .pending, .saving: return "tray.and.arrow.down"
        case .saved: return "checkmark.circle.fill"
        case .discarded: return "xmark.circle"
        }
    }

    private var symbolColor: Color {
        switch stage {
        case .pending, .saving: return .white.opacity(0.55)
        case .saved: return Theme.good
        case .discarded: return .white.opacity(0.35)
        }
    }

    /// True while the due time is the user's to change: only on a proposal that has not been
    /// decided, and only when there is a day for a time to sit on.
    private var isEditable: Bool {
        if case .pending = stage { return dueDay != nil }
        return false
    }

    /// A label and its value on one line, with the labels in a fixed column so the values
    /// line up and a wrong one is easy to spot without reading every word.
    @ViewBuilder
    private func row(_ field: PushConfirmFormat.Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(field.label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.40))
                .frame(width: 58, alignment: .leading)

            if field.role == .due, isEditable {
                dueEditor(current: field.value)
            } else {
                Text(field.value)
                    .font(.system(size: 13))
                    // A field the parse did not fill is greyed and says so in words. It is
                    // never silently absent, and never dressed up to look like something
                    // that was said.
                    .foregroundStyle(field.given ? .white.opacity(0.95) : .white.opacity(0.38))
                    .italic(!field.given)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = field.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.42))
            }
            Spacer(minLength: 0)
        }
    }

    /// The due time, in place and editable.
    ///
    /// The field holds only the time, and the resolved date beside it holds the day. Both are
    /// on screen at once on purpose: it is the only way the user can see for themselves that
    /// changing 17:00 to 09:00 did not quietly move the reminder to another day.
    ///
    /// - Parameter current: the value that is still standing, shown whenever the typed text
    ///   is not yet readable. The row never goes blank mid-edit: what is on screen at every
    ///   keystroke is either what the user is about to save or what would be saved if they
    ///   stopped now.
    private func dueEditor(current: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            DueTimeField(text: $dueDraft, isFocused: $dueFocused)
                .frame(width: 62)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.bg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(dueFocused ? Theme.ink.opacity(0.7) : Theme.line2,
                                              lineWidth: 1)
                        )
                )
                // An `NSViewRepresentable` reports no text baseline, so the row would fall back
                // to aligning on this box's bottom edge and leave the "Due" label sitting below
                // the number it labels. 15.4 is where the line inside the field actually is:
                // 3pt of padding plus the 13pt system font's ascent. Stated rather than derived
                // because there is nothing to derive it from, and eyeballing it is check 10.
                .alignmentGuide(.firstTextBaseline) { _ in 15.4 }

            // What the typed text currently means, day included. No complaint while the text
            // is half finished: shouting at every keystroke on the way to "9:30" teaches
            // people to stop reading the complaints. It falls back to the value that is
            // still standing, dimmed, so the day never leaves the screen.
            Group {
                if let preview = DueEdit.preview(dueDraft, day: dueDay) {
                    Text(preview).foregroundStyle(.white.opacity(0.55))
                } else {
                    Text(current).foregroundStyle(.white.opacity(0.28))
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if case .pending = stage {
            HStack(spacing: 8) {
                Button(action: onSave) {
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.ink))
                }
                .buttonStyle(.plain)

                Button(action: onDiscard) {
                    Text("Discard")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.50))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Text(PushConfirmFormat.footnote(for: stage))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.32))
                    // Naming the click costs more characters than naming a key did. It wraps
                    // rather than clips: a truncated instruction is the same problem as a
                    // wrong one, one ellipsis later.
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(PushConfirmFormat.footnote(for: stage))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The due time, as a real control

/// The due-time box: an `NSTextField` the panel can address by name.
///
/// This is the second attempt at this interaction, and the first one shipped a story nobody had
/// checked, so here is what was actually measured, in this panel, by `DueTimeFieldTests`:
///
/// **Tab was broken, and the reason is not subtle.** SwiftUI's hosted controls are not linked
/// into this panel's AppKit key view loop at all: the field's `nextValidKeyView` is nil, the
/// panel's `initialFirstResponder` is nil, and `selectNextKeyView` leaves the first responder
/// exactly where it found it. There was never anything for Tab to walk to, which is why adding
/// a second field and a `@FocusState` to it changed nothing. ``AskBarController`` now handles
/// Tab itself and hands the caret over outright, and the only way to hand it to *this* field is
/// to be able to find it. Hence ``identifier``.
///
/// **The click, honestly, was probably never broken.** SwiftUI's `TextField` on macOS is itself
/// an `NSTextField` subclass, and measured inside this exact panel it hit-tests correctly,
/// refuses to be a window-drag handle and accepts the first mouse, the same as this does. So
/// nothing here claims to have repaired the click. What it does is make the caret a fact the
/// panel owns rather than something SwiftUI keeps to itself: focus becomes
/// `NSWindow.firstResponder` on a view with a stable identity, which is what lets Tab reach it,
/// and what lets a test assert any of it in a process with no mouse.
struct DueTimeField: NSViewRepresentable {

    /// The text the user is typing. Written on every keystroke, because Return is read by a
    /// key monitor above this view and the save path reads this and nothing else.
    @Binding var text: String
    /// Whether the caret is in here, reported outwards so the border can light up. The border
    /// is the only thing that tells the user the click landed, so it is fed by AppKit's answer
    /// (the field editor beginning and ending) rather than by a second opinion in SwiftUI.
    @Binding var isFocused: Bool

    /// How the panel finds this field again when Tab is pressed.
    ///
    /// An identifier rather than a stored reference because the field is created by SwiftUI,
    /// several layers inside a hosting view that neither the controller nor this struct owns.
    /// Searching for it is the one way that does not depend on where SwiftUI decided to put it.
    static let identifier = NSUserInterfaceItemIdentifier("memoir.push.dueTime")

    /// Depth-first search for the due field under `root`. nil when no proposal is on screen,
    /// which is also the answer that makes Tab do nothing rather than something surprising.
    static func locate(in root: NSView?) -> NSTextField? {
        guard let root else { return nil }
        if let field = root as? NSTextField, field.identifier == Self.identifier { return field }
        for sub in root.subviews {
            if let found = locate(in: sub) { return found }
        }
        return nil
    }

    func makeNSView(context: Context) -> ClickableTextField {
        let field = ClickableTextField()
        field.identifier = Self.identifier
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = "time"
        field.font = .systemFont(ofSize: 13)
        field.textColor = NSColor.white.withAlphaComponent(0.95)
        field.alignment = .left
        // The rounded box and its border are drawn by SwiftUI behind this, so the control
        // itself draws nothing: a second bezel inside the first is the tell that a native
        // control has been dropped into a design that was not expecting one.
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        // It is 62pt wide because the row says so, not because "17:00" is five characters.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Due time")
        return field
    }

    func updateNSView(_ field: ClickableTextField, context: Context) {
        context.coordinator.parent = self
        // Only when it genuinely differs. Assigning during editing would move the caret to the
        // end on every keystroke, and the value here is normally one this field just produced.
        if field.stringValue != text { field.stringValue = text }

        // Nothing here puts focus back after a rebuild, on purpose. A guard for that was
        // written, and then the test for the case it guarded (a refused time appearing under
        // a live edit) passed with the guard disabled: SwiftUI updates this view rather than
        // replacing it, so the field editor is never disturbed. Code that guards nothing reads
        // like a hazard somebody handled.
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DueTimeField

        init(_ parent: DueTimeField) { self.parent = parent }

        /// Every keystroke, not just the committed value. The save path folds `dueDraft` in
        /// before it writes, and a time the user typed but Memoir never read is the same silent
        /// failure as the default they were correcting.
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            // A field being torn out of a window is not the user leaving the field, and only
            // the second of those should put the border out.
            guard let field = notification.object as? NSTextField, field.window != nil else { return }
            parent.isFocused = false
        }
    }
}

/// An `NSTextField` with the two answers a click depends on pinned rather than assumed.
///
/// Neither override changes anything today: a stock `NSTextField` already returns exactly
/// these, which was measured rather than believed. They are written down because the ask bar
/// is unusual in two ways that both bear on whether a press ever reaches this box, and a
/// default quietly changing underneath us would take the click away again with nothing to
/// notice. `DueTimeFieldTests` asserts both, so they are claims under test rather than
/// decoration.
final class ClickableTextField: NSTextField {

    /// The panel is movable by its background. AppKit decides whether a press starts a window
    /// drag by asking the view under the pointer, and a yes here is a click the user never
    /// gets: the panel slides half an inch and the caret never appears.
    override var mouseDownCanMoveWindow: Bool { false }

    /// The bar deliberately stays open when you click away, which is check 8, so it is often
    /// not the key window when the user goes for the time. A press at a window that is not key
    /// is normally spent making it key and then discarded. This spends it on the caret, so the
    /// time takes one click rather than two.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
