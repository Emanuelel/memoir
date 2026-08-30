# What Memoir does with your data

Plain language, no marketing. If anything here is wrong, the code is wrong and it should be fixed.

## The short version

Memoir reads on-screen text and writes it to one file on your Mac. Nothing is sent anywhere unless you explicitly turn on a cloud brain, and even then only the question you asked plus a small packet of your own context, never the whole database.

There is no account, no sign-in, no analytics, no telemetry, no crash reporting.

The app can make **three** kinds of outbound network request, all off by default, and each needs its own switch:

| Request | Goes to | Switch | Default |
|---|---|---|---|
| Anthropic API | `api.anthropic.com` | Allow cloud brains | off |
| A model on your own network | a host **you** type in | Allow a model on my network | off |
| What the weather was | `api.open-meteo.com` | Let the journal look up the weather | off |

There is also a fourth way out that is not a network request from Memoir: the **Claude Code** brain, which hands your question to the `claude` binary already on your Mac. It is covered by the cloud switch.

The first two fire only when you ask a question, having first turned the relevant switch on. The weather is the odd one and worth reading the detail on: it fires when you open the journal, not when you ask something, and it is the only request that says anything about *where* you are. It carries a date and a coordinate rounded to about 11 km: no identifier, no account, no key, nothing that says which machine is asking. Your location is fetched from macOS at reduced accuracy, used for that one request, and stored nowhere: not in the database, not in the config file, not in the log. With the switch off, no location is requested at all and nothing is sent. It is off by default for exactly that reason, and the journal says so where the weather would have been rather than hiding the switch in Settings.

**There is exactly one thing that goes out without you asking, and it is the update check.** It is a plain `GET` for a small static file that says what the current version is. No query string, no headers identifying you, no version of yours, no machine id; there is no account for it to name. The comparison happens on this Mac, against the version already in the binary, which is why the request can carry nothing about the person making it. Somebody logging it sees an IP asking for a file, exactly as if you had loaded a web page. It runs at launch and once a day, it can be switched off in **Settings → Updates**, and nothing installs itself: when there is a newer version Memoir says so once and you decide.

That is a real distinction and it is worth being precise about rather than hiding: **telemetry reports on you; this asks a question.** There is a test that fails if a query string, a body, or an identifying header is ever added to it, and it is counted at the send site by the same counter as everything else, so it appears in Settings → Data like any other request. Turn it off in Settings and Memoir will never contact anything on its own again; you will find new versions the same way you found this one.

## What is read

**Through the macOS accessibility system:** the text your apps publish for screen readers. Practically, that's the content of the window you're focused on.

**Without any permission:** which app is frontmost, and how long since you touched the keyboard or mouse.

**With Screen Recording permission, if you grant it:** window titles. Optional. Without it Memoir records the app name only.

**With Microphone and Speech Recognition permission, if you grant them:** your voice, and only while the ask bar is open and the mic indicator is red. See "Dictation" below.

**If you point Memoir at a notes folder (Settings → Vault):** the markdown files in that folder, read locally: at launch, hourly, and whenever you press Import. Titles and aliases become entries in the memory, marked as yours. The folder is never uploaded and never modified, with one exception you control, below.

**With Contacts permission, if you grant it:** the names on your cards, plus nicknames and company. Not phone numbers, not email addresses, not postal addresses, not birthdays, not contact photos. Nothing is ever written back to your address book.

**With Calendar permission, if you grant it:** each event's title, location, and attendee names, going back up to ten years. Not event notes or URLs: a calendar note is often a dial-in code or a password. Every calendar the Mac's Calendar app knows about is included, so Google and Exchange accounts come through if you have set them up there. Memoir never adds, changes or deletes an event.

**With Photos permission, if you grant it:** two fields per image: the date it was taken and its coordinate, if it has one. Nearby coordinates are grouped onto a roughly 150-metre grid; somewhere that appears on three or more separate days becomes a place in your memory, named with its coordinates until you rename it. Screenshots are skipped. Coordinates are never sent anywhere to be turned into a place name, which is why the names start as numbers.

**With Location permission, if you grant it, and only with the weather switch on:** an approximate location (`kCLLocationAccuracyReduced`, so macOS hands over a district rather than an address), used for one thing and one thing only, which is asking what the weather was. It is rounded further before it leaves and stored nowhere: not in the memory, not in the config file, not in the log. Memoir already knows the places you go, from your own photographs and calendar, and does not keep a second record of where this Mac happens to be. With the weather switch off it never asks.

The contacts, calendar and photo sources are read when you press the button, then re-read hourly so that a contact you add next month, an event next week, and yesterday's photographs are all known. Only sources you have already granted are re-read; the hourly pass never raises a permission prompt on its own.

## The vault

The vault integration is read-only by design. Memoir never edits, moves, renames or deletes your notes. It skips `.obsidian`, `.trash`, `.git` and its own `Memoir/` folder entirely.

The single write path: you can ask Memoir to **draft a daily note**, read the draft, and explicitly accept it. Only then is a file written, always inside a `Memoir/` subfolder of your vault, never anywhere else, containing exactly the text you reviewed. Memoir never reads that folder back, so nothing it writes can become its own memory.

## Agent proposals

An AI agent connected over MCP can *suggest* that something be remembered (`propose_memory`). Suggestions go to `proposals.json` next to the database, **not into the memory**. The database is opened read-only by the MCP server and stays that way; there is a test that fails if any tool changes so much as its modification time. You see pending proposals in Settings → Data. Accept writes the entry, marked as yours. Reject deletes it. There is no third path.

## Dictation

The ask bar can type for you. Press ⌥Space, say your question, press Return.

- The microphone opens **only** while the ask bar is on screen and listening. Escape, Return, clicking the mic button, or the bar closing all shut it immediately.
- Audio is transcribed by Apple's **on-device** speech models. On macOS 26 that is `SpeechAnalyzer`/`SpeechTranscriber`; on macOS 15 it is `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. If a language cannot be recognised locally, Memoir reports voice as unavailable rather than falling back to Apple's servers.
- **No audio is recorded, buffered to disk, or uploaded.** Buffers go from the microphone into the transcriber and are discarded. Nothing about voice is written to `memoir.sqlite` or the log.
- The one thing that touches the network is Apple's own model download, the first time you use a language. That is a download; nothing of yours is uploaded with it. You can trigger it yourself in Settings → Voice and watch it.
- Turn the whole thing off with Settings → Voice → "Start listening when the ask bar opens", or simply never grant the permissions.

## What is never read

- Screenshots. There is no screen-capture code in this project.
- Video. There is no camera code in this project.
- **The pictures in your photo library, except the ones the journal shows you.** What goes *into* the memory is still metadata alone: `PhotoImporter` reads each image's date and coordinate, does not call `PHImageManager` at all, and no picture reaches the database, the vault or the log. The one exception is on screen in front of you. Today's photographs appear as thumbnails above the journal composer, so the page is never blank, and drawing them means asking macOS for the images. That happens in `PhotoFrames`, for one day, only while the pane you opened is showing, capped at four. Nothing decoded is stored, nothing is written back, nothing is sent: there is no `URLSession` in that file, iCloud downloads are switched off, and a picture is never part of a packet shown to a model. `PHImageManager` is *called* in exactly one file in this repository, `Sources/MemoirKit/Memory/PhotoFrames.swift`, and that file is the whole of the exception. macOS has no permission level for metadata alone (the only alternative to read access is write-only access), so the system dialog still asks for more than Memoir takes.
- Faces. Photos' People album has no public API, so who is in a picture is not something Memoir can read even if it wanted to. People come from your contacts and from calendar attendees.
- Audio, except while you are dictating into the ask bar with the mic indicator lit, and even then it is transcribed locally and never stored.
- Keystrokes. The hotkey monitor is listen-only and cannot synthesize or record input.
- Anything from an excluded app. Password managers, Keychain Access, and the system's own credential prompts (the "enter your keychain password" sheet, the login window, notification alerts) ship excluded by default; you can add more in Settings.
- Anything at all while capture is paused.

## Where it is written

```
~/Library/Application Support/Memoir/
  memoir.sqlite               captures, entities, provenance, sessions
  memoir.sqlite-wal / -shm    SQLite's write-ahead log, same contents, folded in as it goes
  memoir.sqlite.v{N}.backup   a snapshot taken before each schema upgrade, in case one fails
  config.json                 your settings, never the API key
  proposals.json              agent suggestions awaiting your accept, not memory
  logs/memoir.log             diagnostics: which app was frontmost, when, and how much was read
  logs/asks.jsonl             your questions, the answers, and the context each was given
```

That is the whole list. `asks.jsonl` is the one worth knowing about: it exists so a bad answer can be diagnosed, and to do that it records the context packet the brain was shown, which contains capture text. It never leaves the machine, it is capped at 4 MB, and it goes when you delete everything.

**All of it lives inside an encrypted container.** `memoir.sparsebundle` is an AES-256 volume that macOS itself encrypts, mounted at `Memoir/vault` while the app is running and closed when it quits. The paths above are what you see inside it. SQLite is untouched by this (it is the volume that is encrypted, not the database format), so search, the index and everything else behave exactly as they always did.


## Encryption, and exactly what it is worth

**The key.** 256 random bits in your login keychain, under `sh.memoir.vault`. macOS unlocks it when you log in, so there is no password to type to look at your own life. It is marked device-local, so it never syncs to iCloud Keychain: a key that syncs is a key that leaves the machine.

**The recovery key.** Shown once, during setup, and never again. It is the same key rendered as fourteen groups you can write on paper, with a checksum so a mistyped one is refused immediately rather than failing later as a memory that will not open. Auto-unlock is held by the keychain, and a keychain does not survive a wiped disk. **If both this Mac and that key are gone, nobody can open the memory, including whoever wrote Memoir. There is no account, no server, and no reset.**

**What it defends.** A stolen laptop. A copied database. A leaked backup. A disk pulled out of a dead Mac.

**What it does not defend.** Anything running as you while you are logged in. At that moment the volume is mounted, because you are using it. The MCP server reaches the key through the keychain the same way the app does. Encryption protects the *file*, not the *session*, and any claim beyond that would be the mistake Recall made.

### If your memory predates encryption

A database created before this existed is copied into the container at the next launch, verified by opening it, and only then removed from its old location.

**Deleting that original does not scrub it.** On an APFS SSD the old blocks survive until the drive reuses them, and no application can overwrite them to order: that is the storage layer's decision, not ours. So a memory that began life unencrypted is *encrypted from now on*, and is not the same as a memory that was encrypted from its first byte. This is why the move happens automatically at launch instead of being offered as a setting you might switch on in a year. If it matters to you, delete everything and let it fill again from an encrypted start.

### If the vault will not open

Memoir starts anyway, on the old unencrypted path, and **says so**: in the log, and out loud in the band. A memory tool that refuses to start is worse than one that opens and tells you the truth about its own state. What it will never do is carry on quietly and let you believe you are protected.

Your Anthropic API key, if you set one, is in the **macOS Keychain** under service `sh.memoir.brain`. It is never written to the database, the config file, or the log. There is a test that fails if it ever appears in serialised config.

## What is kept, and for how long

Three tiers:

- **Raw captures are kept, by default, for as long as you want them.** There is no expiry unless you set one. You can choose a window in Settings, and anything past it is deleted for good; leave it alone and nothing is ever thrown away. The sweep runs at launch rather than only after a full day of uptime.
- **Imported history is never swept by time.** Contacts, calendar events, photo days and vault notes are dated by when the thing happened, not by when Memoir read it, so a ninety-day window would delete the decade the import exists to provide, the first time you set one. It would also protect nothing: the contact is still in Contacts, the event still in your calendar, the photograph still in your library. Deleting these deliberately still works: the Memories browser, excluding an app, and "delete everything" all reach them.
- **What Memoir has learned** (people, projects, commitments) is kept until you delete it. So are the short quoted snippets held as evidence for each thing learned (up to 240 characters each), and the session records of which app you used and for how long. Those are what let Memoir show you *where* a belief came from after the capture behind it has rolled off, so they deliberately outlive it.

Captures are not cheap. Fully indexed, one costs about 10.7 KB (roughly half of it text and half search index), so Settings shows what your retention setting projects to on disk, measured from your own rate rather than guessed. Measured 22 August 2026 on a real database: 12,490 captures, 131.5 MB.

"Delete everything" in Settings → Data removes captures, entities, provenance, sessions, both search indexes, the pending proposals, the pre-upgrade snapshots, `asks.jsonl` and `memoir.log`, then vacuums the file. That is a real hard delete, not a flag. If it cannot finish, it now says so instead of reporting success.

## What leaves your Mac

**With the default settings: nothing is uploaded.** `allowCloud` and `allowLocalNetwork` are both off. While a switch is off, the brain router will not select the brain behind it even if you explicitly prefer it: it falls back to a local brain instead. That behaviour is tested, and the guard is at a single point (`BrainRouter.isAllowed`) that selection, availability and construction all go through.

**If you enable cloud and pick the Anthropic brain:** your question and a context packet go to `api.anthropic.com`. The packet is assembled by `MemoryService.context` and is capped by a token budget: typically some pinned entities, open commitments, entities matching your question, and a few recent capture snippets. Not your history, not your database.

**If you enable cloud and pick Claude Code:** the same packet is passed to the local `claude` binary, which sends it to Anthropic under your own account.

**If you enable a model on your own network:** the same packet is POSTed to the host you typed in: an LM Studio, Ollama or vLLM box on your LAN or Tailnet. No third party, no account, no retention policy but yours. It is still a packet leaving this Mac, usually over plain HTTP, which is why it has a switch of its own rather than riding on "cloud", and why it is counted like any other request.

**One thing no setting here governs: your own backups.** `~/Library/Application Support/Memoir/` is an ordinary folder, so Time Machine, Backblaze, or anything else you have pointed at your home directory will copy the database like any other file, including to a network drive. Memoir does not exclude itself, because silently removing your memory from your own backups is not a decision it should make for you. If you would rather it were not backed up, exclude the folder in your backup tool.

**If you connect an agent over MCP:** whatever that agent asks for goes wherever that agent runs. This is the one route out of the machine that the app's own settings do not govern, so it is worth being exact about.

`memoir-mcp` itself sends nothing. It has no `URLSession` in it, no model, and no network code of any kind: its entire import list is `Foundation`, `MemoirKit` and `SQLite3`. It reads the database and writes markdown to standard output. But it is a *server*, and the client on the other end is the thing that travels: connect it to a cloud assistant and every row you ask for is transmitted to that assistant, under that assistant's terms and not Memoir's. Connect it to something running locally and nothing leaves. Memoir cannot tell the difference and does not try to.

Two consequences follow, and neither is a defect:

- **The brain switches do not apply here.** They govern the app's brain router. An MCP client is a separate program you started and pointed at your own data; the settings were never in that path, and the outbound counter in Settings → Data does not count MCP reads because no request leaves through Memoir's code.
- **The refusals still hold.** Credentials, private browsing, incoming calls and messages, predictions about the future, and questions about your life away from the screen are declined by the server before any SQL runs (`ScopeGuard`), so they are refused on this route exactly as they are in the app. Captures of assistant conversations and of Memoir's own window are filtered out of every result, so the memory never feeds an agent its own reflection back as evidence.

The database stays read-only throughout. `propose_memory` writes a suggestion to `proposals.json` for you to accept or reject; there is a test that fails if any tool changes the database file's modification time.

Settings → Data shows a live counter of requests that have actually left the machine this session. It reads zero on a local-only setup.

It is incremented by the code that makes the request, on the line before it sends, so a request that is made and then *fails* still counts, because it still left. For a while this was not true: the counter lived in the app layer and was incremented after an answer came back, based on which brain had answered, which meant it was really counting answers and missed anything that went out by another path. It now lives in `MemoirKit.OutboundMonitor`, the four send sites are its only callers, and the panel in Settings is a read-only view of it.

## What Memoir never does

- Send anything on launch, on a timer, or in the background
- Report usage, feature opens, install IDs, versions, or crashes
- Send your first question, or any question, anywhere unless you turned a switch on
- Sync anything between machines
- Ask you to create an account

That third one is worth naming explicitly: some products in this category quietly transmit the first question of every conversation for training data while advertising themselves as local. Memoir does not, and the outbound counter is there so you don't have to take that on faith.

## The threat model

Being straight about this matters more than sounding safe, so: **Memoir's security model is macOS's.**

What it does defend against:

- **An MCP client, malicious or compromised.** The server opens the database read-only three separate ways and has no statement that can write. `propose_memory` stages text into a review file, bounded and never rendered as markup, and only your accept turns it into memory.
- **Accidental egress.** Every network path is behind a switch that is off by default, enforced at one point in the router, and counted at the send site.
- **Reading things it should not.** Excluded apps are checked before any text is read, not filtered afterwards, and secure text fields are never read or descended into.
- **Its own guesses overwriting you.** Nothing inferred can overwrite something you wrote or corrected.

What it does **not** defend against, and cannot:

| | Stopped? |
|---|---|
| Malware already running as you | **No.** It can read the database, exactly as it can read your Mail and your browser history. |
| Another account on the same Mac | **No.** Ordinary file permissions apply. |
| Someone at your unlocked Mac | **No.** There is no separate password on Memoir. |
| A stolen Mac, FileVault **on** | **Yes**, by FileVault and by Memoir's own container. |
| A stolen Mac, FileVault **off** | **Yes**, by the container: the memory is AES-256 and the key is in your keychain. Turn FileVault on anyway, for everything else on the disk. |
| Your backup software copying the file | **Yes.** A copied `memoir.sparsebundle` is ciphertext without your key. |
| A memory that existed before encryption | **Partly.** It is encrypted from the migration onwards; the blocks its plaintext occupied survive until the SSD reuses them. See "If your memory predates encryption". |

The pattern in the "no" rows is worth naming: **encryption protects the file, not the session.** While you are logged in and using Memoir the volume is mounted, so anything running as you can read it, exactly as it can read your Mail. What changed with encryption is every row where the disk leaves your possession. What has not changed is that Memoir adds no new way for that file to travel, and the section above is how you check.

## Verifying it yourself

- The whole codebase is on your disk. `URLSession` appears in exactly **four** files: one per row of the table above (`Sources/MemoirKit/Brain/AnthropicBrain.swift`, `Sources/MemoirKit/Brain/LocalNetworkBrain.swift` and `Sources/MemoirKit/Memory/Weather.swift`), plus `Sources/MemoirKit/Setup/UpdateCheck.swift`, the update check described at the top of this document.
  ```bash
  grep -rln "URLSession\|dataTask" Sources/
  ```
  There is a check in `Scripts/verify.sh` that fails the build if a fifth one appears, and every entry is argued for by name in that file rather than waved through. Two are allowed on conditions the same stage enforces: the update check fails it if it ever grows a body, a query string or a header of its own, and either fails it by ceasing to be counted at the send site.
- Every request is counted at the line that sends it. Those same four files, plus the Claude Code
  subprocess, are the only callers of `OutboundMonitor.record`, and that is the number Settings
  draws:
  ```bash
  grep -rn "OutboundMonitor.shared.record" Sources/
  ```
- Watch it with Little Snitch or `lsof -i` and confirm silence on a local-only setup.
- `swift test` runs the assertions about cloud never being selected and the key never being serialised.

## Getting your data out

**Settings → Data → Take it with you**, or from a terminal:

```bash
memoir-ask --export ~/Desktop/memoir-export.json    # everything
memoir-ask --export ~/Desktop/memoir-memory.md      # the reading copy
```

Two formats, because they answer different questions:

- **JSON** is the archive: every entity, every quoted piece of evidence behind it, every capture, every session. Nothing is filtered: entities you deleted come out too, carrying `"deleted": true`, because an export that silently drops rows is not an export. It is a plain object with a `format` and `formatVersion` at the top, ISO-8601 dates, and flat lists you join on `entityID` and `captureID`. Any program can read it; no knowledge of Memoir's schema is required. Measured on a real 42 MB database: 13.8 MB of JSON in about a second.
- **Markdown** is the reading copy: what Memoir believes, grouped by kind, each belief marked *yours* or *inferred* and followed by the words it was drawn from. It drops straight into Obsidian or any notes app. Same database: 341 KB.

Exporting is a read and changes nothing, which there is a test for.

You can also simply copy the database itself. Inside the mounted volume `memoir.sqlite` is an ordinary SQLite file: no proprietary format, no custom encoding, and `sqlite3` will open it. The encryption is the container around it and not the file format, which is the whole point: at rest it is ciphertext to anyone without your key, and in your hands it is a file any program can read. Nothing of yours is locked inside anything of ours.

Leaving should cost you nothing. Export first, then delete below if you want to.

## Deleting everything

1. Settings → Data → **Delete everything**, or
2. Quit Memoir and `rm -rf ~/Library/Application\ Support/Memoir`
3. If you set an API key: Keychain Access → search `sh.memoir.brain` → delete
4. System Settings → Privacy & Security → Accessibility → remove Memoir
5. If you used dictation: System Settings → Privacy & Security → **Microphone** and **Speech Recognition** → remove Memoir
