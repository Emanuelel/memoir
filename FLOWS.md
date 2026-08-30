# Memoir: Core Flows

The contract for "is it still working". Every flow has a stable ID, a plain-English statement, and a pass condition. Integration tests are named after these IDs so a failure names the broken flow, not a broken function.

Run them all with `Scripts/verify.sh` after every meaningful change.

**Unit tests ask "does this function work". These ask "does the product still do its job".** Every flow crosses at least two modules and uses a real SQLite database on disk.

---

## Tier 0. Trust invariants

If any of these break, the product is not shippable. They are the promises made to the user, and they must fail loudly.

### CF-1 · A user correction is permanent
Edit an entity's title, then run extraction again over the same source text, repeatedly, with higher-confidence input.
**Pass:** the corrected title survives every subsequent pass. `corrected` stays true. Confidence may rise, the title never changes.
*The single most important invariant in the product. If this breaks, the memory cannot be trusted, and an untrustworthy memory is worse than none.*

### CF-2 · Nothing leaves the machine when local-only
Run the full pipeline with `allowCloud = false`: capture, consolidate, ask, MCP query.
**Pass:** zero outbound requests. Asserted structurally by a counting URLProtocol that intercepts everything and fails the test if any request is attempted.

### CF-2b · The outbound counter is measured, not inferred
Inspect where `OutboundMonitor.record` is called, and in what order relative to the send.
**Pass:** exactly four call sites (`AnthropicBrain`, `LocalNetworkBrain`, `ClaudeCodeBrain`, `UpdateCheck`), and in each the record *precedes* the send, so a request that fails is still counted.
The fourth is the only one that can fire without the user asking a question, which is why it is named here rather than waved through: it is a `GET` for a static version file carrying nothing about the caller, it is off with one switch, and CF-2c is what keeps it that way.
*The counter is what PRIVACY.md offers instead of asking to be trusted, so it has to be true at the point of sending. It was not: it lived in `MemoirApp`, which `MemoirKit` cannot import, and fired after an answer returned based on which brain answered. It counted answers, and missed extraction's `complete()`, the `memoir-ask` CLI, the network brain, and every failed request.*

### CF-2c · The update check asks a question, it does not report on you
Fetch the manifest against a stubbed session and inspect the request that was sent.
**Pass:** a `GET`, with no query string, no body, and no `Authorization` or `Cookie` header: nothing that could identify the machine, the user or even which version is asking. The comparison happens locally against the running binary's version. It is recorded by `OutboundMonitor` before the send like every other site (CF-2b), so it appears in Settings → Data.
*This is the one request that goes out without the user initiating it, so the distinction between "asks a question" and "reports on you" is the whole justification for it existing in a product that promises no telemetry. Appending a version to make a server's life easier would quietly turn one into the other, which is what this test exists to prevent.*

### CF-3 · A cloud brain is never selected without consent
Set `allowCloud = false` and explicitly prefer `anthropicAPI`. Separately, configure a local network endpoint with `allowLocalNetwork = false`.
**Pass:** the router returns a local brain. Never a cloud one, and never the network one. Not on fallback, not on retry, not when every local brain is unavailable.
*What may run is "everything that stays on this Mac", which is smaller than "everything that is not cloud". `localNetwork` is not cloud (no third party, no account), but it POSTs the context packet to another host, so it needs consent of its own. `BrainKind.isCloud` said so in a comment for a long time while the brain in fact ran on nothing but an endpoint being configured.*

### CF-4 · The API key never persists outside the Keychain
Save a key, run the whole pipeline, then grep the database file, config.json, UserDefaults and the log file.
**Pass:** the key string appears in none of them.

### CF-5 · Excluded apps are never captured
Put an app on the exclusion list and make it frontmost.
**Pass:** no capture row exists for it. Not truncated, not redacted. Absent.

### CF-5b · The system's own credential prompts are never captured
Make `SecurityAgent`, `loginwindow` or `UserNotificationCenter` frontmost. Separately, decode a `config.json` written before these were excluded.
**Pass:** no capture row for any of them; the older config is seeded with the new identifiers exactly once, without discarding the user's own additions or undoing their removals; and captures already taken from them can be retired along with the provenance quoting them.
*The exclusion list covered Keychain Access (the app you open) and missed the sheet macOS puts in front of you. Measured on a real database: 40 captures across the three, 23 holding the text of a credential prompt, one reading "enter the login keychain password". The secure-field skip did its job and no password value was ever stored; the prompt around it was. Adding to a default only ever helps the next install, because the exclusion set is persisted whole.*

### CF-6 · Secure fields are never read
Present an element whose subrole is `AXSecureTextField`.
**Pass:** its value appears in no capture, and the walk does not descend into it.

### CF-7 · Delete everything actually deletes everything
Populate captures, entities, provenance and sessions, leave `memoir.sqlite.v{N}.backup` snapshots beside the database, then `purgeEverything()`.
**Pass:** every table is empty, FTS indexes are empty, the file has been vacuumed smaller, and **no snapshot survives**, along with `proposals.json`, `asks.jsonl` and `memoir.log`. A wipe that cannot finish reports the failure instead of reporting success.
*CF-7b requires those snapshots to be written before a migration; nothing required them to survive this button. Measured on a real installation: 66 MB of them beside a 42 MB live database, so the folder barely shrank while the panel read zero. `asks.jsonl` was the same shape of miss: it holds the full context packet given to every brain, its own doc comment claimed it was deleted here, and `AskLog.purge()` had no callers anywhere in the project.*

### CF-9 · There is a way out that is not deletion
Populate a memory, then export it as JSON and as Markdown.
**Pass:** the archive's counts match the store's exactly; deleted entities leave flagged rather than filtered; the JSON decodes with a plain `JSONDecoder` and no knowledge of Memoir; the Markdown names every live entity and quotes the evidence under each; and the export changes nothing.
*Settings had a prominent "Delete everything" and no export of any kind: no JSON, no CSV, no markdown, no flag, no button. For a product whose pitch is that the memory is yours and stays on your machine, that asymmetry says leaving and destroying are the same act. Measured on a real 42 MB database: 13.8 MB of JSON, 341 KB of Markdown, about a second each.*

### CF-7b · A schema change is snapshotted first
Wind a populated database back a version and reopen it with migration allowed.
**Pass:** a `memoir.sqlite.v{N}.backup` exists beside it before any migration runs, it opens and
contains the rows, and a second run does not overwrite it. A failed backup warns but never blocks
the upgrade: a user who cannot migrate is worse off than one who migrates without a spare copy.
*A real user upgrading Memoir runs these migrations over the only copy of everything they have asked
it to remember.*

### CF-7c · A schema change requires consent, and a newer one never bricks the app
Open a populated older database from a tool, then from the app. Open a NEWER one from either.
**Pass:** the tool is refused and the version is left exactly as it was; the app, which passes
`mayMigrate: true`, upgrades it. A fresh database always initialises without asking, because
creation is not migration and nobody can lose what they never had. A database newer than the build
is **read**, with a warning, never refused.
*Both halves were live failures within an hour of each other. `memoir-ask --embed`, a developer tool,
silently migrated the user's database v3 → v4. The installed v3 app then quit with "Memoir can't
start" over a database that was completely intact. Opening for read-write must not imply "and
upgrade my schema", and a version check that kills a working app is a policy choice that was
simply wrong.*

---

## Tier 1. The pipeline

The product's actual job, end to end.

### CF-8 · Private browsing is never captured
Browse in an incognito or private window in any browser.
**Pass:** no capture row exists for it, in any language. Ordinary windows whose titles merely
contain the word "private" are unaffected.
*Private browsing is the clearest signal a user can give that something should not be
remembered. The browser only stops recording its own history; nothing stops an
accessibility reader, so it has to be honoured explicitly.*

### CF-10 · Capture lands correctly
A snapshot with real text becomes a row with the right app, timestamp, text and hash.
**Pass:** round-trips through the Store unchanged.

### CF-11 · Identical screens dedupe
The same text captured twice in a row.
**Pass:** exactly one row. *This is what kept the count frozen at 30. Worth guarding forever.*

### CF-12 · Changed screens do not dedupe
Text that differs by one word.
**Pass:** two rows.

### CF-12b · Capture fires on events, not on a timer
A static screen, an app switch, a document change, continuous typing, and an idle period.
**Pass:** an unchanging screen produces **no** captures; app switch and window change each
produce one; typing produces exactly one capture *on the pause*, never one per keystroke;
a 200ms global floor and a 1.5s checkpoint floor for bursts are both enforced; idleness
suppresses everything and does not leave a stale typing pause pending on return.
*Capture used to run on a fixed timer regardless of change: the direct cause of eight
copies of one page in a single context packet, and of CPU burned on a static screen.*

### CF-13 · Sessions rotate on app switch
Frontmost app changes A → B → A.
**Pass:** three sessions with sane durations, none overlapping.

### CF-14 · Extraction finds commitments with dates
Feed realistic text: a Slack thread, an email, a standup note.
**Pass:** commitments extracted, relative dates ("Friday", "tomorrow") resolved against a **fixed injected reference date**, never the wall clock.

### CF-14b · Extraction refuses other people's words
Feed a social timeline, a group chat with speaker labels, a design note full of style tokens, and
the twenty-three junk rows lifted verbatim out of the user's live "Open commitments" list.
**Pass:** nothing becomes a commitment unless the user plausibly made it, and nothing junk-shaped
survives in the database either: every class below is refused at write time *and* recognised by
`RuleExtractor.isJunkEntity`, which is what CF-14c replays over the rows already stored.

The classes, each named after the rows that motivated it:

| class | what it is | the row |
|-------|-----------|---------|
| timeline furniture | a post with its handle, Follow button, counters and "5/30/26, 8:01 PM" footer | a stranger's tweet |
| speaker labels | a line attributed to a named third party | "~Pawel :", "Marco:" |
| style tokens | design vocabulary filed as a project | "gentler/hand-drawn" |
| code-host chrome | three pieces of GitHub's vocabulary **with nobody speaking**, a `owner/Repo:` heading not followed by a task or a pronoun, a Q&A page title | "main branch 1 Branch 2 Tags Go to file Add file…" |
| prompts to assistants | a network **address** (a port or a path, not the bare word `localhost`), **two** shouted constraints in one breath, a coding agent named in a sentence with no deadline | "can you qccess localhost:4611/ui.html" |
| product tours | a third-party chatbot narrating its own flow; "Let's proceed" as a **whole utterance**, not carrying an object | "Let's proceed! You will be able to see the model…" |
| broadcast posts | an announcement written for an audience, which presupposes a crowd | "I'm incredibly excited to announce…" |
| sentiment promises | a first-person promise with **no moment to do it by and no task verb after it** | "I'll be there", "I'll stay closely connected" |
| marketing | ad copy, a shouted banner **carrying no instruction**, a listing title with its site name appended | "SIN PERMANENCIA - TODO INCLUIDO" |
| assistant register | a model offering to do work, judged **one segment at a time** | "say the word and I'll…", "want me to…" |
| Memoir's own interface | Memoir's copy and its example questions, **with nobody speaking** | "a nudge, or something due soon" |
| foreign prose | an article in a language these rules cannot judge, **and no task marker on the line** | "le due colonne" (Italian for "two", not a deadline) |

"due" is also tightened to require a date behind it, so a preposition ("missing … due to notch"),
an adverb ("due soon") and the Italian number are no longer deadlines. It still accepts the real
forms: "due at 5pm on Friday" and "due in two weeks".

The bold clauses are the repairs measured in CF-14d. Each one replaces a token the guard used to
match anywhere with the structure that actually makes the row junk.

A real promise in the same shape still lands, and the table is checked one sentence at a time:
"I'll send the invoice Friday" in Slack, "can you review the PR before standup?" addressed to the
user, "- [ ] renew the domain" in a note, "TODO: reply to Marco", "I need to file the tax return by
the 30th". If a guard kills one of these, the guard is wrong, not the example.

**Measured:** on the twenty-four-row corpus, precision goes from 1 in 24 (4%) to 1 in 1 (100%).
Twenty-three rows are retired and the one left standing is the one the user typed.
*The converse of CF-14, and the more important half. Memoir's live memory contained "mikkel torres
@0xquillvox follow i will tell my kids that arden built this in a cave with a box of scraps
5/30/26, 8:01 PM 28" as an OVERDUE commitment: a stranger's tweet, scraped off a timeline and shown
as the user's obligation, with a deadline. Inventing a debt is the worst class of false memory,
because it is acted upon.*

### CF-14c · Fixing the extractor sweeps up behind it
Populate entities that today's guards would refuse, then run the sweep.
**Pass:** they are soft-deleted, authored entities are never touched, and a dry run reports without
deleting. A second sweep finds nothing.
*A guard only ever protects what has not been written yet. The rows that motivated CF-14b were
still on screen after it shipped.*

### CF-14d · The guards do not eat real commitments
Feed thirty-five genuine commitments, each in the shape of one of the junk classes above, then
store them and run the sweep over them.
**Pass:** at least **26 of 35** are extracted, and **none** is retired by the sweep. Every guard
fires on the SHAPE of the junk, never on a word the junk happens to contain, and the minimal-pair
check proves it: the same sentence with and without the trigger token must get the same verdict.

**Measured:** 35 of 35 kept, 0 retired.

*This flow exists because CF-14b alone is not a contract: a memory that refuses everything passes
it perfectly, and the first cut of these guards very nearly did. Measured over these thirty-five
sentences it kept **7**, against 28 for the branch before it, and it retired **24** already-stored
real commitments the first time the sweep ran. Every loss was a single common token: "nudge",
"readme", "localhost", "cookie", "definitely", "privacy policy". A memory that refuses four fifths
of your promises is as useless as one full of junk, and it fails silently instead of visibly.*

*So "when in doubt, refuse" is no longer the whole rule. Refuse a SHAPE, not a word. Where a guard
cannot be made precise, let the row through and catch it in `isJunkEntity` with more context, or
drop the guard and say so in its doc comment. PUSH is a repair for a missed commitment, not a
licence to miss them.*

### CF-15 · Every entity is traceable
Any extracted entity.
**Pass:** at least one provenance row pointing at a real capture ID, with a snippet that genuinely appears in that capture's text.

### CF-16 · Consolidation is idempotent
Run `consolidate` three times over the same captures.
**Pass:** entity count is identical after runs 2 and 3. No duplicates from re-processing.

### CF-17 · Ask returns an attributed answer
Ask a question with seeded memory.
**Pass:** non-empty answer, a `BrainKind` that matches the brain that actually ran, and every cited capture ID resolves to a real row.

### CF-17b · Answers stay grounded in their evidence
Ask a question whose category is empty, and inspect any figure the answer states.
**Pass:** every number in a generative answer appears in that turn's evidence (context +
question). One that does not is fabricated: the answer is replaced with an honest refusal.
Currency is part of the token, so `100%` in an unrelated page cannot ground `$100`.
`rulesOnly` is exempt: it computes from the store and cannot invent.
*The model answered "You owe someone $100" against zero commitments, with "none recorded"
as the first line of its context. Prompting did not fix it; enforcement did.*

### CF-18 · The floor always answers
Disable every brain except `rulesOnly`.
**Pass:** still a useful, non-empty, non-placeholder answer. The product never says nothing.

### CF-19 · Context stays within budget
Seed 500 entities and 5,000 captures, request a 2,000-token packet.
**Pass:** estimate ≤ budget, pinned and due-soon entities present, and it completes in reasonable time.

---

## Tier 2. Lifecycle and restraint

### CF-19b · Questions are routed cheaply, and escalate only when unsure
Ask questions spanning all five categories and inspect how each was classified.
**Pass:** confident questions (margin ≥ 0.075) are classified by on-device embeddings in
~4ms with no model call; low-margin questions escalate to a `@Generable`-constrained
classifier that can only return a valid category; escalation failure degrades to the
embedding answer rather than losing the question; with no embeddings at all a keyword
fallback still classifies.
*Measured: 14/16 correct for free, and both errors fell below the threshold. The router
knows when it does not know. Follows the FrugalGPT/RouteLLM cascade pattern, where the
calibrated confidence signal is the load-bearing part, not the routing itself.*

### CF-20 · Retention rolls off captures but never entities, and keeps everything by default
The default window is **zero, meaning keep everything**. A zero must never be read as a cutoff of "now": that arithmetic would delete a decade of somebody's life the first time the maintenance sweep ran, silently, on a machine that had done nothing wrong. Guarded in `MemoryService.applyRetention` and again in Settings, and tested both ways.
Seed captures across 120 days, retain 60.
**Pass:** old captures gone, recent captures kept, **entity count unchanged**. Memory outlives its raw source.

### CF-21 · Provenance survives its capture
An entity whose source capture has been purged by retention.
**Pass:** the entity remains and the memory browser degrades gracefully to "source expired" rather than crashing or showing a dangling reference.

### CF-22 · The restraint gate holds
Quiet hours including a window wrapping midnight, cooldown, daily cap, dismissal backoff, focus suppression.
**Pass:** every suppression case returns nil. Time is always injected, never read from the clock.

### CF-23 · Pause means paused
Pause capture while a screen read is provably in flight, then wait for several loop ticks (measured by a second, unpaused loop rather than by sleeping).
**Pass:** zero new rows, the in-flight read's result never reaches the database, and polling settles and then stops. Resume, and capture continues.
*The settling matters: `stop()` can land after a read has already been entered, so the number of reads is legitimately 2 or 3. Pinning it at 2 made this the only flaky test in the suite (red about one run in four), which is survivable locally and corrosive on CI, where it fails a stranger's pull request for something they did not do.*

---

## Tier 3. The MCP contract

Tested against the **real compiled binary as a subprocess**, not an in-process mock. This is what Claude Code actually talks to.

### CF-30 · Handshake
`initialize` → `initialized` → `tools/list`.
**Pass:** valid JSON-RPC 2.0, protocol `2025-06-18`, exactly twelve tools each with a valid
JSON Schema: the five originals (`recall`, `who_is`, `what_happened`, `open_commitments`,
`today`), the substrate set (`what_changed_since`, `prior_art`, `working_set`,
`sources_for`, `verify`), `timesheet`, and `propose_memory`.

### CF-31 · Every tool answers
Call `recall`, `who_is`, `what_happened`, `open_commitments`, `today` against a seeded database.
**Pass:** each returns well-formed MCP content blocks with no error field.

### CF-32 · stdout carries only protocol
Run with a database that triggers logging and warnings.
**Pass:** every stdout line parses as JSON. Diagnostics appear on stderr. *One stray `print()` corrupts the stream and silently breaks the client. This guards it.*

### CF-33 · The server cannot write
Point it at a database and exercise every tool.
**Pass:** the file's mtime and row counts are unchanged. Opened `SQLITE_OPEN_READONLY`.

### CF-34 · Empty and missing databases are survivable
Run against a nonexistent path and an empty schema.
**Pass:** informative responses, correct exit, no crash.

### CF-35 · The substrate tools answer, and stay read-only
Call `what_changed_since`, `prior_art`, `working_set`, `sources_for`, `verify` and
`timesheet` against a seeded database.
**Pass:** each answers with real content and dated provenance; `prior_art` on new ground and
`sources_for`/`verify` with no evidence say so plainly instead of stretching; `verify` states
its epistemics ("presence in the record, not truth"); after the whole battery the database
file is byte-identical.
*These are the tools that make Memoir a substrate rather than an appendix: catch-up, history,
current context, citations, staleness. Every one of them is a reader.*

---

## Tier 4. End to end

### CF-40 · The whole loop
Capture text containing a commitment → consolidate → ask "what do I owe anyone" → get an answer naming it → query the same commitment through MCP.
**Pass:** the commitment appears in both answers, with provenance tracing back to the original capture.
*If only one test could survive, this is it.*

---

## Tier 5. PUSH: what you tell it

Until now Memoir only ever *inferred*. Everything in this tier is about data the user **authored**, which is
clean by construction and must therefore be protected from everything that guesses.

### CF-50 · Telling is distinguished from asking
Route a matched pair through the question router: "remind me **what I was working on**" and
"remind me **to send the invoice friday**".
**Pass:** the first is `.resumption`, the second is `.push`. Neither is decided by a keyword: the same
measured-margin cascade applies, and a thin margin escalates to the constrained classifier.
*The two openings are identical for three words. The first is already a passing eval case, so a push
classifier that steals it is a recall regression disguised as a feature.*

### CF-51 · Nothing is written without confirmation
Submit a push phrase and inspect the store before the user accepts.
**Pass:** zero rows written. The parse is returned for display and commits only on an explicit accept.
Cancelling writes nothing and leaves no partial state.
*A memory that invents entries when it mishears you is worse than one that does not listen.*

### CF-52 · A parse never invents a field
Push a phrase with no date ("remember the wifi password is on the fridge").
**Pass:** `dueAt` is nil, not a guess. The title is drawn from the user's own words, never paraphrased into
something they did not say. Grounding applies to parses exactly as it does to answers.

The same applies to **editing** a proposal before accepting it. Change the due time in the confirm panel.
**Pass:** the day never moves, an emptied field means `dueAt` is nil rather than midnight, a time typed
against a proposal that named no day is refused rather than given today, and text that is not a time is
refused out loud with the previous value left standing. A rejected edit that silently keeps the old value
is the same failure as an invented one, arriving a step later.
*Memoir's 17:00 for a bare day is a reasonable convention and a bad final answer, so the panel says which
hours are Memoir's and lets them be overruled. A default the user cannot tell from their own intent is how
the wrong hour ships.*

### CF-53 · Dates resolve against an injected reference
Push "remind me to call the accountant tomorrow at 10" with a fixed reference date.
**Pass:** the due date is that reference's tomorrow at 10:00 local, computed by `MemoryDateResolver`.
Never the wall clock. A day-granularity phrase ("friday") resolves to the 17:00 convention.

### CF-54 · Authored beats inferred, always
Create an authored entity, then run extraction repeatedly over text that would produce a colliding
inferred one.
**Pass:** the authored title, detail and due date survive every pass. `source` stays `authored`.
Confidence may rise; nothing else moves. An inferred entity may never merge over an authored one.
*This is CF-1 extended from correction to creation, and it is the reason PUSH is worth building at all.*

### CF-55 · Authored entities are visibly distinct
Read back a mixed list.
**Pass:** every row reports whether it was authored or inferred, and that flag survives a round trip
through the store and through consolidation.
*If a user cannot see which rows are guesses, they inherit our uncertainty without being told about it.*

### CF-56 · Completing is permanent
Mark an authored commitment done, then consolidate again.
**Pass:** it stays done. No extraction pass resurrects it.

### CF-57 · Push survives having no model
Disable every brain except `rulesOnly` and push a phrase.
**Pass:** a deterministic parse still happens or Memoir says plainly that it could not understand.
It never writes a garbled entity, and it never silently drops what you said.

## Tier 6. What you write, not only what you read

Measured on the live database: WhatsApp Web is the RICHEST surface Memoir captures, with 61 captures
averaging 8,352 characters, actual messages with names and timestamps, ahead of every other app.
Gmail averages 4,891. Capture was never the problem. What is missing is structure: the capture is
one wall of text, so "Teo : He's got the derby" is a substring rather than a message with a
sender, and "what did I write on whatsapp" falls through to the generic brief.

Most of what a person commits to, they commit to in writing, to someone. A memory that cannot
tell who said what inside a conversation is blind to exactly the half of life where obligations
are made.

### CF-60 · A chat capture is recoverable as messages
Feed real captured text from WhatsApp Web, Gmail, Telegram and Slack (fixtures lifted from the
live database's actual shapes, anonymised).
**Pass:** individual messages come back as (sender, text) pairs. Group names, weekday stamps and
the duplicated preview lines WhatsApp renders are furniture, not senders or content. A surface the
parser does not recognise degrades to the whole text with no sender, never to invented senders.

### CF-61 · "What did I write" is answerable
Ask "what did I write on whatsapp", "what did I send to Marco", "what was my last message".
**Pass:** routed to a messages shape, never to the generic brief. With the user's names configured
(CF from fin/identity), the answer contains only THEIR messages. With no names configured it says
plainly that it cannot tell who wrote what until a name is added in settings. An honest gap,
never a guess. Sender attribution in an answer must come from the parse, never from the model.

### CF-62 · Your own labelled promise survives, in a chat
Run extraction over a chat where the user's own labelled message contains a commitment
("Emanuele: I'll send the invoice Friday") alongside other people's.
**Pass:** with the name configured, the user's promise lands as a commitment; the others do not.
The junk guard that refuses third-party speaker labels (CF-14b) must not eat the user's own:
this is the identity work made load-bearing, because chat apps label EVERY message including
yours.

---

## Tier 6. The band and the timer

The notch band is Memoir's whole presence: a strip that shows one number, a timer that is a
fact, and a delivery surface for the restraint engine that has been waiting for one.
Everything in this tier is computed against an injected clock and proven without a pixel.

### CF-59 · macOS Focus silences the companion
Turn the system's Focus mode on, then ask the scanner for a nudge that would otherwise be
delivered, and turn it off again.
**Pass:** nothing is delivered while Focus is on, and the same nudge is delivered the moment
it is off. Suppression is a decision the engine makes, not a thing the caller remembers to do.

*Memoir had a pomodoro timer of its own, and the first half of this flow used to be about it:
a run ending as a `Session` row, a ledger surviving a relaunch. The timer is gone: a
productivity feature in a product about a life. The rows it wrote are still in people's
databases, and CF-65 is what keeps them out of the day's app time.*

### CF-63 · The commitment counts are computed, never guessed
Seed commitments overdue, due later today, due next week, dateless, completed and
deleted, plus a note carrying a date. Then count against an injected clock.
**Pass:** overdue and due-today count exactly the open commitments in those windows.
Completed and deleted rows never count, non-commitments never count, and completing or
reopening a row moves the counts immediately. The open list agrees with the counts and
reads in glance order: overdue, then soonest due, then dateless. (The band no longer shows
these numbers. They are still what the Todos pane, `open_commitments` and the day's brief are
built on, so they still have to be right.)

### CF-64 · Nothing reaches the user except through the engine
Drive the scanner→engine→dismissal loop with seeded commitments and session stretches.
**Pass:** a commitment coming due proposes **nothing**, ever, however imminent, and is
still counted in the memory afterwards. Memoir does not raise a commitment on its own; the
band used to widen and announce one, and that whole channel is deleted. A delivered nudge
dismissed once is silent for the full backoff and returns after it. A distraction stretch
is reported by the scanner but gated by the engine's threshold, so tightening the threshold
needs no scanner change.
## Tier 7. The ontology: what the work is about

The sessions table says "40 minutes in Chrome". This tier is everything that turns that into
"40 minutes on the Fenwick migration": labels from the user's own names, spans across apps,
and the honest outputs built on top.

### CF-70 · Work spans across apps
Seed one project worked in three apps back to back, with an ontology that knows its name and aliases.
**Pass:** one span, carrying the project's name, all three apps, the summed duration, and a capture
ID for every attributed stretch. Unlabelled time degrades to the app name with no entity claim;
idle sessions are attributed to nobody; a short gap does not split a span; the longest matching
name beats its own substring.

### CF-71 · Resumption answers are current and grouped
Ask "where did I leave off" against seeded multi-span history.
**Pass:** the answer names the *most recent* span by label, with its apps and the last thing on
screen; earlier spans appear as history, newest first. An empty window widens to the last real work
rather than answering stale; a truly empty memory says so; a question about another year declines
(CF-17b's `isGeneralBrief` applies).
*This was the weakest eval family: "answers go stale by hours; grouped questions return empty
lists". A memory that cannot answer the daily question does not get a second week.*

### CF-72 · Accounting answers the question asked
Ask the four accounting shapes against one seeded morning.
**Pass:** "time in chrome" leads with Chrome's figure, not the table; "how long have I been working"
gives the total with bounds; "summarise my day" groups time by project; "what did I ship" reports
where the time went and *says explicitly* it is not a claim about deliverables. An unknown app
degrades to the total, not to silence.

### CF-73 · Capture coverage is honest and visible
Seed a rich app, a thin app and a silent app, thirty active minutes each.
**Pass:** they grade apart (good / poor-or-partial / nothing); real use with zero text is reported,
not hidden; brief use is "unknown", not condemned; the verdict window is bounded.
*For a product whose pitch is provenance, silent partial coverage is the worst available failure.*

### CF-74 · The vault is read, never written
Import a markdown folder with frontmatter aliases, kind folders and a due date.
**Pass:** notes become authored entities with aliases, kinds and provenance pointing at real capture
rows (CF-15 holds); re-import is idempotent; an edited note is canon; `.obsidian` and `Memoir/` are
skipped; every path, size and mtime in the vault is unchanged; a missing folder throws rather than
silently importing nothing; an on-screen alias later corroborates the authored entity instead of
minting a twin.

### CF-75 · Write-back is a reviewed proposal, never a sync
Draft a daily note, then accept it.
**Pass:** drafting writes nothing anywhere; accept writes exactly one file, only inside
`<vault>/Memoir/`, containing exactly what was reviewed; the user's own notes are untouched; what Memoir
wrote is never re-imported as memory; a missing vault refuses the write.

### CF-76 · The timesheet is arithmetic with receipts
Build a timesheet over seeded multi-day work.
**Pass:** lines bucket per day and per thing, project lines carry capture evidence, unlabelled time
sits under its app with no entity claim, and the total is the sum of its parts. The rendering
states the attribution method; the weekly review covers time, what surfaced and what is owed, and
declares its figures measured, not estimated.

---

## Tier 7. Identifiers from before the rename

Memoir used to be called Pip. The migration that carried data across has been removed: it was
dead for everyone who was not the author, and after the memory moved inside the encrypted
container it became actively wrong: the plaintext path is empty by design, which the adoption
step read as "a fresh install" and answered by copying the old database back out, unencrypted,
on every launch.

What remains is not migration and must not be removed with it. `sh.pip.*` bundle ids name
**session rows already written to people's databases**, 73 of them on the database this was
measured against. `FocusSession.legacyBundleID` keeps those recognisable; the doctor's
own-bundle exclusion keeps them from being reported as an app that reads poorly. Deleting
either does not remove a reference to an old name, it silently drops a user's data out of
their day.

### CF-65 · Rows written under the old identity still count
Seed sessions under `sh.pip.focus` and `sh.pip.app`, then read the day and the coverage report.
**Pass:** the focus rows are still recognised as Memoir's own rather than counted as an app
somebody used, and neither bundle id appears in the coverage report as a poorly-read app.

## CF-65 · The rename brings the memory with it
Seed a `Memoir` folder with a real database, a config file and an answer log, then adopt it.
**Pass:** the memory opens under the new name with authorship intact, the settings and the
answer log come too, and the old folder is left exactly where it was: copied, never
moved, because this is the only copy of everything the user asked Memoir to remember.
Adoption is idempotent and refuses to run at all once Memoir has a memory of its own, so
a second launch can never overwrite newer data with older. A machine that never ran Memoir
reports nothing to do rather than an error. Focus rows recorded under the old bundle
id are still recognised as Memoir's own, because the exclusion keys on that string.
*The rename shipped without this. Nothing was lost only because nobody had launched the
renamed build yet.*

---

## Running them

```bash
Scripts/verify.sh          # build + unit + integration + MCP subprocess + bundle
Scripts/verify.sh --fast   # skip release build and bundle assembly
```

Exit non-zero on any failure. Prints a per-flow pass/fail table.

## Rules for these tests

- **Never touch the user's real database.** Every test gets a fresh temp directory, torn down after.
- **Never read the wall clock.** Time is injected. A test that fails at midnight or in another timezone is worthless.
- **No network. Ever.** A counting URLProtocol is installed globally and fails the run on any attempted request.
- **Deterministic.** No randomness, no ordering assumptions, no sleeps as synchronisation.
- **A failure names its flow.** Test names carry the CF ID so a red run says which promise broke.
- **When a test catches a real bug, fix the code, not the test.**

### CF-77 · An agent proposal is staged, never recorded
Call `propose_memory` over MCP and inspect both the database and the review queue.
**Pass:** the database is byte-identical (CF-33 holds through a write-shaped tool); the
proposal lands in `proposals.json` beside it; oversized titles and unknown kinds are
refused in prose rather than staged; only an explicit accept in the app writes the entry,
as an *authored* entity with provenance, and a reject deletes it leaving no trace.
*CF-51 is the same law for what the user says out loud. Agents propose; only the user records.*

### CF-78 · The vault is found, not hunted for
Build homes carrying a vault in each place one can live (Obsidian's own `obsidian.json`,
an Obsidian MCP server already configured for a Claude client, and the iCloud folder), and
ask what Memoir would offer.
**Pass:** every vault is found without a file dialog; the vault currently open in Obsidian
leads; the same folder named by several sources is offered once, attributed to the most
authoritative; a folder holding no notes is never offered; a vault's PARENT is never
offered beside it, so importing cannot merge several vaults into one ontology; Memoir's own
`Memoir/` write-back never counts as evidence of a vault; and a malformed config is skipped
rather than fatal.
*The most common vault on a Mac sits under `~/Library`, which the file picker hides. A
feature that needs the user to paste a path is a feature that does not work.*

### CF-79 · A promise has to be yours
Capture the same first-person sentence on a feed, in a pull request, and in a note, then
ask what is owed.
**Pass:** the one read on a feed is stored and never surfaced (absent from the todo list,
the strip's counts, `open_commitments`, `today` and the weekly review); the ones written in
a pull request or a note are surfaced normally; seeing a provisional sentence later on a
writing surface clears the doubt permanently; nothing authored, pushed or corrected is ever
demoted; and the sweep demotes rows the old extractor stored while leaving alone any with
evidence from somewhere the user writes.
*Measured on a real database: 25 commitments, 17 of them somebody else's words read off a
web page. A memory that invents obligations is worse than one that forgets.*

### CF-80 · Verify certifies only what the record actually says
Ask `verify` about a claim the record carries, several it does not, and one made of nothing
but common words.
**Pass:** the real claim is dated. Every false one is refused plainly ("not in the record"
when its distinctive words were looked for and missing, "cannot verify" when the claim has
no distinctive words to look for), and none of them is answered with dated evidence.
*The first implementation searched every word and accepted an OR match, so "the moon is made
of cheese" came back **supported by fresh evidence**: the word "the" is in every capture ever
taken. Search widens to find a half-remembered page; verification must never widen. A tool
whose whole job is catching claims that have rotted, vouching for anything at all, is the
worst failure this product can have: confident, cited and wrong.*

### CF-81 · A conversation with an assistant is never quoted as evidence
Seed a chat with a model (one in a desktop app, one in a browser tab where only the title
gives it away), then ask every tool that quotes evidence about what was said in it.
**Pass:** `recall`, `prior_art`, `sources_for` and `verify` return nothing from either.
Time and session arithmetic is unaffected, because it is computed from sessions rather than
captures: "you were in Claude for 50m" stays true and stays said.
*What you asked is not what you saw, and only the latter is evidence. A chat holds prompts
and generated replies (including replies quoting this memory's own output back at it), so
citing one is circular: the agent reads its own earlier suggestion and calls it the user's
decision. Measured on a real database: 1,029 assistant captures, 54 entities citing them,
and no filter anywhere in the server agents actually read from.*

### CF-82 · The working set spends its budget on distinct things
Leave one page as the newest thing in the record, captured five times a minute apart, with
other activity just behind it, then ask for the working set.
**Pass:** the repeated page is listed at most once, and the slots it would have taken go to
things the agent has not already been told.
*A browser left open produces a capture a minute, so the five most recent were five copies
of one tab: an agent loading context learned one thing and paid for five. Every other
section of the tool already deduplicated; the fallback was the one path that did not.*

### CF-83 · The floor never claims a model is not running
Ask the floor a question it answers by template.
**Pass:** the answer attributes itself to the record on this Mac and says nothing about what
else was or was not running.
*The floor is reached in two very different situations (no model installed, and a model that
ran and whose reply was rejected or bettered), and it cannot tell them apart. Asserting the
first told a user with a configured, available, just-attempted model that no model was
running, and they reasonably concluded the product was broken.*

### CF-84 · An answer about now says so when the record stopped hours ago
Seed a day of work whose newest capture is eighteen hours before the question, then ask what
was last done, where work left off, and what happened today.
**Pass:** every one leads with the gap and names the thing to go and check. A lookup about a
person does not, because it is not a claim about the present.
*Capture had been dead for eighteen hours after a rebuild invalidated the Accessibility grant.
The app logged "capture paused: Accessibility permission not granted" every minute, to a file
nobody reads, and went on answering confidently from the day before. It was not wrong about
the past; it was silent about the present, which is worse, because a stated gap is a thing you
can go and fix. `memoir-ask --doctor` is the same check for the whole installation.*

### CF-85 · What Memoir cannot know is decided by fact, not by similarity
Route questions about money moving, phone calls and meals, alongside the answerable
questions they most resemble.
**Pass:** every unknowable one is `outOfScope` whatever its phrasing, and the answerable
look-alikes keep their categories: "how much time did I spend in chrome" stays accounting,
"who did I talk to" stays recall, "remind me to pay the invoice" stays push.
*Found by the live probe, not by the suite. "How much **money** did I spend today" is one
word from "how much **time** did I spend in chrome today", so the embedding put it in
accounting and answered a question about money with a time report; "who did I call on the
phone" landed near "who did I talk to" and came back as a general brief. Whether a question
is answerable at all is a fact about what this product observes, so it is decided by rule
first; embeddings then decide which kind of answerable question it is.*

### CF-86 · Sources are quoted only for claims the captures actually carry
Ask `sources_for` about a claim the record carries, several it does not, and one made of
nothing but common words.
**Pass:** the real claim is quoted with its app and timestamp. Every unsupported one gets
"no evidence in the record" naming the words that were looked for, or "cannot source" when
there were none to look for. No capture is ever quoted that carries none of them. Where
only part of a claim is on record, the answer is labelled partial and says the claim as
stated is not. One page is one source however many times it was captured: repeated captures
of the same screen are collapsed, because a reader counts sources as corroboration.
*Found by using the tool, not by the suite, which only ever asked it for a claim the fixture
carried. Search widens AND to OR so a half-remembered phrase still finds its page, and with
no match at all the widened query fell through to recency: a claim about the MCP server came
back sourced to a Gmail inbox, a Chrome permission dialog and a WhatsApp advert for a villa,
each properly attributed. `verify` had already been given this floor and refused the same
claim on the same database; the two tools disagreed because only one of them had been
taught. Quoting the wrong capture is worse than quoting none: an empty answer reads as
"nothing on record", a furnished one as "here is your evidence", and the skill file tells
agents to cite this rather than assert.*
### CF-87 · A todo is not a topic, and a label is never the app said twice
Build the ontology from a project, an inferred todo and an authored todo, then render a span
of work that matched nothing.
**Pass:** no commitment becomes a label whoever wrote it; the project still does; and work
that degrades to its app name is named once rather than followed by a list containing only
that same app.
*This file already recorded the failure for threads: an email subject line became a bolded
project in a timesheet, "**lunch thursday, works for me**, 24m". The "authored still labels
regardless of kind" escape hatch brought it straight back through commitments: a stray todo
typed into the push bar became the name of an hour's work in the working set. And unlabelled
time read "Claude · 5m · Claude", which made an honest fallback look like a bug.*
### CF-88 · Recall answers with what matches, or says nothing did
Ask `recall` a question whose distinctive words are nowhere in the record, alongside one the
record genuinely carries.
**Pass:** the real question is answered. The other returns "nothing matches", naming the words
it looked for, and no row is listed that carries none of them.
*Search widens AND to OR so a half-remembered phrase still finds its page. That is right, and
it stays. What it also did was return rows sharing nothing with the question but a stopword:
"repo about screen memory" came back with an ad-tracker URL and a note about prayer apps,
because "about" is in every other sentence ever captured. This floor is deliberately much
weaker than the one `verify` and `sources_for` stand on. They demand every distinctive word,
because they answer "does the record carry this claim"; recall answers "what might this be",
so one word in common is enough to stay in. Only rows carrying none at all are dropped, and
those were never matches by any reading.*

### CF-89 · An organisation is not a person
Put a company name where a person's name is read from (a bot's display name in a mail header)
and ask who they are.
**Pass:** it is not filed as a person. Names that merely end in an ordinary word still are:
only a trailing organisation suffix behind a name disqualifies it, so Ivy Labs the person
survives and Hooli Labs the company does not.
*"Vercel Inc" was a person at 75% confidence, and `who_is` answered about it as though it were
a colleague. It arrived through the message-header pattern, which is otherwise the most
reliable person signal on the screen, so the fix belongs in the plausibility test rather than
in the pattern. Whatever else "Acme Ltd" is, it is not somebody the user can owe an answer to.
The sweep applies the same test, because a guard only ever protects what has not been written
yet: on the real database the row already existed at 99% confidence with 24 mentions behind
it, and refusing new ones did nothing about the one being answered with.*

### CF-90 · A provisional commitment stays unsurfaced over MCP too
Store one commitment marked provisional and one that is not, and ask `open_commitments`
through the real server.
**Pass:** the real one is listed and the provisional one is not.
*CF-79 stores a promise read off a page and never shows it. That law held in the app and
silently did not hold here: `provisional` was missing from the MCP's entity field list, so it
was never SELECTed, every row decoded as false, and both `!provisional` filters in
`ToolHandler` were dead code. A column absent from the query is indistinguishable from a
column that is false, which is why this survived a suite that tested the filter and a sweep
that set the flag. Found by demoting four commitments on the real database and watching the
MCP list them anyway.*

### CF-91 · Open commitments narrow to one person, by the conversation around them
Store a promise typed in a thread with somebody, and an unrelated one, then ask
`open_commitments` for that person.
**Pass:** only the promise from their thread comes back, and a person with nothing outstanding
gets a plain "none", carrying the caveat that silence is not proof.
*"What did I tell Marco" is the question people actually ask, and the whole list was the only
answer available. Scoping on the commitment's own words would answer it with nothing: "I'll
get the invoice over to you this week" names nobody, and the thread it was typed into is the
only place his name appears, so the match runs over the captures behind the row as well.*

### CF-92 · An answer leads with the answer, not with its evidence
Ask `what_happened` for a range the record covers, and read the first line.
**Pass:** the first line carries the total and where the time went. The breakdown follows it,
and what is listed afterwards is what moved in the window rather than everything it touched.
*The reply opened with a date heading and put the total on line three, under twelve app rows
and twenty-five note titles: about forty lines with the answer nowhere in them, leaving the
caller to work out what the week was about from a spreadsheet. `verify` has had the right
shape all along: a verdict first, quotes underneath. The entity list was worse than long, it
was constant: `today`, `working_set`, `what_changed_since` and `what_happened` all answered
different questions with the same fifteen note titles off an imported vault, because "touched
in this window" includes everything anything read. A list that is identical whatever you asked
is not an answer to any of it.*

### CF-93 · Every answer comes back counted
Call the tools through the real server and read `structuredContent` beside the text.
**Pass:** every tool advertises an `outputSchema`, every call returns a `structuredContent` that
validates against it and names its own tool, the counts agree with the prose, and the text block
is unchanged. A refusal reports itself as declined and an empty record as empty, rather than both
passing for an answer.
*Every tool counted its own answer and threw the number away. `recall` knew it had one capture
twenty-eight days old and `what_happened` knew it was two apps over two sessions; both flattened
it into a sentence and returned a `String`, so a client wanting to draw
`memoir:recall ✓ 1 capture · 28 days ago` could only get there by parsing the markdown back out.
That makes a chip hostage to the wording of an answer, and the wording moves: CF-92 reshaped
four of these tools in one pass. The declared protocol was the other half of it: `outputSchema`
and `structuredContent` arrived in 2025-06-18 while the server was still announcing 2024-11-05,
so a client obeying the handshake would have been right to ignore both. Four statuses rather
than a tick, because a scope refusal, an empty record and an unreadable database all come back
as `isError: false` with prose in the block, and a chip that only knows "it returned text" ticks
all three.*

### CF-94 · The handshake answers in the version the client asked for
Open `initialize` three times: with the revision this server prefers, with the older one it
also speaks, and with one it does not know.
**Pass:** the first two come back as they were asked, and both clients get their answers. The
unknown one is answered with this server's own revision, per the spec.
*`structuredContent` needs 2025-06-18, so CF-93 raised the version the server names, and
named it unconditionally. A client that opens with 2024-11-05 was then answered with a
protocol it never offered, which it is entitled to hang up on: the whole connection lost to
gain a field that client was always going to ignore. Structured content is additive and the
markdown is never not there, so an older client should lose the chip and keep every answer.
Found by handshaking as an old client against the new server, not by the suite, which only
ever spoke the newest revision.*

### CF-95 · The answer names the work, not the window it happened in
Record an hour in an editor on a named project, then ask `what_happened` about that window.
**Pass:** the answer names the project. Time nothing is known about still degrades to its app
name, is marked as unlabelled, and is never counted as a project.
*"You spent 1h 25m in Claude" is a measurement, not an answer: the app is the one thing the
user already knows. What they cannot reconstruct is what the hour was FOR. The machinery
existed and this tool was not using it: the timesheet has attributed time to projects through
the ontology since CF-76, while `what_happened` and `today` aggregated raw session app names
and so could never say more than the app. The honest fallback is the timesheet's and is kept
exactly: unlabelled time is listed under the app it was spent in, never guessed into a
project, which is the reason its totals can be trusted at all.*

### CF-96 · An application's own name is never a person
Capture a screen whose window title carries the application's name, repeatedly, and read back
the people.
**Pass:** the application is not among them.
*"Google Chrome" was a person at 55% confidence, and it reached the daily brief. The
repetition path reads a repeated capitalised phrase as evidence of a name, and an app's name
is the one string that appears beside everything the user has ever looked at: the strongest
possible signal by repetition and the weakest possible evidence of a person. "Quote Machina
Verified" and "Clearer Responses Trending" arrived the same way off a social timeline, whose
furniture repeats on every post. Answered from the capture rather than a list of app names,
because Memoir already knows what it was looking at and a list goes stale the day the user
installs something.*

### CF-97 · A name the timeline promoted is not somebody the user knows
Scroll a feed carrying a name repeatedly, hold a conversation with somebody on the same site,
and read back the people. Then sweep a database that already holds a feed-only person.
**Pass:** the feed name is neither stored nor kept; the person from the conversation is both.
*A feed is the one surface where repetition means the opposite of what it usually means. A
colleague mentioned twelve times is somebody you work with; a name mentioned twelve times on a
timeline is a name the timeline is promoting. "Jorge Martín" was a person at 99% confidence
with twelve mentions, every one of them X's trending sidebar, and 120 of the 267 people in the
record were handles scrolled past. Direct messages on the same sites are excluded, because
there the user is the other participant. CF-91's invoice promise was typed into exactly such
a thread. The sweep applies the same test, for the third time on the same lesson: a guard only
ever protects what has not been written yet.*

### CF-98 · Time nothing can name still says what was on the screen
Spend an hour in an app on a subject the ontology has never heard of, then ask what happened.
**Pass:** the row still reads as unlabelled, and it names the screen the time was spent on,
with the unread badge and the trailing application name stripped off.
*"Claude: 1h 25m" is the one fact the user already had. The screen usually says what the hour
was for; it just says it with the app stapled to the end by the window manager and an unread
count on the front, and the count changes on every capture so one page looks like six.
Deliberately a caption and not a re-attribution: `WorkSpanBuilder` drops spans under a minute,
so splitting an app's hour across nine window titles would delete the short ones and shrink
the timesheet's totals. CF-76 is arithmetic with receipts, and this must not touch the
arithmetic. Note the limit: captures from an assistant surface are excluded as evidence by
CF-81, so time in one stays uncaptioned.*

### CF-99 · A caption never out-measures the row it captions
Ask what happened for a window where one app carries several subjects, and compare the
durations beside the subjects with the row's own total.
**Pass:** the subjects are a split of the measured time, not an addition to it.
*The first cut derived subject time from capture spacing and printed it next to a total derived
from session records. They do not agree, and not for the reason first written here: capture
only ever runs on the frontmost app, so the gap between two of an app's captures is not time
spent in it: it is every stretch spent somewhere else, in between. Billing that gap to the
earlier capture invents time, and the 10-minute cap bounds the invention without removing it.
A row measured at 11m listed subjects summing to 57m. Printed side by side the smaller number
reads as the wrong one, and CF-76's whole claim is that these totals are arithmetic with
receipts. The weights still come from the screen; they are scaled onto the measured total
rather than published as rival measurements.*
### CF-103 · First run is a sequence, and it ends with the user set up
Walk the flow end to end against a throwaway support directory: from the welcome, through the
permission, the identity step and the agents, to the last screen. Walk it backwards. Skip it.
Read the forward button's label on a permission that was never granted and on an identity step
with no names in it.
**Pass:** it starts at the welcome and ends by finishing exactly once, and nothing in the
middle counts as completion. Back stops at the start. The forward button says "Continue
without it" over an ungranted permission and "Skip this" over an empty identity step, and is
unemphasised in both: it only becomes the white pill when pressing it costs the user nothing.
Skip lands on the last step rather than closing the flow.
*Onboarding was one static screen for a reason that had nothing to do with design: the window
was shown whenever Accessibility was missing and torn down by a two-second poll the instant it
arrived, so no step could survive its own first step. `IdentityStep` saving on every keystroke
was a workaround for a window that closed itself mid-sentence. Sequencing it meant separating
"is the permission granted" from "has the user finished", which is what `hasCompletedOnboarding`
is for, decoded as `true` when the key is absent, so an upgrade does not march existing users
back through a welcome. The first run of this suite failed on the empty-identity case because
`IdentityStep` loads the real config to pre-fill the name field, and the machine running it had
a name saved: hence the support-directory override around the initialiser rather than only
around the assertions.*

### CF-102 · A capture is not made richer by walking the same screen twice
Walk an application whose window contains web areas, and compare the distinct text collected
with the total.
**Pass:** the walk reaches the whole window, and no string is collected more than once.
**Pass:** a document-shaped web area outranks a one-child text box when roots are chosen.
*Two changes met here and only one survived. Choosing the first web area breadth-first, and
skipping the window entirely once one was found, left the Claude desktop app returning six
nodes and 26 characters of composer placeholder: the whole screen invisible on an unlucky
pick. Ordering web areas by subtree size and appending the window as a final root fixed it:
1,485 nodes, depth 36.
The other change raised the dedupe gate to two sightings, so an assistant's open conversation
(named in the sidebar and again as the heading) could be told from the forty merely listed.
Measured on the real screen afterwards, it distinguished nothing: the window root re-walks
what the web areas already returned, so "twice" means walked twice, not listed and open. It
cost 27% of a capture already truncated at the ceiling, which is real content pushed out to
store a second copy of a menu. It was reverted. The heading remains unidentified.*

### CF-101 · A one-time code is redacted; the screen it appeared on is not
Feed the guard a screen that is only a verification code, a working screen that merely
discusses code near numbers, and an ordinary screen that mentions neither.
**Pass:** the first is dropped, the second keeps its text and loses every code-shaped number,
the third is untouched.
*The rule is unchanged and absolute: a code never reaches the database. Enforcing it by
discarding the whole capture was the disproportionate part, and it stayed invisible while the
walk returned almost nothing. The moment CF-100's root fix made captures rich, every one of
them died: on a developer's machine "code" sits within twenty characters of a four-digit
number more or less permanently, so 20,366 characters of work were thrown away because the
text said "code" near "1485". Redaction is blunt on purpose: once a screen has mentioned a
code, every 4–8 digit run on it is suspect, and the cost of over-redacting is a lost figure
while the cost of under-redacting is a stored credential.*

### CF-111 · An application that leaves its title bar empty is still asked what it is showing
Capture an application whose window title is only its own name, with a document open.
**Pass:** the capture's window title names the open document, and anything the user named
beside it, in Claude's case the project. An application that fills its title bar properly is
untouched.
*The Claude desktop app reports the window title "Claude" and never the conversation, so an
hour of work could be measured and never named. Reading it out of the collected text was
hopeless: the walk flattens the tree, and the heading becomes one more string among forty
sidebar rows listing every other conversation. Three attempts failed that way before the tree
was dumped and the structure looked at: a sidebar is `AXLandmarkComplementary`, content is
`AXLandmarkMain`, both web standards rather than anything specific to one app.
The first cut then took the first named control inside the main landmark and read back "Bypass
permissions (Opus 5)": the composer's mode and model pickers, reached first because tree order
is not screen order. A document's name sits at the top of its pane and the controls for typing
sit at the bottom, which geometry knows and the tree's shape does not. Topmost wins, and no
denylist has to keep up with whatever the next button is called.
Delivered as the window title rather than a new column, so every reader (captions, work
naming, the on-screen list) gets it with no migration.*

### CF-104 · The envelope carries the answer, not just its measurements
Call any tool through the real server on a client that honours `outputSchema`, and read what
the caller actually receives.
**Pass:** `structuredContent` contains the whole markdown answer in `text`, byte-identical to
the content block. An envelope that reports how much was found while containing none of it
fails, however well its counts validate.
*CF-93 gave every answer a count and CF-94 concluded that "structured content is additive and
the markdown is never not there". True of the wire and false of the reader: a client that
supports the field renders it INSTEAD of the text block, so the markdown left the server every
time and reached nobody. `recall` answered `15 captures · 3 entities` carrying neither, and an
agent reading that reports in Memoir's name that the record is empty when it is full, which is
the one failure this product cannot have, because the user cannot see the rows to know better.
The suite asserted both halves left the server and never that the half a client reads had
anything in it, so it passed throughout.*

### CF-105 · A filtered read fetches more than it returns
Hold a long conversation about a topic with an assistant, then recall that topic.
**Pass:** the genuine captures come back. Assistant chatter is dropped without consuming the
result budget, and no read binds `limit` to SQL when rows are discarded in Swift afterwards.
*`searchCaptures` asked SQL for the newest `limit` matching rows and then dropped assistant
conversations from them, so the answer was however many survived: a number nobody chose. The
discarded rows are the newest by construction: asking Claude about WhatsApp writes captures
saying "WhatsApp", and those outrank every real one on `ts DESC`. Ten rows fetched, ten
discarded, 322 genuine WhatsApp captures below the cut, and the tool reported "nothing matched",
so discussing a topic with an assistant is precisely what evicted it from memory, and asking
twice made the second answer worse than the first. `recentCaptures` and the `captures(from:to:)`
fast path had it too; the slow fallback beside them was already correct, so the optimised path
was the bug and the unoptimised one the specification.*

### CF-106 · The assistant filter reads the tab, not the word
Hold a conversation in an assistant's web app, and separately read a page *about* that
assistant. Recall a topic both mention.
**Pass:** the conversation is not quoted as evidence, and the page the user was reading still
is. A title naming the product inside a sentence is reading; a title whose whole segment is the
product is the product.
*CF-81 caught assistants by domain, and the Claude web app names no domain in its tab: the
title is `Test question - Claude – Part of group ✅Memoir demo video with Remotion`. So six of
ten rows of a real `recall` for "WhatsApp" came back as Claude explaining it could not read the
user's WhatsApp: Memoir quoting an assistant's disclaimer as evidence about the thing the
disclaimer denied seeing. The obvious repair is the dangerous one. `contains("claude")` would
have dropped 87 browser captures on the database this was found on, and 60 of them were the
user genuinely reading: `mirafenn on X: "…feels like Claude skills wrapped"`, `claude demo -
Search / X`, `How to Run a Gauntlet Loop … Behind Claude of Duty`. Silence about what someone
read is a worse failure than chatter, because nothing marks the gap. Splitting on the
separators browsers actually use and requiring an exact segment drops 30 and keeps all 60:
"Claude of Duty" is a segment, "Claude" is not. Gemini is left to the domain check: it is a
crypto exchange and a star sign before it is an assistant.*

### CF-107 · The notch says whether it is recording, and says so when it stops
Revoke Accessibility while Memoir is running. Wait fifteen seconds.
**Pass:** the mark's violet half turns red and breathes, the strip reads *Not logging*, and the
band widens once to say Memoir has lost the permission, and says it again every half hour for
as long as it is true. Re-grant it, and the band says it is recording again.
*The failure this exists to stop has the longest fuse in the product: the app looks identical
whether capture is landing or dead, so the first symptom is an answer about the wrong week, a
fortnight later. `CaptureLoop` swallows every failure by design (losing capture because one
read failed would be worse than any bug it could report), and `hasAccessibility` was read once
at launch and never again, so a permission revoked at 10am left the app believing it still had
it until the next relaunch. Health is therefore measured, not assumed: captures actually
landing while the user is demonstrably at the machine. See `CaptureHealthJudge`.*

### CF-108 · An app that publishes nothing is not the same as a memory that has stopped
Work for an hour in an app with no accessibility tree: a game, a canvas app.
**Pass:** the notch stays healthy. Settings still grades that app honestly under coverage.
*The alarm has one job and it can fail in two directions. A stall is only declared after four
minutes of active work across **two different** apps with nothing written: a broken pipeline
fails everywhere at once, while an opaque app fails in one place and is already reported by
`AppCaptureQuality` (CF-73). Time at an idle Mac and time in an excluded app never count
against capture at all: the second is Memoir working exactly as designed. An indicator that
cries wolf is worse than no indicator, because it teaches people to ignore the one thing that
would have told them.*

### CF-109 · A restart does not end the recording
Restart the Mac without touching Memoir.
**Pass:** Memoir is running and recording when the desktop appears. Nothing was clicked.
*There was no login item at all, so every restart (a system update at 3am, a flat battery, a
crash) stopped capture until somebody happened to notice, and nothing said so. Registered
through `SMAppService` rather than a `LaunchAgents` plist for one reason above the others: it
can report `requiresApproval`, so a Mac that will *not* relaunch Memoir says so in Settings
instead of looking fine. On by default, including on upgrade.*

### CF-110 · A pause comes back by itself
Pause capture. Do nothing.
**Pass:** capture resumes on its own when the time is up, and the notch says how long is left
the whole way: *Paused · 42m*. Pause for fifteen minutes and restart the Mac: capture is
running when the desktop appears.
*The switch had no expiry, which made it the same failure as a revoked permission wearing a
friendlier hat: somebody turns it off to read something private, gets on with their day, and
the memory stops for a fortnight with the switch doing exactly what it was told. Pausing is now
a question of how long, defaulting to an hour, and the open-ended option has to be picked on
purpose. The expiry is **evaluated, never scheduled**: a timer would not survive the app being
quit, and a pause that outlives a reboot is the version of this that would have been hardest to
notice. `applyConfig` therefore asks the clock rather than the stored boolean: an hour-old
config is still "paused" as a flag long after it has stopped being true.*

