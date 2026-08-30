#!/usr/bin/env python3
"""Score the ablation arms against the criterion declared in Evals/ablation.json.

The scoring rule is mechanical on purpose. A judge asked "did this answer get better"
returns an opinion, and this project has been burned twice by a measurement that turned
out to be measuring something else. So the rule is: an answer USES the returns block when
it names a subject key that appears in that arm's returns table and nowhere in the
coverage or days blocks. Paraphrase does not count. If a model can answer without naming
anything only the block supplied, the block did not contribute.
"""
import argparse, json, os, re, sys, urllib.request

MODEL = "claude-opus-4-5"
API = "https://api.anthropic.com/v1/messages"


def keys_from(table: str) -> list[str]:
    """Row keys from a markdown returns table: the first cell of each data row."""
    out = []
    for line in table.splitlines():
        if not line.startswith("| "):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if not cells or not cells[0] or set(cells[0]) <= set("- :"):
            continue
        if cells[0].lower() in {"subject", "key", "hour"}:
            continue
        out.append(cells[0])
    return out


def ask(payload: str, question: str) -> str:
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 900,
        "messages": [{
            "role": "user",
            "content": (
                "Here is everything a local memory can tell you about a stretch of one "
                "person's time. Answer their question from it. Do not invent anything that "
                "is not here, and say plainly what the record cannot support.\n\n"
                f"{payload}\n\n---\n\nTheir question: {question}"
            ),
        }],
    }).encode()
    req = urllib.request.Request(API, data=body, headers={
        "content-type": "application/json",
        "x-api-key": os.environ["ANTHROPIC_API_KEY"],
        "anthropic-version": "2023-06-01",
    })
    with urllib.request.urlopen(req, timeout=180) as r:
        return "".join(b.get("text", "") for b in json.load(r)["content"])


def uses_block(answer: str, block_keys: list[str], shared: str) -> str | None:
    """The first block-only key this answer names, or None."""
    low = answer.lower()
    for key in block_keys:
        k = key.strip().lower()
        # Long enough to be a claim rather than a coincidence, and absent from the
        # blocks both arms share, or it is not evidence the block was read.
        if len(k) < 6 or k in shared:
            continue
        if k in low:
            return key
    return None


def main() -> int:
    p = argparse.ArgumentParser()
    for flag in ("spec", "none", "full", "placebo", "returns-full", "returns-placebo"):
        p.add_argument("--" + flag, required=True)
    a = p.parse_args()

    spec = json.load(open(a.spec))
    crit = spec["criterion"]
    arms = {n: open(getattr(a, n)).read() for n in ("none", "full", "placebo")}
    shared = arms["none"].lower()
    keys = {
        "full": keys_from(open(getattr(a, "returns_full")).read()),
        "placebo": keys_from(open(getattr(a, "returns_placebo")).read()),
    }

    print(f"full table: {len(keys['full'])} rows   placebo table: {len(keys['placebo'])} rows")
    if not keys["placebo"]:
        print("\nNo placebo rows. The gate cannot separate the block from its own length.")
        return 3
    if abs(len(keys["full"]) - len(keys["placebo"])) > max(2, len(keys["full"]) // 5):
        print("\nThe placebo is not shape-matched to the full table. Fix that before scoring.")
        return 3

    used = {"full": 0, "placebo": 0}
    for q in spec["questions"]:
        line = [f"{q['id']:<16}"]
        for arm in ("none", "full", "placebo"):
            answer = ask(arms[arm], q["ask"])
            hit = uses_block(answer, keys.get(arm, []), shared) if arm != "none" else None
            if hit:
                used[arm] += 1
            line.append(f"{arm}:{'✓ ' + hit[:24] if hit else '·'}")
        print("  ".join(line))

    n = len(spec["questions"])
    margin = used["full"] - used["placebo"]
    print(f"\nfull used the block on {used['full']}/{n}; placebo on {used['placebo']}/{n}; margin {margin}")
    print(f"criterion: at least {crit['fullMinimumUses']} uses AND a margin of at least "
          f"{crit['fullMustExceedPlaceboBy']}")

    if used["full"] >= crit["fullMinimumUses"] and margin >= crit["fullMustExceedPlaceboBy"]:
        print("\nSHIPS.")
        return 0
    print("\nCUT. The returns block does not earn its tokens on this window.")
    print("That is a result, not a failure: it is half the budget and all of the narration risk.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
