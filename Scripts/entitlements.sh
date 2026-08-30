#!/bin/bash
# Hands back an entitlements file codesign will actually accept.
#
# WHY THIS EXISTS
# ===============
# Packaging/Memoir.entitlements is mostly prose: every key carries the reasoning for why it
# is there, and there is a long header explaining which keys tccd recognises and which
# widely-cited ones do not exist. That is deliberate and worth keeping.
#
# But codesign does not parse entitlements with CFPropertyList. It hands them to AMFI, whose
# parser rejects XML comments outright:
#
#     Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 5
#
# and then exits non-zero having signed nothing. build-app.sh sent that to /dev/null, so the
# build reported success and produced an app with no entitlements at all, which under the
# hardened runtime means Contacts, Calendar, Photos and the microphone are refused silently,
# with no prompt and no row in System Settings for the user to switch on. release.sh passed
# the same file and would have failed loudly at the signing step, so nothing broken ever
# shipped; the cost was a dev build that looked fine and could not read a photo library.
#
# `plutil -convert xml1` re-serialises the parsed plist, which drops the comments and nothing
# else. So the documented file stays the source of truth, and what reaches codesign is the
# same dictionary without the prose.

# Writes a comment-free copy of the entitlements next to the build and echoes its path.
#
# $1: the documented entitlements file
# $2: a directory to write the normalised copy into
memoir_entitlements() {
    local source="$1"
    local into="$2"
    local out="$into/Memoir.normalised.entitlements"

    if [[ ! -f "$source" ]]; then
        echo "entitlements.sh: $source is missing" >&2
        return 2
    fi
    mkdir -p "$into"
    if ! plutil -convert xml1 -o "$out" "$source" 2>/dev/null; then
        echo "entitlements.sh: $source is not a readable plist" >&2
        return 2
    fi
    # A plist that parses but holds no keys would sign cleanly and grant nothing, which is
    # the failure this whole file exists to stop happening quietly.
    if ! grep -q "com.apple.security" "$out"; then
        echo "entitlements.sh: $source parsed but declares no entitlements" >&2
        return 2
    fi
    echo "$out"
}
