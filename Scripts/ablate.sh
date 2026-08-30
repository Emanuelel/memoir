#!/usr/bin/env bash
# Decide whether the returns block earns its tokens.
#
#   Scripts/ablate.sh --db <path> [--from 2026-07-31] [--to 2026-08-27]
#
# Builds the same window three ways and asks the eight questions in Evals/ablation.json
# against each. The criterion is in that file and was written before the block existed,
# which is the only reason it means anything.
#
#   none      coverage + days. The control.
#   full      coverage + days + returns at the real floor.
#   placebo   coverage + days + returns of the SAME ROW COUNT from subjects BELOW the
#             floor. Adding plausible text moves an answer on its own; this arm is what
#             separates "the block helped" from "the prompt got longer".
#
# Without ANTHROPIC_API_KEY it builds the three payloads, reports their sizes, and stops.
# That half is deterministic and is what CI runs. The scoring half needs a model, the way
# Scripts/eval.sh --judge does.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

DB=""; FROM=""; TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db) DB="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

SPEC="Evals/ablation.json"
[[ -f "$SPEC" ]] || { echo "missing $SPEC" >&2; exit 2; }
FROM="${FROM:-$(python3 -c "import json;print(json.load(open('$SPEC'))['window']['from'])")}"
TO="${TO:-$(python3 -c "import json;print(json.load(open('$SPEC'))['window']['to'])")}"
[[ -n "$DB" ]] || { echo "--db is required" >&2; exit 2; }

swift build --product memoir-mcp >/dev/null
MCP="./.build/debug/memoir-mcp"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# One MCP session per arm, so a tool's own state cannot leak between them.
call() {
  local name="$1" args="$2"
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ablate","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args}}" \
    | "$MCP" --db "$DB" 2>/dev/null \
    | python3 -c "
import sys, json
for line in sys.stdin:
    try: d = json.loads(line)
    except ValueError: continue
    if d.get('id') == 2:
        c = d.get('result', {}).get('content', [{}])
        print(c[0].get('text', '') if c else '')
"
}

RANGE="{\"from\":\"$FROM\",\"to\":\"$TO\"}"
call coverage "$RANGE" > "$OUT/coverage.md"
call what_happened "$RANGE" > "$OUT/days.md"

# The returns block, at the real floor and below it. A server without the tool yet
# writes an empty file, and the harness reports that rather than pretending.
call returns "$RANGE" > "$OUT/returns-full.md" || true
# awk rather than `grep -c || echo 0`: grep exits 1 on no matches AND prints 0, so the
# fallback appended a second 0 and the arithmetic below silently failed open. An
# unrunnable gate that exits 0 is exactly the failure this script exists to catch, and it
# managed to commit it on its first run.
FULL_ROWS=$(awk '/^\| /{n++} END{print n+0}' "$OUT/returns-full.md" 2>/dev/null || echo 0)
# The placebo has to be the SAME SHAPE as the full table, not the same rule with a
# different threshold. The below-floor population is an order of magnitude larger — 1,080
# subjects against 71 on the developer's vault — so an untruncated placebo arm is thirteen
# times the prompt and measures length rather than content, which is the exact confound
# this arm exists to remove. Truncated to the full table's row count, keeping the
# highest-ranked below-floor rows so it reads as plausible.
call returns "{\"from\":\"$FROM\",\"to\":\"$TO\",\"minDays\":1,\"maxDays\":2}" \
  > "$OUT/returns-placebo-raw.md" || true
awk -v keep="$FULL_ROWS" '
  /^\| / { data++; if (data > 2 + keep) next }   # header row + separator, then keep rows
  { print }
' "$OUT/returns-placebo-raw.md" > "$OUT/returns-placebo.md"

cat "$OUT/coverage.md" "$OUT/days.md" > "$OUT/arm-none.md"
cat "$OUT/arm-none.md" "$OUT/returns-full.md" > "$OUT/arm-full.md"
cat "$OUT/arm-none.md" "$OUT/returns-placebo.md" > "$OUT/arm-placebo.md"

echo "window        $FROM → $TO"
for arm in none full placebo; do
  printf 'arm %-9s %6s chars\n' "$arm" "$(wc -c < "$OUT/arm-$arm.md" | tr -d ' ')"
done
echo "returns rows  $FULL_ROWS"

if [[ "$FULL_ROWS" -eq 0 ]]; then
  echo
  echo "The returns tool returned nothing. Either it is not built yet, or the window is empty."
  echo "The gate cannot run, and an unrunnable gate is not a pass."
  exit 3
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo
  echo "No ANTHROPIC_API_KEY. Payloads built and checked; scoring skipped."
  echo "Copies kept for inspection:"
  KEEP="${TMPDIR:-/tmp}/memoir-ablation"
  rm -rf "$KEEP"; mkdir -p "$KEEP"; cp "$OUT"/arm-*.md "$OUT"/returns-*.md "$KEEP/"
  echo "  $KEEP"
  trap - EXIT; rm -rf "$OUT"
  exit 0
fi

python3 Scripts/ablate_score.py \
  --spec "$SPEC" \
  --none "$OUT/arm-none.md" \
  --full "$OUT/arm-full.md" \
  --placebo "$OUT/arm-placebo.md" \
  --returns-full "$OUT/returns-full.md" \
  --returns-placebo "$OUT/returns-placebo.md"
