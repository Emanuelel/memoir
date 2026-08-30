#!/usr/bin/env bash
# Build Memoir and install it to /Applications, preserving its Accessibility grant.
#
# Why this is not `rm -rf && cp -R`: deleting the bundle and recreating it makes macOS
# treat the result as a brand-new app and drop its TCC entries, so every deploy cost a
# trip to System Settings. `ditto` overwrites the bundle in place, which keeps the
# identity. Combined with the stable "Memoir Local Dev" signing identity (whose designated
# requirement is cert-based rather than hash-based), the grant survives a rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEST="/Applications/Memoir.app"

echo "==> building"
bash Scripts/build-app.sh

echo "==> quitting running instance"
osascript -e 'quit app "Memoir"' 2>/dev/null || true
sleep 2
pkill -f "$DEST/Contents/MacOS/Memoir" 2>/dev/null || true
sleep 1

echo "==> installing"
# A clean replace, deliberately. `ditto` was used here to preserve the Accessibility
# grant, but it MERGES rather than replaces: a stale *.cstemp from an interrupted
# codesign survived every deploy, verification then failed, and the self-heal re-signed
# ad-hoc, silently throwing away the certificate signature and, with it, the grant.
#
# Now that signing uses a stable identity, the designated requirement is anchored to the
# certificate rather than to the binary's hash, so the grant survives the bundle being
# replaced outright. Copy exactly; never re-sign at deploy time.
rm -rf "$DEST"
cp -R build/Memoir.app "$DEST"

if ! codesign --verify --verbose=1 "$DEST" 2>&1 | grep -q "satisfies its Designated Requirement"; then
    echo "    ERROR: installed bundle does not verify. Not launching." >&2
    codesign --verify --verbose=1 "$DEST" 2>&1 | sed 's/^/      /' >&2
    exit 1
fi

REQ="$(codesign -d -r- "$DEST" 2>&1 | grep designated || true)"
if [[ "$REQ" == *cdhash* ]]; then
    echo "    WARNING: signed ad-hoc (hash-based identity)."
    echo "             Accessibility will reset on every rebuild. Fix with:"
    echo "               security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db"
else
    echo "    signature: stable (certificate-anchored)"
fi

echo "==> launching"
# Stamped before the launch so the health check below can tell this run's log lines
# from every previous run's. Same format the logger writes, so a string compare works.
LAUNCH_TS="$(date '+%Y-%m-%d %H:%M:%S')"
# Never inherit a test-only generation timeout into the real app.
env -u MEMOIR_GENERATION_TIMEOUT open "$DEST"
sleep 5

if pgrep -f "$DEST/Contents/MacOS/Memoir" > /dev/null; then
    echo "    running: $(pgrep -f "$DEST/Contents/MacOS/Memoir" | head -1)"
else
    echo "    WARNING: not running"
    exit 1
fi

LOG="$HOME/Library/Application Support/Memoir/logs/memoir.log"

# Read only the lines this launch wrote. Continuation lines (the extractor logs
# multi-line payloads) carry no timestamp, so they inherit the decision made for
# the line above them.
since_launch() {
    awk -v since="$LAUNCH_TS" '
        substr($0, 1, 1) == "[" && substr($0, 2, 1) ~ /[0-9]/ {
            keep = (substr($0, 2, 19) >= since)
        }
        keep
    ' "$LOG" 2>/dev/null
}

# This used to grep `tail -20` for "capture loop starting", and it was wrong in the
# most damaging direction: a working capture loop writes thousands of lines in the
# five seconds this script sleeps (3,491 were measured on one launch), so the line
# it was looking for had already scrolled a long way out of that window. The check
# therefore failed *because* capture was healthy, and then printed a confident
# "Accessibility permission is NOT granted" — sending someone to fix a problem they
# did not have. Twice, on this machine.
#
# So: prove health from this run's own lines, and only claim the permission is
# missing when the app itself says so. Anything else is reported as not-yet-known,
# which is what it is.
STARTED="$(since_launch | grep 'capture loop starting' | tail -1 || true)"
DENIED="$(since_launch | grep 'Accessibility permission not granted' | tail -1 || true)"

if [[ -n "$STARTED" ]]; then
    echo "    capture: ${STARTED#*CaptureLoop.swift] }"
elif [[ -n "$DENIED" ]]; then
    echo ""
    echo "    Accessibility permission is NOT granted. Capture is not running."
    echo "    System Settings > Privacy & Security > Accessibility > enable Memoir"
    echo "    (the menu bar icon shows a warning triangle until it is)"
else
    echo "    capture: no verdict yet (the app logged neither start nor refusal in ${LAUNCH_TS}+5s)"
    echo "    The menu bar icon is the authority: green means it is logging."
fi
