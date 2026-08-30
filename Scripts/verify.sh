#!/usr/bin/env bash
#
# Memoir: one-command verification.
#
# Ten stages, in the order that fails cheapest first. Every stage is timed, every
# stage prints PASS or FAIL, and the run exits non-zero if any of them failed.
#
#    1  build (debug)        a genuinely clean build, and any warning fails the run
#    2  tests                unit + integration, including the MCP subprocess flows
#    3  answer evals         78 graded answers against a seeded database
#    4  build (release)
#    5  app bundle           Scripts/build-app.sh assembles Memoir.app
#    6  bundle sanity        structure, Info.plist, signature, memoir-mcp inside it
#    7  memoir-mcp --selftest
#    8  mcp stdio smoke      real binary, real pipe, JSON-RPC in and out
#    9  privacy containment  outbound networking lives in three named files, on terms
#   10  hygiene              no TODO / FIXME / unimplemented left in Sources/
#
# Stage 3 is here because the tests prove the machinery works and cannot see whether
# the ANSWERS are good, which is the thing the product is judged on. It grades against
# a synthetic memory it seeds itself, so it means the same on every machine. It
# stays in --fast, because an answer regression is not a packaging detail.
#
#   Scripts/verify.sh            everything
#   Scripts/verify.sh --fast     skip 4-6 (release build and bundle)
#   Scripts/verify.sh --flows    the CF-ID table from the test run, nothing else
#
# The flow table is driven by FLOWS.md: every `### CF-N` heading there must be
# claimed by a test whose name carries that ID, or it shows up as untested.
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Location. Everything is relative to the repo root derived from this file, so
# the script runs identically from any working directory.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

if [[ ! -f "$ROOT/Package.swift" ]]; then
    echo "verify.sh: no Package.swift at $ROOT. Is this script still inside the repo?" >&2
    exit 2
fi
cd "$ROOT"

LOG_DIR="$ROOT/.build/verify-logs"
# A dedicated scratch path, wiped every run, so stage 1 recompiles every file and
# the compiler actually re-emits its warnings. An incremental build into .build
# says nothing about a file it did not touch. This one is separate from .build so
# it does not fight SwiftPM's lock or throw away the test build's cache.
WARN_SCRATCH="$ROOT/.build/verify-debug"
# Deliberately not "$LOG_DIR/2-tests.log": that is the stage log, and pointing both
# at one path leaves two file descriptors writing over each other's bytes.
TEST_LOG="$LOG_DIR/2-tests.raw.log"

# A real on-device cold start is ~60s, and a generation that outlives its temp
# database causes a SQLite disk I/O error during teardown. Tests get a short leash.
export MEMOIR_GENERATION_TIMEOUT="${MEMOIR_GENERATION_TIMEOUT:-2}"

BUILD_TIMEOUT="${MEMOIR_VERIFY_BUILD_TIMEOUT:-900}"
TEST_TIMEOUT="${MEMOIR_VERIFY_TEST_TIMEOUT:-1800}"
MCP_TIMEOUT="${MEMOIR_VERIFY_MCP_TIMEOUT:-60}"

# ─────────────────────────────────────────────────────────────────────────────
# Arguments
# ─────────────────────────────────────────────────────────────────────────────
FAST=0
FLOWS_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --fast)  FAST=1 ;;
        --flows) FLOWS_ONLY=1 ;;
        -h|--help)
            sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'
            exit 0 ;;
        *)
            echo "verify.sh: unknown option '$arg' (want --fast, --flows or --help)" >&2
            exit 2 ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Presentation
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    DIM=$'\033[2m';  BOLD=$'\033[1m';   OFF=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; DIM=""; BOLD=""; OFF=""
fi

rule() { printf '%s%s%s\n' "$DIM" "──────────────────────────────────────────────────────────────────────" "$OFF"; }

# Milliseconds since the epoch. perl ships with macOS; the fallback keeps the
# script working on a stripped-down machine, at second resolution.
now_ms() {
    perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}

fmt_ms() { awk -v ms="$1" 'BEGIN { printf "%.1fs", ms / 1000 }'; }

# Runs a command with a hard deadline. alarm(2) survives exec, and exec resets
# SIGALRM to its default action, so the child is killed even if it ignores us.
# Returns 142 on timeout, like the coreutils `timeout` this machine does not have.
with_timeout() {
    local secs="$1"; shift
    perl -e 'my $t = shift @ARGV; alarm $t; exec { $ARGV[0] } @ARGV; exit 127;' "$secs" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage bookkeeping (bash 3.2: parallel indexed arrays, no associative ones)
# ─────────────────────────────────────────────────────────────────────────────
STAGE_TOTAL=10
STAGE_N=0
FAILED=0
S_NAME=(); S_STATUS=(); S_MS=(); S_LOG=()

stage_hint() {
    case "$1" in
        1-build-debug)   echo "swift build --scratch-path $WARN_SCRATCH    # reproduce, warnings and all" ;;
        2-tests)         echo "swift test --filter '<CF-id>'    # full output: $TEST_LOG" ;;
        3-evals)         echo "Scripts/eval.sh <group>    # the seeded world and its arithmetic are in .build/eval-fixture/facts.json" ;;
        4-build-release) echo "swift build -c release" ;;
        5-app-bundle)    echo "bash Scripts/build-app.sh" ;;
        6-bundle-sanity) echo "the bundle at build/Memoir.app is incomplete or unsigned. Rerun Scripts/build-app.sh" ;;
        7-selftest)      echo "swift build --product memoir-mcp, then: .build/debug/memoir-mcp --selftest --db /tmp/memoir-selftest.sqlite" ;;
        8-mcp-stdio)     echo "memoir-mcp must answer initialize and tools/list with JSON-RPC frames and nothing else on stdout" ;;
        9-privacy)       echo "outbound networking belongs only in NETWORK_OWNERS: the two brains that send by design, the update check, which may only ask, and the weather lookup, which is off by default" ;;
        10-hygiene)      echo "finish it or delete it: no markers ship in Sources/" ;;
        *)               echo "" ;;
    esac
}

run_stage() {
    local key="$1" name="$2"; shift 2
    STAGE_N=$((STAGE_N + 1))
    local log="$LOG_DIR/$key.log"
    printf '%s==> %d/%d  %s%s\n' "$BOLD" "$STAGE_N" "$STAGE_TOTAL" "$name" "$OFF"

    local start end ms rc=0
    start="$(now_ms)"
    "$@" > "$log" 2>&1 || rc=$?
    end="$(now_ms)"
    ms=$((end - start))

    S_NAME+=("$name"); S_MS+=("$ms"); S_LOG+=("$log")
    if [[ $rc -eq 0 ]]; then
        S_STATUS+=("PASS")
        printf '    %sPASS%s  %s\n\n' "$GREEN" "$OFF" "$(fmt_ms "$ms")"
    else
        S_STATUS+=("FAIL")
        FAILED=1
        printf '    %sFAIL%s  %s  (exit %d)\n' "$RED" "$OFF" "$(fmt_ms "$ms")" "$rc"
        [[ $rc -eq 142 ]] && printf '    %stimed out%s\n' "$RED" "$OFF"
        sed 's/^/    | /' "$log" | tail -30
        printf '    %s%s%s\n\n' "$YELLOW" "$(stage_hint "$key")" "$OFF"
    fi
}

skip_stage() {
    local name="$1"
    STAGE_N=$((STAGE_N + 1))
    S_NAME+=("$name"); S_STATUS+=("SKIP"); S_MS+=("-1"); S_LOG+=("")
    printf '%s==> %d/%d  %s%s\n    %sSKIP%s  (--fast)\n\n' \
        "$BOLD" "$STAGE_N" "$STAGE_TOTAL" "$name" "$OFF" "$DIM" "$OFF"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: debug build, warnings fatal
# ─────────────────────────────────────────────────────────────────────────────
stage_build_debug() {
    local raw="$LOG_DIR/1-build-debug.raw.log"
    rm -rf "$WARN_SCRATCH"
    local rc=0
    with_timeout "$BUILD_TIMEOUT" swift build --scratch-path "$WARN_SCRATCH" > "$raw" 2>&1 || rc=$?
    cat "$raw"
    if [[ $rc -ne 0 ]]; then
        echo
        echo "the debug build failed."
        return "$rc"
    fi
    local warnings
    warnings="$(grep -nE '(^|[[:space:]])warning:' "$raw" || true)"
    if [[ -n "$warnings" ]]; then
        echo
        echo "the build is not clean, $(printf '%s\n' "$warnings" | wc -l | tr -d ' ') warning line(s):"
        printf '%s\n' "$warnings"
        return 1
    fi
    echo
    echo "clean: no warnings from a full recompile of every source file."
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: the test suite
# ─────────────────────────────────────────────────────────────────────────────
stage_tests() {
    local rc=0
    with_timeout "$TEST_TIMEOUT" swift test > "$TEST_LOG" 2>&1 || rc=$?
    # The raw log is ~1k lines, most of it the app's own stderr. Show the verdict
    # lines and the failures, and leave the rest on disk.
    grep -E '^[^A-Za-z0-9[:space:][]+ Test .*(failed|recorded an issue)' "$TEST_LOG" | head -60 || true
    grep -E '^[^A-Za-z0-9[:space:][]+ Test run (with|started)' "$TEST_LOG" || true
    if [[ $rc -ne 0 ]]; then
        echo
        echo "full output: $TEST_LOG"
    fi
    return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: answer evals against the seeded world
#
# `Scripts/eval.sh` seeds its own database, dates every question to that database's
# day and silences every on-device model, so this is the one stage whose result is a
# property of the code rather than of the machine it ran on. Roughly 20 seconds.
# ─────────────────────────────────────────────────────────────────────────────
stage_evals() {
    local rc=0
    bash "$ROOT/Scripts/eval.sh" > "$LOG_DIR/3-evals.raw.log" 2>&1 || rc=$?
    # The per-case lines are 78 of them and mostly PASS. Show the verdict and whatever
    # failed; the rest stays on disk.
    grep -E 'FAIL|FLAKY' "$LOG_DIR/3-evals.raw.log" | head -40 || true
    grep -E 'passed  \(' "$LOG_DIR/3-evals.raw.log" || true
    if [[ $rc -ne 0 ]]; then
        echo
        echo "full output: $LOG_DIR/3-evals.raw.log"
    fi
    return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4/5: release build and bundle
# ─────────────────────────────────────────────────────────────────────────────
stage_build_release() { with_timeout "$BUILD_TIMEOUT" swift build -c release; }
stage_app_bundle()    { with_timeout "$BUILD_TIMEOUT" bash "$ROOT/Scripts/build-app.sh"; }

# ─────────────────────────────────────────────────────────────────────────────
# Stage 6: bundle sanity
# ─────────────────────────────────────────────────────────────────────────────
stage_bundle_sanity() {
    local app="$ROOT/build/Memoir.app"
    local bad=0
    [[ -d "$app" ]] || { echo "missing $app"; return 1; }

    local required=(
        "Contents/MacOS/Memoir"
        "Contents/MacOS/memoir-mcp"
        "Contents/Info.plist"
    )
    local item
    for item in "${required[@]}"; do
        if [[ -f "$app/$item" ]]; then
            echo "  ok       $item"
        else
            echo "  MISSING  $item"; bad=1
        fi
    done
    for item in "Contents/MacOS/Memoir" "Contents/MacOS/memoir-mcp"; do
        if [[ -f "$app/$item" && ! -x "$app/$item" ]]; then
            echo "  NOT EXECUTABLE  $item"; bad=1
        fi
    done
    [[ $bad -eq 0 ]] || { echo "bundle structure is incomplete"; return 1; }

    echo "  ---- plutil -lint ----"
    plutil -lint "$app/Contents/Info.plist" || return 1
    local bundle_id
    bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
    [[ -n "$bundle_id" ]] || { echo "Info.plist has no CFBundleIdentifier"; return 1; }
    echo "  CFBundleIdentifier = $bundle_id"

    # Every usage description below is load-bearing at runtime and completely silent at
    # build time. Dropping one does not fail to compile and does not fail to launch: TCC
    # kills the process the first time the matching API is touched, so the user meets it
    # as a crash while dictating or while saving a todo. Asserting them here turns that
    # into a red line in a build nobody has shipped yet.
    echo "  ---- Info.plist keys ----"
    local required_keys=(
        CFBundleExecutable
        CFBundleName
        LSMinimumSystemVersion
        NSAccessibilityUsageDescription
        NSAppleEventsUsageDescription
        NSMicrophoneUsageDescription
        NSSpeechRecognitionUsageDescription
        NSRemindersFullAccessUsageDescription
        NSContactsUsageDescription
        NSCalendarsFullAccessUsageDescription
        NSPhotoLibraryUsageDescription
        NSLocationUsageDescription
    )
    local key value
    for key in "${required_keys[@]}"; do
        value="$(plutil -extract "$key" raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
        if [[ -n "$value" ]]; then
            echo "  ok       $key"
        else
            echo "  MISSING  $key"; bad=1
        fi
    done
    [[ $bad -eq 0 ]] || { echo "Info.plist is missing a key the app needs at runtime"; return 1; }

    echo "  ---- codesign -dv ----"
    codesign -dv "$app" 2>&1 || { echo "codesign -dv failed: the bundle is not signed"; return 1; }
    echo "  ---- codesign --verify ----"
    codesign --verify --verbose=1 "$app" 2>&1 || { echo "the signature does not verify"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# Which memoir-mcp do stages 6 and 7 talk to
#
# Full run: the copy inside the bundle, because that is the one a user would
# actually wire into Claude Code. --fast: the binary stage 1 just built, which is
# the only one guaranteed to match the sources in front of us.
# ─────────────────────────────────────────────────────────────────────────────
MCP_BIN=""
resolve_mcp_bin() {
    local candidates
    if [[ $FAST -eq 1 ]]; then
        candidates=(
            "$WARN_SCRATCH/debug/memoir-mcp"
            "$ROOT/.build/debug/memoir-mcp"
            "$ROOT/build/Memoir.app/Contents/MacOS/memoir-mcp"
            "$ROOT/.build/release/memoir-mcp"
        )
    else
        candidates=(
            "$ROOT/build/Memoir.app/Contents/MacOS/memoir-mcp"
            "$ROOT/.build/release/memoir-mcp"
            "$WARN_SCRATCH/debug/memoir-mcp"
            "$ROOT/.build/debug/memoir-mcp"
        )
    fi
    local c
    for c in "${candidates[@]}"; do
        if [[ -x "$c" ]]; then MCP_BIN="$c"; return 0; fi
    done
    return 1
}

require_mcp_bin() {
    if ! resolve_mcp_bin; then
        echo "no memoir-mcp binary found. Looked in build/Memoir.app, .build/release,"
        echo ".build/debug and $WARN_SCRATCH/debug."
        echo "Build one with: swift build --product memoir-mcp"
        return 1
    fi
    echo "binary: ${MCP_BIN#$ROOT/}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 7: memoir-mcp --selftest
#
# Against a throwaway path, never the user's real database. Nothing may reach
# stdout: in selftest mode the whole conversation belongs on stderr.
# ─────────────────────────────────────────────────────────────────────────────
stage_selftest() {
    require_mcp_bin || return 1
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/memoir-verify.XXXXXX")"
    local out="$tmp/stdout" err="$tmp/stderr" rc=0
    with_timeout "$MCP_TIMEOUT" "$MCP_BIN" --selftest --db "$tmp/selftest.sqlite" > "$out" 2> "$err" || rc=$?

    tail -20 "$err" | sed 's/^/  | /'
    if [[ $rc -ne 0 ]]; then
        echo "--selftest exited $rc"
        rm -rf "$tmp"; return "$rc"
    fi
    if [[ -s "$out" ]]; then
        echo "--selftest wrote to stdout, which must stay empty outside a JSON-RPC session:"
        sed 's/^/  > /' "$out"
        rm -rf "$tmp"; return 1
    fi
    if ! grep -q "selftest complete" "$err"; then
        echo "--selftest exited 0 but never reached 'selftest complete': it did not run every tool."
        rm -rf "$tmp"; return 1
    fi
    echo "  all five tools answered; stdout stayed empty"
    rm -rf "$tmp"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 8: live MCP stdio smoke
#
# initialize + initialized + tools/list piped into the real binary. Every line it
# writes to stdout has to parse as JSON, because one stray byte silently breaks
# the client. This is CF-30 and CF-32 in miniature, on the binary we just built.
# ─────────────────────────────────────────────────────────────────────────────
stage_mcp_stdio() {
    require_mcp_bin || return 1
    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/memoir-verify.XXXXXX")"
    local out="$tmp/stdout" err="$tmp/stderr" rc=0

    printf '%s\n%s\n%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify.sh","version":"1"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
        | with_timeout "$MCP_TIMEOUT" "$MCP_BIN" --db "$tmp/smoke.sqlite" > "$out" 2> "$err" || rc=$?

    if [[ $rc -ne 0 ]]; then
        echo "memoir-mcp exited $rc while serving the handshake"
        tail -10 "$err" | sed 's/^/  | /'
        rm -rf "$tmp"; return "$rc"
    fi

    sed 's/^/  < /' "$out" | cut -c1-160
    if ! validate_mcp_stream "$out"; then
        echo "stderr said:"; tail -10 "$err" | sed 's/^/  | /'
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
}

validate_mcp_stream() {
    local out="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$out" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    lines = [l for l in fh.read().splitlines() if l.strip()]

def die(msg):
    print("MCP stream invalid: " + msg)
    sys.exit(1)

if not lines:
    die("memoir-mcp produced no stdout at all")

frames = []
for n, line in enumerate(lines, 1):
    try:
        frames.append(json.loads(line))
    except ValueError as e:
        die("stdout line %d is not JSON (%s):\n  %s" % (n, e, line[:200]))

by_id = {}
for f in frames:
    if isinstance(f, dict) and "id" in f:
        by_id[f["id"]] = f

init = by_id.get(1)
if init is None:
    die("no response to initialize (id 1)")
if init.get("jsonrpc") != "2.0":
    die("initialize response is not JSON-RPC 2.0: %r" % init.get("jsonrpc"))
if "error" in init:
    die("initialize returned an error: %r" % init["error"])
version = init.get("result", {}).get("protocolVersion")
if version != "2025-06-18":
    die("protocolVersion is %r, expected '2025-06-18'" % version)

listing = by_id.get(2)
if listing is None:
    die("no response to tools/list (id 2)")
if "error" in listing:
    die("tools/list returned an error: %r" % listing["error"])
tools = listing.get("result", {}).get("tools")
if not isinstance(tools, list) or not tools:
    die("tools/list returned no tools")
for t in tools:
    if not t.get("name"):
        die("a tool has no name: %r" % t)
    if not isinstance(t.get("inputSchema"), dict):
        die("tool %r has no JSON Schema" % t.get("name"))

print("  %d stdout line(s), all valid JSON; protocol %s; %d tools: %s"
      % (len(lines), version, len(tools), ", ".join(sorted(t["name"] for t in tools))))
PY
        return $?
    fi

    # No python3: fall back to a per-line JSON parse with plutil.
    echo "  (python3 unavailable: falling back to plutil for JSON validation)"
    local n=0 line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n=$((n + 1))
        if ! printf '%s' "$line" | plutil -lint - >/dev/null 2>&1; then
            echo "MCP stream invalid: stdout line $n is not JSON:"
            echo "  $line"
            return 1
        fi
    done < "$out"
    [[ $n -gt 0 ]] || { echo "MCP stream invalid: memoir-mcp produced no stdout at all"; return 1; }
    grep -q '"protocolVersion":"2025-06-18"' "$out" || { echo "MCP stream invalid: no protocolVersion 2025-06-18"; return 1; }
    grep -q '"tools"' "$out" || { echo "MCP stream invalid: tools/list returned no tools"; return 1; }
    echo "  $n stdout line(s), all valid JSON"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 9: privacy containment
#
# A named few files are allowed to talk to the network. If another one learns how,
# the promise in PRIVACY.md is no longer true and this run has to say so by name.
# ─────────────────────────────────────────────────────────────────────────────
# Exactly four files may open a socket, and adding a fifth has to be a decision rather than a
# diff nobody read. This stage caught LocalNetworkBrain the moment it appeared, which is the
# behaviour worth keeping: the list grows only when someone argues for it here.
#
# AnthropicBrain sends to a third party. LocalNetworkBrain sends to a machine the user owns and
# named - no account, no retention, no third party - but the bytes still leave this Mac, which
# is why it is on this list rather than exempt from it.
#
# UpdateCheck is the argued-for third, and the only one that can fire without the user asking a
# question, so it carries the burden of proof rather than a waiver. It is permitted because of
# what it is, not because it is convenient: one GET for a static JSON file, no query string, no
# body, nothing identifying the machine or even saying which version is asking - the comparison
# happens locally, in the binary. Telemetry reports on you; this asks a question. An allowlist
# that took that on trust would be worth nothing, so the entry is conditional: the extra
# assertions below fail this stage the moment the checker starts sending anything, or stops
# being counted at the send site by OutboundMonitor. FLOWS.md CF-2c is the same promise from the
# test suite's side, and PRIVACY.md states it to the user in the same words.
#
# Weather is the fourth, and the hardest of the four to justify - so here is the argument rather
# than a line in a list. It is the only request that says anything about *where* the user is,
# and the only one that fires from a surface rather than from a question: opening the journal
# triggers it. Both of those are worse properties than anything else on this list.
#
# It is allowed because the weather is the one thing the journal shows that is not already on
# this Mac, and there is no local source for it - macOS keeps none. The terms it is allowed on:
# its own switch, off by default, so nothing fires until somebody turns it on; a coordinate
# coarsened to ~11 km before it leaves, which is worth nothing to whoever receives it and
# nothing lost from the answer; no identifier, key or account attached; and counted at the send
# site like everything else. If any of that stops being true, this entry should be argued again
# rather than kept.
NETWORK_OWNERS=(
    "Sources/MemoirKit/Brain/AnthropicBrain.swift"
    "Sources/MemoirKit/Brain/LocalNetworkBrain.swift"
    "Sources/MemoirKit/Setup/UpdateCheck.swift"
    "Sources/MemoirKit/Memory/Weather.swift"
)

# The one allowlisted file that is not a brain, held to the terms it was allowed on.
UPDATE_CHECKER="Sources/MemoirKit/Setup/UpdateCheck.swift"

stage_privacy() {
    local bad=0

    # Every owner must still exist, or the check is passing because its anchor moved rather
    # than because the code is clean.
    for owner in "${NETWORK_OWNERS[@]}"; do
        if [[ ! -f "$ROOT/$owner" ]]; then
            echo "$owner does not exist. This check has lost its anchor, update NETWORK_OWNERS in verify.sh"
            return 1
        fi
    done

    # Filtered by the list above rather than by a hand-written grep per file, so NETWORK_OWNERS
    # is the only place the allowlist exists and the two cannot drift apart.
    local hits
    hits="$(grep -rnE 'URLSession|dataTask' "$ROOT/Sources" || true)"
    for owner in "${NETWORK_OWNERS[@]}"; do
        hits="$(printf '%s' "$hits" | grep -v "^$ROOT/$owner:" || true)"
    done
    if [[ -n "$hits" ]]; then
        echo "URLSession/dataTask found outside ${NETWORK_OWNERS[*]}:"
        printf '%s\n' "$hits" | sed "s|^$ROOT/|  |"
        echo
        echo "files that must not contain it:"
        printf '%s\n' "$hits" | cut -d: -f1 | sort -u | sed "s|^$ROOT/|  |"
        bad=1
    else
        for owner in "${NETWORK_OWNERS[@]}"; do
            local owner_hits
            owner_hits="$(grep -cE 'URLSession|dataTask' "$ROOT/$owner" || true)"
            echo "  URLSession/dataTask: $owner_hits reference(s) inside $owner"
        done
    fi

    # The terms UpdateCheck is on the list under. Being allowed to open a socket is not the same
    # as being allowed to say anything, and a check that only counted files would let the second
    # one change without a word.
    local checker_ok=1
    local sending
    sending="$(grep -nE 'httpBody|httpMethod|uploadTask|\.upload\(|URLQueryItem|addValue|setValue' \
        "$ROOT/$UPDATE_CHECKER" || true)"
    if [[ -n "$sending" ]]; then
        echo "$UPDATE_CHECKER sends more than the bare GET it is allowlisted for:"
        printf '%s\n' "$sending" | sed 's|^|  |'
        echo "  a body, a query string or a header of its own turns the question into a report."
        bad=1; checker_ok=0
    fi
    if ! grep -q 'OutboundMonitor.shared.record' "$ROOT/$UPDATE_CHECKER"; then
        echo "$UPDATE_CHECKER no longer records its request with OutboundMonitor:"
        echo "  it fires without the user asking, so an uncounted one makes Settings → Data a lie."
        bad=1; checker_ok=0
    fi
    if [[ $checker_ok -eq 1 ]]; then
        echo "  update check: bare GET, counted at the send site"
    fi

    # Raw sockets would slip past the URLSession grep entirely.
    local raw
    raw="$(grep -rnE 'NWConnection|^import Network|CFStreamCreatePair|Socket\(' "$ROOT/Sources" || true)"
    if [[ -n "$raw" ]]; then
        echo "raw networking found:"; printf '%s\n' "$raw" | sed "s|^$ROOT/|  |"; bad=1
    fi

    # Real SDKs only: `analyticsOptIn` and `analyticsSource` are local-only fields.
    local sdk
    sdk="$(grep -rniE 'import (PostHog|Sentry|Firebase|Mixpanel|Amplitude|Segment)|posthog\.com|sentry\.io|google-analytics' "$ROOT/Sources" || true)"
    if [[ -n "$sdk" ]]; then
        echo "telemetry SDK found:"; printf '%s\n' "$sdk" | sed "s|^$ROOT/|  |"; bad=1
    fi

    return $bad
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 10: hygiene
#
# Markers only: a TODO/FIXME comment or an unimplemented trap. Matching the bare
# word would flag RuleExtractor, which legitimately hunts for "TODO" in captured
# text. A false alarm there would train everyone to ignore this stage.
# ─────────────────────────────────────────────────────────────────────────────
stage_hygiene() {
    local pattern='(//+|/\*|\*)[[:space:]]*(TODO|FIXME|XXX|HACK|unimplemented)([^A-Za-z]|$)'
    pattern="$pattern"'|fatalError\("[[:space:]]*(TODO|FIXME|unimplemented|not implemented)'
    pattern="$pattern"'|preconditionFailure\("[[:space:]]*(TODO|FIXME|unimplemented|not implemented)'
    pattern="$pattern"'|[^A-Za-z]unimplemented\(\)'
    pattern="$pattern"'|#warning'

    local hits
    hits="$(grep -rnE "$pattern" "$ROOT/Sources" || true)"
    if [[ -n "$hits" ]]; then
        echo "unfinished work left in Sources/:"
        printf '%s\n' "$hits" | sed "s|^$ROOT/|  |"
        return 1
    fi
    echo "  no TODO / FIXME / unimplemented markers in Sources/"
}

# ─────────────────────────────────────────────────────────────────────────────
# The flow table
#
# FLOWS.md is the contract; the test names are the evidence. Reads the headings
# from one and the verdicts from the other, and reports any flow that nothing
# claims.
# ─────────────────────────────────────────────────────────────────────────────
flow_table() {
    local log="$1"
    if [[ ! -s "$log" ]]; then
        printf '  %sno test output: stage 2 never produced a log%s\n' "$YELLOW" "$OFF"
        return 0
    fi
    awk -v green="$GREEN" -v red="$RED" -v yellow="$YELLOW" -v off="$OFF" -v dim="$DIM" '
    # ---- pass 1: FLOWS.md headings ------------------------------------------
    FNR == NR {
        if ($0 ~ /^###[ \t]+CF-[0-9]+/) {
            if (match($0, /CF-[0-9]+/)) {
                id = substr($0, RSTART, RLENGTH)
                title = $0
                sub(/^###[ \t]+CF-[0-9]+[ \t]*/, "", title)
                sub(/^·[ \t]*/, "", title)
                if (!(id in known)) { order[++nflows] = id; known[id] = 1 }
                titles[id] = title
            }
        }
        next
    }
    # ---- pass 2: swift-testing verdicts -------------------------------------
    {
        # A verdict line is a status glyph, then the word Test, then the quoted
        # name, anchored, so neither the log lines the app itself writes (which
        # start with a bracket) nor a compiler diagnostic echoing the source of a
        # test can be mistaken for a result. An issue line is not a verdict.
        if (match($0, /^[^A-Za-z0-9 \t[]+ Test run with .*(passed|failed)/)) {
            runline = substr($0, RSTART, RLENGTH)
            sub(/^[^ ]+ /, "", runline)
        }
        if (!match($0, /^[^A-Za-z0-9 \t[]+ Test "[^"]*" (passed|failed|skipped)/)) next

        seg = substr($0, RSTART, RLENGTH)
        verdict = "skip"
        if (seg ~ /" passed$/) verdict = "pass"
        else if (seg ~ /" failed$/) verdict = "fail"

        name = seg
        sub(/^[^"]*"/, "", name)
        sub(/" (passed|failed|skipped)$/, "", name)

        total_seen++
        if (verdict == "fail") total_failed++

        # One test may name several flows ("CF-30 … CF-34"); credit each of them.
        rest = name
        claimed = 0
        while (match(rest, /CF-[0-9]+/)) {
            id = substr(rest, RSTART, RLENGTH)
            rest = substr(rest, RSTART + RLENGTH)
            if (!(id in known) && !(id in extra)) { extra[id] = 1; extraorder[++nextra] = id }
            counts[id]++
            if (verdict == "fail") fails[id]++
            if (verdict == "skip") skips[id]++
            claimed = 1
        }
        if (claimed) flow_tests++
        else {
            unit_tests++
            if (verdict == "fail") unit_failed++
        }
    }
    END {
        printf "  %-7s %-6s %-6s %s\n", "FLOW", "STATUS", "TESTS", "PROMISE"
        untested = 0
        for (i = 1; i <= nflows; i++) { emit(order[i], titles[order[i]]) }
        for (i = 1; i <= nextra; i++) { emit(extraorder[i], "(no ### heading in FLOWS.md)") }

        printf "\n  %s%d of %d test results carry a CF-ID; %d are unit tests%s\n",
               dim, flow_tests + 0, total_seen + 0, unit_tests + 0, off
        if (runline != "") printf "  %s%s%s\n", dim, runline, off
        if (untested > 0)
            printf "  %s%d flow(s) in FLOWS.md have no test carrying their ID%s\n", yellow, untested, off
        if (total_failed > 0)
            printf "  %s%d test result(s) failed%s\n", red, total_failed, off
    }
    function emit(id, title,   status, colour, n) {
        n = counts[id] + 0
        if (n == 0)                 { status = "NONE"; colour = yellow; untested++ }
        else if (fails[id] > 0)     { status = "FAIL"; colour = red }
        else if (skips[id] == n)    { status = "SKIP"; colour = yellow }
        else                        { status = "PASS"; colour = green }
        printf "  %-7s %s%-6s%s %-6s %s\n", id, colour, status, off, (n == 0 ? "-" : n), title
    }
    ' "$ROOT/FLOWS.md" "$log"
}

# ─────────────────────────────────────────────────────────────────────────────
# --flows: run the tests, print the table, say nothing else on stdout
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

if [[ $FLOWS_ONLY -eq 1 ]]; then
    rc=0
    with_timeout "$TEST_TIMEOUT" swift test > "$TEST_LOG" 2>&1 || rc=$?
    if [[ ! -s "$TEST_LOG" ]] || ! grep -qE 'Test run (with|started)' "$TEST_LOG"; then
        echo "verify.sh --flows: swift test produced no test output (exit $rc). See $TEST_LOG" >&2
        exit 1
    fi
    flow_table "$TEST_LOG"
    exit "$rc"
fi

# ─────────────────────────────────────────────────────────────────────────────
# The run
# ─────────────────────────────────────────────────────────────────────────────
RUN_START="$(now_ms)"
rm -f "$LOG_DIR"/*.log 2>/dev/null || true

printf '%sMemoir verification%s  %s%s%s\n' "$BOLD" "$OFF" "$DIM" "$ROOT" "$OFF"
printf '%smode: %s · generation timeout: %ss · logs: %s%s\n\n' \
    "$DIM" "$([[ $FAST -eq 1 ]] && echo 'fast (no release build, no bundle)' || echo 'full')" \
    "$MEMOIR_GENERATION_TIMEOUT" "${LOG_DIR#$ROOT/}" "$OFF"

run_stage 1-build-debug   "build (debug, warnings fatal)" stage_build_debug
run_stage 2-tests         "tests (unit + integration)"    stage_tests
run_stage 3-evals         "answer evals (seeded)"         stage_evals

if [[ $FAST -eq 1 ]]; then
    skip_stage "build (release)"
    skip_stage "app bundle"
    skip_stage "bundle sanity"
else
    run_stage 4-build-release "build (release)"            stage_build_release
    run_stage 5-app-bundle    "app bundle"                 stage_app_bundle
    run_stage 6-bundle-sanity "bundle sanity"              stage_bundle_sanity
fi

run_stage 7-selftest      "memoir-mcp --selftest"         stage_selftest
run_stage 8-mcp-stdio     "mcp stdio smoke"               stage_mcp_stdio
run_stage 9-privacy       "privacy containment"           stage_privacy
run_stage 10-hygiene      "hygiene"                       stage_hygiene

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
RUN_MS=$(( $(now_ms) - RUN_START ))

printf '%sstages%s\n' "$BOLD" "$OFF"
rule
i=0
while [[ $i -lt ${#S_NAME[@]} ]]; do
    status="${S_STATUS[$i]}"
    case "$status" in
        PASS) colour="$GREEN" ;;
        FAIL) colour="$RED" ;;
        *)    colour="$DIM" ;;
    esac
    if [[ "${S_MS[$i]}" == "-1" ]]; then dur="-"; else dur="$(fmt_ms "${S_MS[$i]}")"; fi
    printf '  %-2s %-32s %s%-4s%s %8s\n' "$((i + 1))" "${S_NAME[$i]}" "$colour" "$status" "$OFF" "$dur"
    i=$((i + 1))
done
rule
printf '  %-2s %-32s %s%-4s%s %8s\n' "" "total" "$BOLD" "" "$OFF" "$(fmt_ms "$RUN_MS")"

printf '\n%sflows%s %s(FLOWS.md ↔ test names)%s\n' "$BOLD" "$OFF" "$DIM" "$OFF"
rule
flow_table "$TEST_LOG"
rule

if [[ $FAILED -eq 1 ]]; then
    printf '\n%sVERIFICATION FAILED%s\n' "$RED$BOLD" "$OFF"
    i=0
    while [[ $i -lt ${#S_NAME[@]} ]]; do
        if [[ "${S_STATUS[$i]}" == "FAIL" ]]; then
            printf '  %s✗%s %s%s\n' "$RED" "$OFF" "${S_NAME[$i]}" \
                "$([[ -n "${S_LOG[$i]}" ]] && echo "  ${DIM}${S_LOG[$i]#$ROOT/}${OFF}")"
        fi
        i=$((i + 1))
    done
    exit 1
fi

printf '\n%sALL GREEN%s  %s%s in %s%s\n' "$GREEN$BOLD" "$OFF" "$DIM" \
    "$([[ $FAST -eq 1 ]] && echo '7 stages (fast)' || echo '10 stages')" "$(fmt_ms "$RUN_MS")" "$OFF"
