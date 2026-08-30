#!/usr/bin/env bash
# Grade Memoir's answers against Evals/answers.json.
#
# Unit tests prove the machinery works. This proves the ANSWERS are good, which is a
# different question and the one the product is actually judged on.
#
#   Scripts/eval.sh                 the gate: seeded world, rulesOnly, deterministic
#   Scripts/eval.sh honesty         one group
#   Scripts/eval.sh --judge         add the frontier judge (needs ANTHROPIC_API_KEY)
#   Scripts/eval.sh --real          the author's own database, by hand, never a gate
#
# FIXTURE MODE is the default and the only thing worth gating on. `memoir-eval-seed`
# builds a synthetic memory in .build/eval-fixture (one invented working Monday with
# ten days behind it), and every question is asked against that, at that Monday's
# noon, with every on-device model silenced. Same answers on any Mac, or it is a bug.
#
# Three switches make it reproducible and all three are load-bearing:
#   --db            answers from the seeded database, not the user's
#   MEMOIR_NOW      dates "today", "overdue" and "due Friday" to the fixture
#   MEMOIR_NO_MODEL silences QueryRewriter and the GuidedClassifier escalation, which
#                   run in front of the brain whatever --brain says. Without it the
#                   suite is reproducible on a Mac WITHOUT Apple Intelligence and not
#                   on one with it.
# MEMOIR_SUPPORT_DIR points the whole process at the fixture folder, so the ask log
# this run writes lands there rather than in the user's real memory.
#
# REAL MODE (--real) is what this script used to do always. Only the honesty group
# means anything there: the rest depend on what happens to have been captured, so a
# failure may mean "not captured yet" rather than "the answer is wrong".
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

BRAIN=""
JUDGE="${MEMOIR_EVAL_JUDGE:-}"
GROUP=""
RUNS="${MEMOIR_EVAL_RUNS:-}"
FIXTURE=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --brain) BRAIN="$2"; shift 2 ;;
        --judge) JUDGE=1; shift ;;
        --runs)  RUNS="$2"; shift 2 ;;
        --real)  FIXTURE=0; shift ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'; exit 0 ;;
        *) GROUP="$1"; shift ;;
    esac
done

# Built every run, not only when the binary is missing.
#
# `[[ -x "$ASK" ]] ||` was the old test and it is the wrong one: a checkout that has ever
# built memoir-ask has the file, so a stale binary is never rebuilt and the suite silently
# grades last month's code. Found by running this from a second checkout, where an old
# memoir-ask had never heard of MEMOIR_NOW: every date resolved from the wall clock, the
# fixture's one overdue commitment read as four, and eleven cases failed for a reason that
# had nothing to do with any of them. SwiftPM is incremental, so an up-to-date tree pays
# about a second for this.
ASK="$ROOT/.build/debug/memoir-ask"
SEED="$ROOT/.build/debug/memoir-eval-seed"
#
# Two invocations, not one with two --product flags: SwiftPM keeps only the LAST --product
# and silently builds that one alone. `swift build --product memoir-ask --product
# memoir-eval-seed` rebuilt the seeder, left a two-day-old memoir-ask in place, and produced
# exactly the failure this comment was written to fix.
echo "building..."
swift build --product memoir-ask >/dev/null
swift build --product memoir-eval-seed >/dev/null

if [[ "$FIXTURE" == "1" ]]; then
    BRAIN="${BRAIN:-rulesOnly}"
    # Rebuilt every run rather than committed. `.gitignore` excludes *.sqlite, and that is
    # the right answer anyway: a checked-in database would migrate silently on open and
    # start answering from a schema nobody wrote.
    FIXTURE_DIR="$ROOT/.build/eval-fixture"
    "$SEED" "$FIXTURE_DIR" 2>/dev/null | sed 's/^/  /'

    export MEMOIR_DB_PATH="$FIXTURE_DIR/memoir.sqlite"
    export MEMOIR_SUPPORT_DIR="$FIXTURE_DIR"
    export MEMOIR_NOW="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['reference'])" "$FIXTURE_DIR/facts.json")"
    export MEMOIR_NO_MODEL=1
    # One run is enough when the answer cannot vary. A model brain over the same fixture
    # still varies, so it still gets three.
    [[ "$BRAIN" == "rulesOnly" ]] && RUNS="${RUNS:-1}"
else
    BRAIN="${BRAIN:-appleOnDevice}"
    unset MEMOIR_DB_PATH MEMOIR_SUPPORT_DIR MEMOIR_NOW MEMOIR_NO_MODEL || true
fi

export MEMOIR_EVAL_BRAIN="$BRAIN"
export MEMOIR_EVAL_GROUP="$GROUP"
export MEMOIR_EVAL_RUNS="${RUNS:-3}"
export MEMOIR_EVAL_JUDGE="$JUDGE"
export MEMOIR_EVAL_FIXTURE="$FIXTURE"
unset MEMOIR_GENERATION_TIMEOUT || true

python3 - "$ROOT" <<'PY'
import json, os, subprocess, sys

root = sys.argv[1]
spec = json.load(open(os.path.join(root, "Evals/answers.json")))
brain = os.environ.get("MEMOIR_EVAL_BRAIN", "appleOnDevice")
runs = int(os.environ.get("MEMOIR_EVAL_RUNS", "3"))
only = os.environ.get("MEMOIR_EVAL_GROUP") or None
ask = os.path.join(root, ".build/debug/memoir-ask")

BOLD, DIM, RED, GREEN, YELLOW, OFF = "\033[1m", "\033[2m", "\033[31m", "\033[32m", "\033[33m", "\033[0m"
if not sys.stdout.isatty():
    BOLD = DIM = RED = GREEN = YELLOW = OFF = ""

# The judge is a FRONTIER model, not a local one.
#
# The first version used the same Qwen3-30B that the suite was measuring, and that is
# circular in a way that matters: Qwen scored 28/30 on these very questions, so a model
# that cannot reliably answer them cannot reliably grade them either. The judge is the
# ceiling on how good the measurement can be, so it should be the best model available,
# not the most convenient one.
#
# This is a DEVELOPMENT tool and never ships. CF-2's "nothing leaves the machine" is a
# promise about the product; grading runs on the developer's machine, by hand.
#
# But be honest about what it sends: the eval corpus carries real questions and real
# answers about real screen activity. Choosing a cloud judge is choosing to disclose
# those to Anthropic. That is the developer's call to make knowingly, which is why it
# requires an explicit key rather than defaulting on.
ANTHROPIC_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
JUDGE_MODEL = os.environ.get("MEMOIR_JUDGE_MODEL", "claude-sonnet-5")
LOCAL_URL = os.environ.get("MEMOIR_LOCAL_URL", "")
LOCAL_MODEL = os.environ.get("MEMOIR_LOCAL_MODEL", "")
WANT_JUDGE = bool(os.environ.get("MEMOIR_EVAL_JUDGE"))
USE_JUDGE = WANT_JUDGE and (ANTHROPIC_KEY or (LOCAL_URL and LOCAL_MODEL))
if WANT_JUDGE and not ANTHROPIC_KEY and LOCAL_URL:
    print("  note: no ANTHROPIC_API_KEY, falling back to the local model as judge.")
    print("        A local judge is weaker than the thing it grades. Treat the number as a floor.")

def judge(question, expected, answer):
    """Ask a large model whether the answer is actually good.

    Substring matching cannot tell a good answer from a plausible one. Measured on the
    tier1 group: 29/30 "passed" while two of three spot-checked answers were wrong or
    useless - "which app took most of my time today" -> "Google Chrome" when Claude had
    40 minutes, and "am I forgetting something" -> a browsing URL instead of the overdue
    commitment. Both passed, because the grader only checks that certain words are present
    or absent. A suite that cannot see those is measuring nothing, which is worse than not
    measuring, because it reports a number.

    Returns (ok, why). Falls back to (None, reason) when the judge is unreachable, so a
    sleeping Mac mini degrades to substring grading instead of failing the run.
    """
    import urllib.request
    prompt = f"""A memory assistant was asked a question about the user's own computer activity.
Judge whether its answer is GOOD.

Question: {question}
What a good answer looks like: {expected}
The assistant answered: {answer}

An answer is BAD if it is off-topic, if it dumps a list when one item was asked for, if it
states something the question did not ask about, or if it is technically true but does not
answer. An honest "I do not have that" is GOOD when the expectation says to refuse, and BAD
when the expectation says real information was available.
Reply with exactly one line: GOOD or BAD, then a dash and at most twelve words of reason."""
    try:
        if ANTHROPIC_KEY:
            body = json.dumps({
                "model": JUDGE_MODEL,
                "max_tokens": 60,
                "messages": [{"role": "user", "content": prompt}],
            }).encode()
            req = urllib.request.Request(
                "https://api.anthropic.com/v1/messages", data=body,
                headers={"Content-Type": "application/json",
                         "x-api-key": ANTHROPIC_KEY,
                         "anthropic-version": "2023-06-01"})
            with urllib.request.urlopen(req, timeout=90) as r:
                text = json.load(r)["content"][0]["text"].strip()
        else:
            body = json.dumps({
                "model": LOCAL_MODEL,
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 60, "temperature": 0,
            }).encode()
            req = urllib.request.Request(LOCAL_URL.rstrip("/") + "/chat/completions", data=body,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=90) as r:
                text = json.load(r)["choices"][0]["message"]["content"].strip()
    except Exception as e:
        return None, f"judge unreachable: {e}"
    return text.upper().startswith("GOOD"), text

def run(question):
    out = subprocess.run(
        [ask, "--quiet", "--brain", brain, question],
        capture_output=True, text=True, timeout=180)
    return out.stdout.strip()

total = passed = 0
failures = []

for group in spec["groups"]:
    if only and group["name"] != only:
        continue
    print(f"\n{BOLD}── {group['name']} ──{OFF}")
    print(f"{DIM}{group['why']}{OFF}\n")

    for case in group["cases"]:
        total += 1
        q = case["q"]

        # Every case is run N times. A single run is noise: the same code scored 20/23 and
        # 21/23 on consecutive runs, and one case passed twice then failed once. Grading a
        # rate rather than a coin flip is the difference between measuring and guessing.
        outcomes, problems_seen, samples = [], [], []
        for _ in range(runs):
            try:
                answer = run(q)
            except subprocess.TimeoutExpired:
                answer = "<TIMED OUT>"
            low = answer.lower()
            problems = []
            for needle in case.get("mustContain", []):
                if needle.lower() not in low:
                    problems.append(f"missing {needle!r}")
            any_of = case.get("mustContainAny", [])
            if any_of and not any(n.lower() in low for n in any_of):
                problems.append("none of " + ", ".join(repr(n) for n in any_of))
            for needle in case.get("mustNotContain", []):
                if needle.lower() in low:
                    problems.append(f"contains {needle!r}")
            # The judge has the final say when it is available: a substring pass that a
            # reader would call a bad answer is exactly the failure this exists to catch.
            if USE_JUDGE and not problems:
                ok, why = judge(q, case.get("expect", ""), answer)
                if ok is False:
                    problems.append(f"judge: {why[:80]}")

            outcomes.append(not problems)
            if problems:
                problems_seen.append("; ".join(problems))
                samples.append(answer.replace("\n", " ")[:150])

        hits = sum(outcomes)
        rate = hits / runs
        # A case only counts as passing if it passes EVERY run. Flaky is not passing: an
        # answer that is right two times in three is a bug you have not characterised yet.
        ok = hits == runs
        passed += ok
        if ok:
            mark = f"{GREEN}PASS{OFF}"
        elif hits:
            mark = f"{YELLOW}FLAKY{OFF}"
        else:
            mark = f"{RED}FAIL{OFF}"
        print(f"  {mark}  {q}  {DIM}({hits}/{runs}){OFF}")
        if not ok:
            print(f"        {DIM}expected: {case['expect']}{OFF}")
            print(f"        {YELLOW}{problems_seen[0]}{OFF}")
            print(f"        {DIM}got: {samples[0]}{OFF}")
            failures.append((group["name"], q, hits, runs))

world = "seeded fixture" if os.environ.get("MEMOIR_EVAL_FIXTURE") == "1" else "YOUR REAL DATABASE"
print(f"\n{BOLD}{passed}/{total} passed{OFF}  ({world}, brain: {brain}, {runs} run{'' if runs == 1 else 's'} per case)")
if os.environ.get("MEMOIR_EVAL_FIXTURE") != "1":
    print(f"{DIM}Only the honesty group is gradeable here. Everything else depends on what")
    print(f"happens to have been captured, so read the expectation before believing a failure.{OFF}")
elif not USE_JUDGE:
    print(f"{DIM}Substring grading only. A green run means nothing regressed, not that every")
    print(f"answer is good. Pass --judge with an ANTHROPIC_API_KEY for that.{OFF}")
if failures:
    print(f"\n{DIM}failing:{OFF}")
    for g, q, hits, n in failures:
        label = "flaky" if hits else "fail "
        print(f"  {label} {g}: {q} ({hits}/{n})")
sys.exit(0 if passed == total else 1)
PY
