# The returns block: CUT

Run 27 August 2026, on the author's own vault, window 2026-07-31 → 2026-08-27.
Criterion from `Evals/ablation.json`, written before the block existed and not moved.

```
full arm     used the table on 7 of 8 questions
placebo arm  used the decoy on 7 of 8 questions
margin       0                 (criterion required 3)
```

**Result: CUT.** The block cleared the first half of the criterion easily and failed the
second half completely.

## What the placebo was

A returns table of the same row count and the same columns as the real one, built from
subjects **below the floor** — things returned to on one or two days rather than three or
more. Same shape. The ranking, which is the block's entire value, is the only thing missing.

## What happened

Given the real table, the answering model named things returned to on eighteen separate
days. Given the decoy, it named a gym sign-up, wedding venues and a maps window visited
twice — and said them with exactly the same confidence, in exactly the same shape of
sentence, on seven of the same eight questions.

So the finding is not that the table is empty or wrong. Every row in both tables is true.
The finding is that **a ranked table does not convey its ranking to a reader.** A model
handed a list of specific subjects will narrate them, and it cannot see which ones are
load-bearing. The number in the "days" column changes nothing about what gets said.

That is the same hole the design panel left open and could not close: *nothing in the page
constrains how the page is read.* This is what that costs, measured.

## What survives

The coverage block. On every question the answers leaned on it — how much of the clock was
watched, which hours are absent, what a gap does and does not mean. The control arm, holding
coverage and days alone, produced answers that were shorter and more careful and no less
useful, and it is a third of the size.

## Do not re-run this hoping for a different number

If the block comes back, it comes back with a mechanism that makes the ranking legible to a
reader — not with a better table. A larger floor, a smaller table, a different sort order and
a longer window are all changes to the table, and the table was never the problem.
