# Memoir: Answer Quality Evals

The golden set is the quality contract for answers, the way FLOWS.md is the contract for
behaviour. Every answer-pipeline change runs the evals; a regression is a red run, not a
vibe.

## Two modes

**Fixture mode (the gate).** A synthetic, seeded database with known facts. Deterministic,
CI-able, run against the `rulesOnly` brain by default and optionally against `appleOnDevice`.

```bash
Scripts/eval.sh
```

`memoir-eval-seed` builds the world into `.build/eval-fixture` (one invented working Monday,
16 March 2026, asked at noon, with ten days behind it), and `eval.sh` asks all 78 questions
against it. The database is regenerated every run rather than committed: `.gitignore` excludes
`*.sqlite`, and a checked-in database would migrate silently on open and start answering from a
schema nobody wrote.

Three switches make it reproducible, and all three are load-bearing:

| switch | what it pins |
|---|---|
| `--db` | answers come from the seeded database, never the user's |
| `MEMOIR_NOW` | "today", "overdue" and "due Friday" are dated to the fixture, not to the run |
| `MEMOIR_NO_MODEL` | silences every `FoundationModels` caller |

The last one is the least obvious and the most important. `QueryRewriter`'s rewrite and the
`GuidedClassifier` escalation both run **in front of** the brain whatever `--brain` says, so
without the gate the suite is reproducible on a Mac *without* Apple Intelligence and not on one
with it. No amount of fixture data fixes that.

The second is where the trap is. `MemoryService.context` has always taken a reference date, so it
was possible to date retrieval to the fixture while `RulesOnlyBrain` went on rendering "today" and
"overdue" from the wall clock: output that looks deterministic, passes, and changes on its own
the next time a date rolls over. The clock therefore reaches the floor through `BrainRouter`, and
the push parser with it: `remind me to send the invoice friday` resolves to **Fri 20 Mar** because
the fixture says so, and the eval asserts that.

**What green means, and what it does not.** The floor is a template engine with no free-text
recall. It answers commitments, arithmetic, resumption, "what do you know about X", and every
refusal; asked *"what url was the motion website"* it answers with the general status brief. So
for cases like that one the substring rules only hold it to not inventing and not denying, and
the whole expectation lives in the case's `expect`, where the judge grades it. **A green run
means nothing regressed. It does not mean every answer is good.**

**Live mode (`--live`, the probe).** Implemented in `memoir-ask --live`, reading
`Evals/live-questions.txt`. Run it before believing any answer-quality work. Runs against the
user's real database. Content is unknown, so grading is structural only: non-empty, no self-echo,
citations resolve, no URL in the answer that does not exist in the database, latency ceiling.
Informational, never a gate.

**Real mode (`Scripts/eval.sh --real`).** What this script used to do always: the graded questions
against the author's own database. Only `honesty` means anything there: the other 66 cases can
fail because something was never captured rather than because an answer is wrong.

## Two risks that are accepted rather than solved

**Routing can differ across macOS versions.** `QuestionRouter`'s centroids are averaged from
`NLEmbedding.sentenceEmbedding(for: .english)`, which is an OS artefact rather than something this
repository ships. A question sitting near a category boundary can therefore route differently on
a different macOS, and the answer changes with it. Nothing in the fixture can prevent that; the
mitigation is that `Scripts/eval.sh` reports the margin-sensitive failures as failures rather than
pretending they are flakes.

**The invented names are invented.** Every product, domain, repository and handle in the fixture
world (and in the source comments that describe the failures those strings originally caused) is
made up. The failures were real. The strings that produced them were one person's browsing record,
and this repository is public.

## Families

Seven groups, 78 cases, defined in `Evals/answers.json`, all graded against the seeded world.
Run one with `Scripts/eval.sh <group>`.

| group | cases | what it is for |
|---|---|---|
| `recall` | 11 | The highest-frequency job: you saw something and cannot find it again. Needs deep keyword search over a long window, precision before recency. |
| `resumption` | 8 | Reloading state after a context switch. Needs time-windowing and grouping by project. Currently the weakest of the three. |
| `accounting` | 6 | Arithmetic over sessions, not retrieval. Numbers must be right **and** the answer must address the question actually asked. |
| `honesty` | 12 | Must refuse rather than invent. Unlike the other groups this must pass on **any** database: refusing does not depend on what was captured. Guarded by CF-17b. |
| `quality` | 3 | Answers that pass every honesty guard and are still bad. Guards catch lies; nothing yet catches uselessness. This group is the backlog for the resumption work. |
| `edge` | 8 | Malformed, empty, adversarial and ambiguous input. Never crash, never invent, never leak. A memory that misbehaves on odd input is not trustworthy on normal input either. |
| `tier1` | 30 | Thirty questions in the shapes a basic-tier user would actually type, chosen to probe where a ~3B model breaks. Every one is answerable from the seeded world; none needs world knowledge. Failures here are selection failures, not knowledge failures. |

Each case declares `mustContain`, `mustContainAny`, `mustNotContain` and a plain-English
`expect`. Exact wording is not gradeable (a model phrases things differently every run), but
*does it name the right site* and *does it claim I created something* both are.

`expect` is not a comment. It is what the judge is given as "what a good answer looks like", so
it carries the whole ambition even where the substring rules are deliberately weaker. Where
the two differ, `expect` is the one that is right.

The substring rules are written to DISCRIMINATE, which takes some care. Asked how long Chrome
had, `mustContain: ["chrome", "1h 38m"]` is satisfied by the whole-day table that names every
app, and a real regression walked straight through it. So the accounting cases also forbid the
*other* apps' figures, and 58 of the 78 cases forbid the general status brief's closing line: a
question that has a specific answer must not be handed the status report instead.

## The judge

Substring matching cannot tell a good answer from a plausible one. Measured on the `tier1`
group, the same thirty questions scored:

    substring grading   29/30
    with the judge      19/30

Eleven answers "passed" that a reader would call wrong or useless. Measured on the real database
at the time: *"which app took most of my time today"* answered **Google Chrome** when Claude had
40 minutes, and *"am I forgetting something"* returned a browsing URL instead of the overdue
commitment. Both passed, because the grader only checked which words were present.

A suite that cannot see those is **worse than no suite**, because it reports a number.

```bash
ANTHROPIC_API_KEY=sk-ant-… Scripts/eval.sh tier1 --runs 3 --judge
```

**The judge must be a frontier model.** The first version used the local Qwen3-30B, which is
circular: Qwen scores 28/30 on these very questions, so a model that cannot reliably answer them
cannot reliably grade them. The judge is the ceiling on how good the measurement can be. Defaults
to `claude-sonnet-5`; override with `MEMOIR_JUDGE_MODEL`.

Without a key it falls back to the local model and **says so**, because a number produced by a
weaker judge is a floor rather than a score.

**What this sends.** The judge is a development tool and never ships. CF-2's "nothing leaves the
machine" is a promise about the product, not about grading it by hand. Against the fixture there
is nothing personal to disclose: the world is invented and so are the answers. Against `--real`
there is, because the corpus is then real questions and real answers about real screen activity.
That is a choice to make knowingly, which is why it needs an explicit key rather than defaulting
on.
