# Manual checks: the PUSH confirmation panel

Everything underneath this panel is covered by automated tests: parsing, saving, refusing to save,
the authored/inferred rule, and every decision the due-time edit makes. A further eleven build the
real ask-bar panel offscreen and assert the AppKit facts the due-time click depends on. What no
test can do is press a mouse button on a visible window, so this is the part that needs a person.

Thirteen checks, about seven minutes. Each says what to do, what should happen, and what a failure
looks like. The last one matters most, because "it did something" is easy to mistake for "it
worked".

```bash
cd ~/Claude/Projects/memoir && Scripts/build-app.sh && Scripts/deploy.sh
```

Then launch Memoir and press **⌥Space**.

---

### 1 · A todo is proposed, not saved

Type: `remind me to send the invoice friday` and press **Return**.

**Expect** a panel showing roughly:

```
Todo: send the invoice
Due: Fri 7 Aug, 17:00
Press return to save, or escape to discard.
```

**Failure looks like:** an *answer* instead of a proposal ("You have no invoices recorded"). That
means the router sent it down the question path. Or a proposal with no due date, which means the
date parse failed silently.

---

### 2 · Escape really discards

With that panel still open, press **Escape**. Then reopen ⌥Space and ask `what do I owe anyone`.

**Expect** the invoice **not** to be listed.

**Failure looks like:** the todo appearing anyway. That would mean it was written before you
accepted, which is the single thing this whole design exists to prevent.

---

### 3 · Return really saves

Type the same phrase again, and this time press **Return** at the panel.

**Expect** a brief confirmation, and Memoir's face to **wink**.

Then ask `what do I owe anyone`: the invoice should be listed now.

**Failure looks like:** no visible confirmation. Not knowing whether it saved is the failure, even
if it did.

---

### 4 · A missing date is stated, not hidden

Type: `remind me to renew the domain` (no date).

**Expect** the panel to say **"Due: no date given"** explicitly.

**Failure looks like:** the Due line simply absent. A blank field is something you can skim past; a
stated "no date given" is something you notice and correct. That distinction is the point.

---

### 5 · A note is a note

Type: `remember that the wifi password is on the fridge`.

**Expect** `Note: the wifi password is on the fridge`, with **no** due date, and the word "Note"
rather than "Todo".

---

### 6 · The question side still works

Type: `remind me what I was working on`.

**Expect** a normal answer about your recent work. **No panel, nothing saved.**

**This is the most important check on the list.** Those first three words are identical to check 1.
If this one shows a save panel, the feature has started eating your questions, and that is worse
than the feature not existing.

---

### 7 · Something it cannot parse says so

Type: `asdfghjkl remind`.

**Expect** roughly *"I did not catch what to save. Try starting with 'remind me to' or 'remember
that'."*

**Failure looks like:** silence, or a saved entry with a garbled title. Dropping what you said
without telling you is the unacceptable outcome.

---

### 8 · State survives clicking away

Type half a phrase (`remind me to call the`), then **click somewhere else on screen**, then press
⌥Space again.

**Expect** your half-typed text still there.

**Failure looks like:** an empty box. This regressed once before: `NSPanel.hidesOnDeactivate`
defaults to true and silently destroyed in-progress input.

---

### 9 · It is marked as yours

Open the memory browser (menu bar → Memory) and find the invoice todo.

**Expect** it labelled **"you told me"**, visibly different from entries Memoir inferred from your
screen.

**Failure looks like:** no distinction. If you cannot tell at a glance which entries are guesses,
you inherit our uncertainty without being told about it.

---

### 10 · The hour Memoir picked admits it is Memoir's, and **one click** changes it

Type: `remind me to send the invoice friday` and press **Return**.

**Expect** the Due row to show an editable time box holding `17:00`, the full date beside it, and
the words **"Memoir's default"** after it.

Now **click straight on the `17:00`**. One click, no keys first.

**Expect** the caret to appear where you clicked and the box's border to light up blue. Select the
text, type `9am`, and watch the line beside it become `Fri … , 09:00` while "Memoir's default"
disappears. Press **Return**.

Ask `what do I owe anyone` and check the hour that comes back.

**Failure looks like:** the click doing nothing, or needing a second click, or the panel sliding
under the pointer instead of taking the caret. This is the check the whole branch exists for: the
first attempt shipped a footnote saying "Tab to edit" when Tab did nothing, so **do not accept a
keystroke as a substitute here**: if only Tab works, the check has failed.

Then the original failure, which still counts: the saved reminder still at 17:00. A time you typed,
watched appear, and never got. Almost as bad, "Memoir's default" still showing after you typed your
own hour, which tells you Memoir chose something you chose. And worst of all, the **day** moving:
`9am` must land on the same Friday, never on today and never on Saturday.

---

### 11 · A time it cannot read is refused out loud, without losing your place

At the panel for `remind me to send the invoice friday`, **click the time**, clear the box, type
`bananas`, and press **Return**.

**Expect** a red line under the Due row saying it did not recognise that as a time and suggesting
what to type, the time still reading `Fri … , 17:00`, and **nothing saved**. The caret should
still be in the box: type `9:30` straight away, without clicking again, and press **Return**. Now
it saves.

**Failure looks like:** it saving anyway. Keeping 17:00 under someone who believes they just set a
different hour is the same failure as the default they were correcting, one step later. Silence is
also a failure: if nothing appears, you cannot tell a refusal from a machine that froze. And having
to click back into the box after the red line appears is a small failure worth reporting: the
panel should not lose your place because it disagreed with you.

---

### 12 · Clearing the box removes the date rather than inventing midnight

Same panel, **click the time**, delete everything in the box.

**Expect** the line beside it to read **"no date given"**. Press **Return**, then open the memory
browser and find the todo.

**Expect** no due date on it at all.

**Failure looks like:** a due date of **00:00** on that Friday. An empty field means "no time on
this", not "the very start of the day", and a reminder that fires while you are asleep is one you
will never see. A date that survives clearing is the same failure wearing a different hour.

---

### 12b · Tab, the fallback (30 seconds, and it is allowed to fail quietly)

At a pending panel, press **Tab** without touching the mouse.

**Expect** the caret to land in the time box. Press **Tab** again: it is allowed to leave.

**Failure looks like:** nothing happening, which is what it did before this branch. Report it, but
it is not a blocker: check 10 is the interaction, this is the courtesy.

---

## What to report back

For any failure, the most useful thing is **what you typed and what appeared**, verbatim. If
nothing at all happened, the log usually says why:

```bash
tail -40 ~/Library/Application\ Support/Memoir/memoir.log
```

## Known-untested, so no surprise if odd

- The panel's exact sizing and position under the notch.
- Behaviour on a second display, or with an external monitor as primary.
- VoiceOver navigation of the panel.
- **A real mouse press.** The suite now builds the actual ask-bar panel offscreen and asserts the
  things a click depends on: that the box is a control and not a window-drag handle, that a hit
  test at it returns the box, that it accepts the first mouse, that the panel will give it the
  caret, and that typing into that caret reaches the value the save path reads. What no process
  without a screen can do is press the button. Check 10 is that press, and it is the only reason
  to believe the interaction end to end.
- **Tab.** Handled by hand now, because SwiftUI's controls are not in this panel's key view loop
  at all: the field's `nextValidKeyView` is nil and `selectNextKeyView` moves nothing, which is
  why the old footnote's promise was empty. The handler itself is tested; the keystroke reaching
  the handler is check 12b.
- The Due row's **vertical alignment**. The box is an `NSTextField` now, and an AppKit view
  reports no text baseline to SwiftUI, so the row's baseline is a stated number rather than a
  measured one. If the "Due" label or the date beside the box sits a point high or low, that is
  this, and it is worth reporting.
- The panel's layout once the Due row carries a box, a date and a label at the same time, and the
  footnote now names the click rather than a key. A row or footnote that wraps is fine; one that
  clips is not, because a clipped instruction is a wrong one with an ellipsis on the end.
