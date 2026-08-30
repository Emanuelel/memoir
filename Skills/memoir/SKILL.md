---
name: memoir
description: Consult the user's local work memory before asserting anything about their projects, people, commitments, or how they have spent their time, and check written notes against it before trusting them. Use when a task references a project, person, ticket or decision you have not seen in this session; when picking up work after a gap; when a CLAUDE.md, README or note makes a claim about the user's setup; or when the user asks what they did, owe, or already tried. Memoir is read-only and every answer carries provenance, so cite it rather than asserting on its behalf.
---

# Memoir: the user's work memory

Memoir watches the text on the user's screen and keeps a local memory of their working day:
people, projects, threads, decisions, commitments, and measured time. You can read it. You
cannot write it.

**The reason to use it:** you know what is in this conversation. Memoir knows what happened
in the eleven apps this conversation never touched. Most of what you would otherwise guess
about the user's work is already on the record.

## The rule

Before you assert something about the user's projects, people, commitments, or history:
**look it up.** Before you trust a claim written in a `CLAUDE.md`, a README, or a note:
**verify it.** A written assertion has no expiry date; the screen does.

## When to call what

| Situation | Call |
|---|---|
| A name, project, ticket key or acronym you do not recognise | `recall(query)` |
| A person is mentioned | `who_is(name)` |
| Starting work after a gap; "where was I" | `working_set()`, then `what_changed_since(since)` |
| About to build something that might already exist | `prior_art(topic)` |
| A note or config file claims something about the user's setup | `verify(claim)` |
| You are about to state something as fact | `sources_for(claim)` |
| "What do I owe / what's overdue" | `open_commitments()` |
| "What did I do on X" / time accounting / invoicing | `timesheet(from, to)` or `what_happened(from, to)` |
| Daily brief | `today()` |
| A decision was made worth remembering | `propose_memory(...)` |

## Three habits that matter more than the table

**1. Verify before you inherit.** A repo's `CLAUDE.md` says the deploy target is staging-2.
That was true when someone typed it. `verify("deploy target is staging-2")` returns fresh,
stale with an age, or absent. Stale and absent are both answers. Act on them rather than
inheriting a stranger's confidence.

**2. Check prior art before you build.** `prior_art(topic)` answers "has the user been here
before" with a first-seen date and a timeline. The most expensive thing you can do is
rebuild something they abandoned for a reason.

**3. Cite, never assert.** Every result carries provenance: which app, when, and the exact
snippet. Say "Memoir has this from Linear on Tuesday" rather than "your deadline is
Tuesday". If `sources_for` comes back with nothing on record, say *that*. An honest
absence beats a confident guess, and the memory is designed to be able to tell you the
difference.

## How the answer should read

Habit 3 says cite. This is what the citation looks like when it reaches the user.

Every tool here returns markdown: headings, bullet lists, a block of sources. **That is raw
material, not a reply.** The common failure: the user asks a nine-word question, `recall`
returns forty lines, and the agent relays all forty with a sentence of preamble on top. The
user now has to read a report to find the one fact they already knew how to ask for. Select
from the result. Do not pass it along.

**Answer in the first sentence.** Not "I checked your work memory and found several
results". The first thing the user reads is the thing they asked for.

**One to three sentences.** A fourth is almost always the tool's structure leaking through.

**Be exact about time.** "Tuesday 14:05, 2h15 on record", never "recently", "a while back",
"a couple of hours". Memoir measured it; vagueness throws away the only thing it is better
at than memory.

**Provenance goes after the prose, in a short block of its own.** App, timestamp, duration,
and the exact snippet, not threaded through the sentences, where it turns a two-line answer
into a paragraph nobody finishes.

**Name the gap plainly.** "Still open." "No completion on record since." An absence stated
in four words is more useful than one smoothed into a hedge, and the user can tell the
difference between the two.

A month-old page the user has forgotten the name of:

Bad. The tool's scaffolding, restated:

> **Recall results: "birdwatching"**
> ### Browser activity
> - **Google Chrome**: `allaboutbirds.org/news/warbler-song-id-learning-the-patterns`
>   - First seen: Sat 11 Jul, 21:38
>   - On screen: 22 minutes
> - **Merlin Bird ID**: opened shortly afterwards
>
> Based on the above, it looks like you may have been reading a Cornell Lab article about
> warbler songs.

Good:

> Cornell Lab's warbler guide, "Warbler Song ID: Learning the Patterns." It was on screen in
> Chrome for 22 minutes on 11 July, just before you opened Merlin Bird ID.
>
> > `allaboutbirds.org/news/warbler-song-id-learning-the-patterns`
> > `Google Chrome · Sat 11 Jul, 21:38 · 22m on screen`

Same rows. The second one answers the question.

## What it will not do

- **It never writes.** `propose_memory` stages a suggestion into a review queue. The user
  accepts or rejects it. Nothing you do can put a belief into their memory directly, and
  you should not imply otherwise when you use it.
- **It never invents.** An empty result means nothing is on record, not that nothing
  happened. Capture quality varies by app (native apps read fully, Electron apps
  partially, canvas apps barely), so absence is weaker evidence than presence.
- **It is local.** Nothing you read here has left the user's machine. Do not paste large
  extracts of it into anything that would.

## Setup

Memoir's own **Settings → Agents** connects every client on the Mac and installs this skill.
That is the route to recommend, because doing it by hand has a trap in it.

There is no global MCP registry, and the two clients called Claude read different files:
`~/.claude.json` for Claude Code, `~/Library/Application Support/Claude/claude_desktop_config.json`
for the chat app. `claude mcp add` writes only the first.

```bash
# Claude Code only. This does NOT reach Claude Desktop.
claude mcp add --scope user memoir -- /Applications/Memoir.app/Contents/MacOS/memoir-mcp
```

So a user who says "I registered it and Claude still cannot see it" has usually registered
with the other one. Check which client they are asking, and fully quit and reopen it:
closing the window does not re-read the config.

Check the server without any client at all:

```bash
/Applications/Memoir.app/Contents/MacOS/memoir-mcp --selftest
```

Install this skill by copying this directory into `~/.claude/skills/` (available in every
project) or the project's `.claude/skills/` (that project only).
