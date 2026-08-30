//  The click that puts the caret in the due-time box.
//
//  This is the second attempt at that interaction. The first shipped a footnote advertising
//  Tab, and Tab did nothing. So the point of this file is narrow and unglamorous: assert the
//  AppKit facts the click actually depends on, inside the window it actually happens in, so
//  that "it compiles" is not the whole case for it working.
//
//  What is asserted here:
//    · the field exists in the card and can be found from the panel (that is Tab's mechanism);
//    · it is not a window-drag handle, which is what swallowed the click before;
//    · a hit test at the box lands on it, which is how AppKit chooses who gets the mouseDown;
//    · the panel will make it first responder, and the caret is a real field editor;
//    · typing into that editor reaches the binding the save path reads.
//
//  What is NOT asserted, because no test in this process can: that a physical mouse press on a
//  visible panel does all of the above in one motion. That is manual check 10.

import AppKit
import SwiftUI
import Testing
import MemoirKit

@testable import MemoirApp

/// The due draft, held somewhere the test can read it. The real card's draft lives on
/// `AskBarState` for the same reason: the save path has to be able to read it.
@MainActor
private final class DraftBox: ObservableObject {
    @Published var text: String
    /// The refusal under the Due row. Published so a test can put it there mid-edit, which is
    /// the one moment the card is rebuilt while the user still has the caret in the box.
    @Published var problem: String?
    init(_ text: String) { self.text = text }
}

/// A pending proposal card, in a scroll view, which is where the ask bar puts it.
private struct CardHarness: View {
    /// Roomy enough for the whole card; the exact figure is not load-bearing.
    static let hostSize = NSSize(width: 480, height: 420)

    @ObservedObject var draft: DraftBox
    let intent: PushIntent
    let day: Date

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                PushConfirmView(
                    stage: .pending(intent, problem: nil),
                    dueDay: day,
                    dueDraft: $draft.text,
                    dueProblem: draft.problem,
                    onSave: {},
                    onDiscard: {}
                )
            }
            .padding(14)
        }
        .frame(width: CardHarness.hostSize.width,
               height: CardHarness.hostSize.height)
    }
}

@Suite("CF-53 · the due time takes a click", .serialized)
@MainActor
struct DueTimeFieldTests {

    /// Friday 20 March 2026, 17:00: the value a bare "friday" produces, and the one the user
    /// is trying to click on and change.
    private static var friday: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 20
        components.hour = 17; components.minute = 0
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private static var proposal: PushIntent {
        PushIntent(
            kind: .commitment,
            title: "send the invoice",
            dueAt: friday,
            dueTimeIsConvention: true,
            source: "remind me to send the invoice friday"
        )
    }

    /// The card, inside the real panel.
    ///
    /// Built through ``NotchPanelController/makeBandPanel()`` rather than as a fresh
    /// `NSWindow` on purpose: `.nonactivatingPanel` is one of the two settings that broke
    /// the click historically, so a test that quietly used a plainer window would prove
    /// nothing about the window that ships, which is the notch band's panel now.
    private static func hostCard() -> (panel: NSPanel, draft: DraftBox, field: NSTextField) {
        // Windows and field editors need an application object. Prohibited, so a test run
        // does not put anything in the Dock or take the user's focus.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let panel = NotchPanelController.makeBandPanel()
        panel.setFrame(NSRect(origin: .zero, size: CardHarness.hostSize), display: false)
        let draft = DraftBox("17:00")
        let hosting = NSHostingView(
            rootView: CardHarness(draft: draft, intent: proposal, day: friday)
        )
        hosting.frame = NSRect(origin: .zero, size: CardHarness.hostSize)
        panel.contentView = hosting

        let field = waitForField(in: hosting)
        // A missing field is the failure this whole file exists to catch, so it is a hard
        // stop rather than an optional that quietly makes every later assertion vacuous.
        guard let field else {
            fatalError("the due-time field never appeared in the hosted card")
        }
        return (panel, draft, field)
    }

    /// SwiftUI builds its `NSView`s on its own schedule, so the search is retried while the
    /// run loop turns rather than once, immediately, and then declared broken.
    private static func waitForField(in root: NSView, timeout: TimeInterval = 5) -> NSTextField? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            root.layoutSubtreeIfNeeded()
            if let field = DueTimeField.locate(in: root) { return field }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return DueTimeField.locate(in: root)
    }

    // MARK: - The click

    @Test("the due field is in the card, and the panel can find it")
    func fieldIsReachable() {
        let (panel, _, field) = Self.hostCard()
        #expect(field.identifier == DueTimeField.identifier)
        // The same lookup Tab uses, from the same starting point Tab uses.
        #expect(DueTimeField.locate(in: panel.contentView) === field)
    }

    @Test("the field is not a window-drag handle")
    func fieldIsNotADragHandle() {
        let (_, _, field) = Self.hostCard()
        // This is the bug, stated as an assertion. The panel is movable by its background;
        // AppKit asks the view under the pointer whether the press should move the window
        // instead of being delivered, and a yes here is a click the user never gets.
        #expect(field.mouseDownCanMoveWindow == false)
    }

    @Test("a press at the box is delivered to the field, not to the panel")
    func hitTestLandsOnTheField() {
        let (panel, _, field) = Self.hostCard()
        guard let content = panel.contentView else {
            Issue.record("the panel has no content view"); return
        }
        // `hitTest` takes a point in the receiver's *superview* space, which is the mistake
        // that made the first run of this test accuse the wrong view.
        let inContent = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: content)
        let hit = content.hitTest(content.convert(inContent, to: content.superview))

        // AppKit delivers the mouseDown to whatever this returns, so "the click reaches the
        // field" and "hit testing at the box returns the field" are the same statement.
        let landedOnField = hit === field || hit?.isDescendant(of: field) == true
        #expect(landedOnField, "hit test at the time box returned \(String(describing: hit))")
        // And whatever it returned must not be a drag handle either, or the press is spent
        // moving the panel before the field ever hears about it.
        #expect(hit?.mouseDownCanMoveWindow == false)
    }

    @Test("one click is enough, even when the panel was not the key window")
    func acceptsTheFirstMouse() {
        let (_, _, field) = Self.hostCard()
        // The bar deliberately does not close when you click away (check 8), so it is often
        // not key when the user goes for the time. Without this, the first click is spent
        // making the panel key and thrown away, and the time needs two clicks.
        #expect(field.acceptsFirstMouse(for: nil))
    }

    @Test("the panel gives it the caret, and the caret is a real field editor")
    func takesFirstResponder() {
        let (panel, _, field) = Self.hostCard()
        #expect(panel.makeFirstResponder(field))
        // A focused NSTextField hands off to a field editor: the window's first responder
        // becomes that editor, not the field. Anything else means there is no caret.
        let editor = field.currentEditor()
        #expect(editor != nil)
        #expect(panel.firstResponder === editor)
    }

    @Test("typing in the focused field reaches the value the save path reads")
    func typingReachesTheDraft() {
        let (panel, draft, field) = Self.hostCard()
        #expect(panel.makeFirstResponder(field))
        guard let editor = field.currentEditor() as? NSTextView else {
            Issue.record("the field never got a field editor"); return
        }

        editor.selectAll(nil)
        editor.insertText("9am", replacementRange: editor.selectedRange)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // Not "the field shows 9am": the field showing something Memoir never read is exactly
        // the failure this panel exists to prevent, one layer down.
        #expect(field.stringValue == "9am")
        #expect(draft.text == "9am")
    }

    @Test("a refused time does not cost the caret")
    func focusSurvivesARefusal() {
        let (panel, draft, field) = Self.hostCard()
        #expect(panel.makeFirstResponder(field))

        // Check 11, exactly: an unreadable time puts a red line under the Due row, which
        // rebuilds the card while the user still has the caret in the box. If focus went with
        // it, correcting "bananas" to "9:30" would need a second click, and the panel would be
        // teaching the user that it loses their place whenever it disagrees with them.
        draft.text = "bananas"
        draft.problem = "That did not read as a time. Try 9am, 09:00 or 9.30pm."
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        panel.contentView?.layoutSubtreeIfNeeded()

        let stillThere = DueTimeField.locate(in: panel.contentView)
        #expect(stillThere != nil)
        #expect(panel.firstResponder === stillThere?.currentEditor())
    }

    // MARK: - Tab, the fallback

    @Test("Tab puts the caret in the due field")
    func tabFocusesTheField() {
        let (panel, _, field) = Self.hostCard()
        // The real handler, with the two inputs the key monitor gives it.
        #expect(ChatController.moveCaretToDueField(in: panel, pendingPush: true))
        #expect(panel.firstResponder === field.currentEditor())
    }

    @Test("Tab is left alone when there is nothing to edit")
    func tabIsInertWithoutAProposal() {
        let (panel, _, _) = Self.hostCard()
        // No pending proposal means the key belongs to whatever else wants it. Consuming Tab
        // unconditionally would break tabbing anywhere else in the bar for no benefit.
        #expect(ChatController.moveCaretToDueField(in: panel, pendingPush: false) == false)
        #expect(ChatController.moveCaretToDueField(in: nil, pendingPush: true) == false)
    }

    @Test("a second Tab lets go rather than trapping the caret")
    func tabLeavesTheFieldOnce() {
        let (panel, _, _) = Self.hostCard()
        #expect(ChatController.moveCaretToDueField(in: panel, pendingPush: true))
        // Already there: the key is not consumed, so Tab keeps meaning "move on" the way it
        // does in every other text field on the machine.
        #expect(ChatController.moveCaretToDueField(in: panel, pendingPush: true) == false)
    }

    // MARK: - The footnote

    @Test("the footnote promises the click, and no longer promises Tab")
    func footnoteMatchesReality() {
        let keys = PushConfirmFormat.pendingKeys
        // The regression this file is named after: the line advertised a keystroke that did
        // nothing. Whatever the wording becomes, it may not go back to naming Tab.
        #expect(!keys.contains("Tab"))
        #expect(keys.localizedCaseInsensitiveContains("click"))
        #expect(keys.contains("Return"))
        #expect(keys.contains("Escape"))
        #expect(!keys.contains("\u{2014}"), "no em dashes in user-facing copy")
    }
}
