# Memoir over MCP: the long version

`README.md` has the one command that works. This is everything else: the per-client config
files, the two traps that cost an afternoon each, the skill, and the one-click bundle.

## MCP: let your own agent read your memory

`memoir-mcp` is a separate read-only binary. Register it and Claude Code, Claude Desktop,
Cursor, Windsurf or Zed can consult your work memory directly.

**Use Settings → Agents.** It lists the clients on this Mac, connects them one click each,
and repairs the entry if you later move the app. Memoir adds a single key to each config and
leaves everything else in the file alone.

Do it by hand and there is one trap worth knowing about, because it costs an afternoon:
**there is no global MCP registry, and the two clients called Claude read two different
files.**

| Client | File | Key |
|---|---|---|
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | `mcpServers` |
| Claude Code | `~/.claude.json` | `mcpServers` |
| Cursor | `~/.cursor/mcp.json` | `mcpServers` |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` | `mcpServers` |
| Zed | `~/.config/zed/settings.json` | `context_servers` |

```bash
# Claude Code only. This writes ~/.claude.json and does NOT touch the chat app.
claude mcp add --scope user memoir -- /Applications/Memoir.app/Contents/MacOS/memoir-mcp
```

Register with one and the other will tell you, correctly, that it cannot see any such
server, which reads as the whole thing being broken. Whichever route you take, **fully quit
and reopen** the client afterwards: closing the window is not enough, because the config is
read once at launch.

There is a second trap in Claude Code specifically, and `claude mcp add` walks straight into
it: **registering a server says nothing about permission to call it.** That lives in a
different file again (`~/.claude/settings.json`), so a hand-registered Memoir works, in the
sense that it stops and asks before every single lookup. Twelve dialogs before your first
answer, each one saying little more than that some server would like to run something.

Settings → Agents writes both files. By hand, add the eleven read-only tools yourself. They
open a database this server cannot write to, so there is no state on the other side of them
to protect:

```json
{
  "permissions": {
    "allow": [
      "mcp__memoir__recall",
      "mcp__memoir__who_is",
      "mcp__memoir__what_happened",
      "mcp__memoir__open_commitments",
      "mcp__memoir__today",
      "mcp__memoir__what_changed_since",
      "mcp__memoir__prior_art",
      "mcp__memoir__working_set",
      "mcp__memoir__sources_for",
      "mcp__memoir__verify",
      "mcp__memoir__timesheet"
    ]
  }
}
```

`propose_memory` is deliberately not on that list. It is the one tool that leaves something
behind for you to review, so it keeps its prompt.

Put these in `~/.claude/settings.json` rather than a project's `.claude/settings.local.json`.
Clicking **Always allow** in the dialog writes the project file, which means the approval does
not follow you to your next repo, and if you use git worktrees, each new worktree starts from
a copy and asks all over again.

```json
{
  "mcpServers": {
    "memoir": {
      "command": "/Applications/Memoir.app/Contents/MacOS/memoir-mcp"
    }
  }
}
```

Twelve tools. Eleven read; one stages.

| Tool | What it returns |
|---|---|
| `recall(query, limit?)` | Matching entities and captures, with provenance |
| `who_is(name)` | A dossier on a person: what's known, where they came up |
| `what_happened(from, to)` | Time per app and what came up, over a date range |
| `open_commitments()` | Outstanding promises, overdue flagged |
| `today()` | The daily brief |
| `what_changed_since(since)` | Catch a session up: new entities, updates, where time went |
| `prior_art(topic)` | Has this ground been covered? First seen, last touched, timeline |
| `working_set()` | What's in play right now: projects, windows, today's entities |
| `sources_for(claim)` | Quoted evidence for a claim, or an honest "nothing on record" |
| `verify(claim, freshDays?)` | Fresh, stale (with age), or absent. For keeping *other* memories honest |
| `timesheet(from, to)` | Per-day, per-project time with the captures each line rests on |
| `propose_memory(kind, title, …)` | Stages a memory for your review. Never writes the database |

Every answer carries provenance (which app, when), so the calling agent can cite Memoir rather than assert on its behalf.

`verify` is the one to point at your `CLAUDE.md` or your notes: a written assertion has no expiry date, and this is the tool that tells you when the screen stopped agreeing with it. `propose_memory` closes the loop in the other direction: an agent can suggest that a decision be remembered, and it lands in a review queue in Settings → Data. Accepting writes it as **yours**; rejecting deletes it. Agents propose; only you record.

Verify it without a client:

```bash
/Applications/Memoir.app/Contents/MacOS/memoir-mcp --selftest
```

### The skill

Twelve tools an agent never calls are twelve tools that don't exist. `Skills/memoir/SKILL.md`
is the missing half: it tells the agent *when*: verify a `CLAUDE.md` claim before inheriting
it, check `prior_art` before building something the user already abandoned, cite provenance
rather than asserting.

**Settings → Agents installs it** into `~/.claude/skills/memoir/`, keeping a copy of any
version you had edited. By hand: copy it into `~/.claude/skills/` for every project, or a
project's `.claude/skills/` for one.

It ships **inside the app bundle**, at `Contents/Resources/Skills/memoir/`, so an install
from a DMG carries it too. Otherwise the skill reaches only the people who cloned the repo,
which is nobody who installed the app.

Claude Code reads that directory. Claude Desktop does not: its equivalent arrives through
plugins, so the chat app gets the tools but not the doctrine.

### One-click install for Claude Desktop

```bash
bash Scripts/make-mcpb.sh      # → dist/memoir.mcpb
```

Double-click it, or drop it on Claude Desktop's **Settings → Extensions**. `.mcpb` (formerly
`.dxt`; both extensions still install) is a ZIP with a `manifest.json` at its root.

Memoir's is deliberately a **pointer, not a copy**: the manifest's `command` is the
`memoir-mcp` already inside the installed app, rather than a second binary embedded in the
bundle. A server shipped separately from the app could be a different build from the database
it reads, and the symptom would be answers from a schema that no longer exists. The bundle is
a few kilobytes and the two can never disagree, at the price that **Memoir.app must be
installed first**, which the script checks before it will build one.

---

