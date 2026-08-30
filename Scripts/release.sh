#!/usr/bin/env bash
#
# Memoir's release path: Developer ID signature, notarisation, stapled DMG, .mcpb.
#
# This is NOT Scripts/build-app.sh. build-app.sh is the daily dev driver: it signs ad-hoc or
# with a local self-signed key, which is exactly right for a machine that already trusts
# itself, and exactly wrong for anyone else's Mac. The two must never collapse into one
# script, because their failure modes are opposites: build-app.sh falling back to ad-hoc is
# a small annoyance, release.sh falling back to ad-hoc is a DMG that every user's Gatekeeper
# rejects and that nobody notices until they try to open it. So: this script has no fallback.
# If there is no Developer ID identity it stops, loudly, before it builds anything.
#
#   Scripts/release.sh                 build, sign, notarise, staple, DMG, .mcpb
#   Scripts/release.sh --no-notarize   everything except the two notarisation round trips
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT YOU MUST DO ONCE, BEFORE THIS SCRIPT CAN WORK
# ─────────────────────────────────────────────────────────────────────────────
# None of this can be automated for you: it needs your own Apple credentials, and this
# script deliberately never sees them.
#
# 1. Join the Apple Developer Program ($99/year). A free Apple ID cannot issue a
#    Developer ID certificate, and Developer ID is the only kind Gatekeeper accepts for
#    software distributed outside the App Store.
#
# 2. Create a "Developer ID Application" certificate and install it in your login keychain.
#    Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application,
#    or by hand at developer.apple.com/account/resources/certificates.
#    Confirm it landed:
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#
#    EXPIRES 1 FEBRUARY 2027. The certificate signing releases today came from the legacy
#    (non-G2) intermediary, whose certificates all die on that fixed date rather than after
#    a term. Anything already notarised keeps working (every signature below is
#    --timestamp'd), but no NEW build can be signed after it. Replace it before then by
#    choosing "G2 Sub-CA" at developer.apple.com, and delete the old one from the keychain:
#    both carry the identical common name, so the preflight below cannot tell them apart and
#    will refuse as ambiguous.
#
# 3. Create an app-specific password for notarisation at appleid.apple.com
#    (Sign-In and Security > App-Specific Passwords). Your real Apple ID password will
#    not work and should never be typed into a terminal.
#
# 4. Store all three in the keychain, ONCE, so nothing sensitive ever reaches this script,
#    your shell history, or CI logs:
#
#        xcrun notarytool store-credentials "memoir-notary" \
#            --apple-id "you@example.com" \
#            --team-id "YOURTEAMID" \
#            --password "abcd-efgh-ijkl-mnop"
#
#    After this, notarisation needs only the profile NAME, which is not a secret.
#
# Then `bash Scripts/release.sh` is the whole release.
#
# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION: all of it from the environment, none of it hardcoded
# ─────────────────────────────────────────────────────────────────────────────
#   MEMOIR_RELEASE_IDENTITY   codesign identity. Default: the sole "Developer ID
#                             Application" identity in the keychain. Required only when
#                             there is more than one and the choice is ambiguous.
#   MEMOIR_NOTARY_PROFILE     notarytool keychain profile name. Default: memoir-notary
#
# No Apple ID, no Team ID and no password appears in this file, is read by it, or is printed
# by it. The identity string ends in "(TEAMID)", so even that is redacted before it is
# echoed: a build log ends up pasted into issue reports more often than anyone plans for.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
cd "$ROOT"

if [[ ! -f "$ROOT/Package.swift" ]]; then
    echo "release.sh: no Package.swift at $ROOT. Is this script still inside the repo?" >&2
    exit 2
fi
if [[ ! -f "$ROOT/Scripts/version.sh" ]]; then
    echo "release.sh: Scripts/version.sh is missing. It holds the version number" >&2
    exit 2
fi
# shellcheck source=version.sh
. "$ROOT/Scripts/version.sh"
VERSION="$MEMOIR_VERSION"

DIST="$ROOT/dist"
APP="$DIST/Memoir.app"
# Through the normaliser, not straight to codesign: the documented file carries comments and
# AMFI's parser refuses them. Here that produced a hard failure at the signing step rather
# than a silent one, which is why nothing broken ever shipped. See Scripts/entitlements.sh.
if [[ ! -f "$ROOT/Scripts/entitlements.sh" ]]; then
    echo "release.sh: Scripts/entitlements.sh is missing. It prepares the entitlements" >&2
    exit 2
fi
# shellcheck source=entitlements.sh
. "$ROOT/Scripts/entitlements.sh"
ENTITLEMENTS="$(memoir_entitlements "$ROOT/Packaging/Memoir.entitlements" "$DIST")"
NOTARY_PROFILE="${MEMOIR_NOTARY_PROFILE:-memoir-notary}"
DMG="$DIST/Memoir-$VERSION.dmg"
DMG_STAGE="$DIST/dmg-stage"
ZIP="$DIST/Memoir-$VERSION.zip"
VOLNAME="Memoir $VERSION"

NOTARIZE=1
for arg in "$@"; do
    case "$arg" in
        --no-notarize) NOTARIZE=0 ;;
        -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||'; exit 0 ;;
        *) echo "release.sh: unknown option '$arg' (want --no-notarize or --help)" >&2; exit 2 ;;
    esac
done

die() { echo; echo "release.sh: $*" >&2; exit 1; }

# The identity string is "Developer ID Application: Some Name (AB12CD34EF)". The trailing
# parenthesis is the Team ID, which is not ours to print.
redact() { printf '%s' "${1%% (*}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Preflight
#
# Everything checkable is checked before `swift build -c release`, which is several minutes
# long. Discovering a missing certificate after the build is a bad trade, and discovering a
# missing notary profile after the build AND the signing is a worse one.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Preflight"

for tool in codesign xcrun hdiutil ditto plutil swift; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not on PATH. Install the Xcode command-line tools."
done
xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool is missing. It needs Xcode 13 or later."
xcrun --find stapler   >/dev/null 2>&1 || die "xcrun stapler is missing. It needs the Xcode command-line tools."
[[ -f "$ENTITLEMENTS" ]] || die "no entitlements at $ENTITLEMENTS"
plutil -lint "$ENTITLEMENTS" >/dev/null || die "$ENTITLEMENTS is not a valid plist"
echo "    entitlements: ${ENTITLEMENTS#$ROOT/}"

# The whole reason this script exists separately. `security find-identity` prints one line
# per identity; we want only Developer ID Application, and we want to be certain which.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' || true)"

if [[ -n "${MEMOIR_RELEASE_IDENTITY:-}" ]]; then
    IDENTITY="$MEMOIR_RELEASE_IDENTITY"
    # Trust it but say what happened, so a typo does not read as "the keychain is broken".
    if ! printf '%s\n' "$IDENTITIES" | grep -Fqx "$IDENTITY"; then
        echo "    NOTE: MEMOIR_RELEASE_IDENTITY is not one of the Developer ID Application"
        echo "          identities found in the keychain. Passing it to codesign anyway."
    fi
elif [[ -z "$IDENTITIES" ]]; then
    cat >&2 <<'EOF'

release.sh: no "Developer ID Application" certificate in this keychain.

This is the release path, and it has no ad-hoc fallback on purpose. An ad-hoc signature is
fine for Scripts/build-app.sh, which is building for the machine that just built it. Shipped
in a DMG it produces "Memoir.app is damaged and can't be opened" on every other Mac, a
message that blames the download rather than the build, so it is reported as a corrupt file
and the real cause is never found. Better to stop here.

Check what you have:
    security find-identity -v -p codesigning

You need a line reading "Developer ID Application: <your name> (<team id>)". Getting one
requires a paid Apple Developer Program membership and your own Apple ID. It cannot be
scripted, and this script will not try. See the header of this file for the four one-time
steps.

For local development, use the path that is meant for it:
    bash Scripts/build-app.sh
EOF
    exit 1
else
    COUNT="$(printf '%s\n' "$IDENTITIES" | grep -c . || true)"
    if [[ "$COUNT" -gt 1 ]]; then
        echo "    found $COUNT Developer ID Application identities:" >&2
        printf '%s\n' "$IDENTITIES" | while IFS= read -r line; do
            [[ -n "$line" ]] && echo "      $(redact "$line") (…)" >&2
        done
        die "ambiguous. Pick one explicitly:
    MEMOIR_RELEASE_IDENTITY='Developer ID Application: …' bash Scripts/release.sh"
    fi
    IDENTITY="$IDENTITIES"
fi
echo "    identity: $(redact "$IDENTITY") (…)"

if [[ $NOTARIZE -eq 1 ]]; then
    echo "    notary profile: $NOTARY_PROFILE"
else
    echo "    notarisation: SKIPPED (--no-notarize)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Build and assemble
#
# Reusing build-app.sh rather than duplicating the assembly. It owns Info.plist, and an
# Info.plist that exists twice is one that disagrees with itself the first time a usage
# string changes. A missing usage string is invisible until TCC kills the process in
# front of a user. Its ad-hoc/dev signature is irrelevant: everything below re-signs with
# --force, which replaces a signature outright.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Building the app bundle"
bash "$ROOT/Scripts/build-app.sh" | sed 's/^/    /'

[[ -d "$ROOT/build/Memoir.app" ]] || die "build-app.sh did not produce build/Memoir.app"

echo "==> Staging a release copy"
mkdir -p "$DIST"
rm -rf "$APP" "$DMG_STAGE" "$ZIP" "$DMG"
# ditto, not cp -R: cp does not reliably carry extended attributes and symlink structure, and
# a bundle that arrives subtly altered fails signing later with a message about sealed
# resources that points nowhere near the copy that caused it.
ditto "$ROOT/build/Memoir.app" "$APP"
echo "    ${APP#$ROOT/}"

# ─────────────────────────────────────────────────────────────────────────────
# Clean the bundle before signing
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Cleaning pre-signing detritus"

# "resource fork, Finder information, or similar detritus not allowed" is codesign's way of
# saying an extended attribute rode along: com.apple.quarantine and com.apple.FinderInfo
# are the usual two, and both arrive without anyone doing anything unusual.
xattr -cr "$APP"

# build-app.sh bounds codesign with an alarm because an unanswered keychain prompt hangs it
# forever; when that fires it leaves *.cstemp files and a half-written _CodeSignature behind.
# --force does not recover from that: the bundle then fails verification with "a sealed
# resource is missing or invalid". Strip both so this run starts from an unsigned bundle.
find "$APP" -name "*.cstemp" -delete 2>/dev/null || true
find "$APP" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
echo "    extended attributes and any prior signature removed"

# ─────────────────────────────────────────────────────────────────────────────
# Sign, inside out
#
# --deep is NOT used, and its absence is the point. Apple deprecated it for signing: it
# applies the SAME entitlements to every nested binary, so memoir-mcp (a read-only SQLite
# reader that needs no microphone, no Apple Events and no Reminders) would be signed asking
# for all three. That is both a broader attack surface than the binary needs and a thing a
# notarisation reviewer can reasonably object to. --deep is a repair tool for ad-hoc
# re-signing, not a distribution step.
#
# So: nested code first, outermost last, each with its own entitlements.
#
# --timestamp is on every call. Without a secure timestamp notarisation rejects the upload
# ("The signature does not include a secure timestamp"), and the round trip is minutes long,
# so the mistake is expensive to make twice.
# ─────────────────────────────────────────────────────────────────────────────
sign() {
    local what="$1"; shift
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@" "$what"
}

echo "==> Signing memoir-mcp (no entitlements: it needs none)"
sign "$APP/Contents/MacOS/memoir-mcp"

echo "==> Signing the main executable"
sign "$APP/Contents/MacOS/Memoir" --entitlements "$ENTITLEMENTS"

echo "==> Signing the bundle"
# Signing the bundle re-signs the main executable and seals Contents/Resources, including
# Skills/memoir, which build-app.sh copied in before this point precisely so it would be
# sealed rather than appended to a signed bundle.
sign "$APP" --entitlements "$ENTITLEMENTS"

echo "==> Verifying the signature"
# --strict --deep here is fine and wanted: on VERIFY, --deep means "check nested code too".
# It is only on SIGN that it is deprecated. Different flag, same spelling.
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Timestamp|Runtime|Format|Sealed)" | sed 's/^/    /' || true

# Prove the entitlements actually attached. A typo in the plist path is silently survivable:
# codesign is happy, the app launches, and the microphone simply never works.
echo "==> Confirming entitlements landed"
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null || true)"
for key in com.apple.security.device.audio-input \
           com.apple.security.automation.apple-events \
           com.apple.security.personal-information.calendars; do
    if printf '%s' "$ENTS" | grep -q "$key"; then
        echo "    ok       $key"
    else
        die "the signed bundle is missing $key: dictation or Reminders will fail silently for every user"
    fi
done
# The one that must NOT be there.
if printf '%s' "$ENTS" | grep -q "com.apple.security.app-sandbox"; then
    die "the bundle is sandboxed. The sandbox makes other apps' accessibility trees unreadable, which is the whole product."
fi
echo "    ok       not sandboxed"

# ─────────────────────────────────────────────────────────────────────────────
# Notarise the app
#
# Two round trips happen in this script, and the reason for the first one is easy to skip.
# Stapling only the DMG leaves the app itself ticketless: it works while the DMG is the thing
# being opened, and then fails for the user who copies the app to a machine that is offline,
# because Gatekeeper falls back to asking Apple and cannot. Staple both.
# ─────────────────────────────────────────────────────────────────────────────
notarize() {
    local path="$1" label="$2"
    echo "==> Notarising the $label (this waits on Apple; minutes, not seconds)"
    if ! xcrun notarytool submit "$path" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait 2>&1 | sed 's/^/    /'; then
        cat >&2 <<EOF

Notarisation of the $label failed.

If it could not find the credentials, the keychain profile "$NOTARY_PROFILE" does not exist
yet. Create it once. It stores your Apple ID, Team ID and app-specific password in the
keychain so they never appear in a script or a shell history:

    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
        --apple-id "<your Apple ID>" \\
        --team-id "<your Team ID>" \\
        --password "<app-specific password from appleid.apple.com>"

If it was rejected instead, ask Apple what it objected to. The log names the exact binary
and reason, which is almost always a missing --timestamp or a nested binary signed with the
wrong identity:

    xcrun notarytool log <submission-id> --keychain-profile "$NOTARY_PROFILE"
EOF
        exit 1
    fi
}

if [[ $NOTARIZE -eq 1 ]]; then
    echo "==> Packing the app for notarisation"
    # ditto -c -k --keepParent, not `zip`. The notary service needs the bundle structure
    # intact, and /usr/bin/zip mangles symlinks and resource forks inside an .app. --keepParent
    # keeps Memoir.app as the archive's top-level directory, which is what the service expects.
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "    ${ZIP#$ROOT/} ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"

    notarize "$ZIP" "app"

    echo "==> Stapling the ticket to the app"
    # Stapled onto the .app, not the .zip: the zip was only ever a transport for the upload.
    xcrun stapler staple "$APP" 2>&1 | sed 's/^/    /'
    rm -f "$ZIP"
fi

# ─────────────────────────────────────────────────────────────────────────────
# The DMG
#
# hdiutil, no third-party dependency. create-dmg is the usual reach here and it is a whole
# extra install to place one icon; a folder containing the app and a symlink to /Applications
# is the interaction everybody already knows.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Building the DMG"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
# ditto again: this copy happens AFTER signing and stapling, so anything that drops an
# extended attribute here breaks a signature that verified a moment ago.
ditto "$APP" "$DMG_STAGE/Memoir.app"
ln -s /Applications "$DMG_STAGE/Applications"

# A volume left mounted from an interrupted earlier run makes hdiutil fail with "Resource
# temporarily unavailable", which reads like a disk problem rather than a stale mount.
if [[ -d "/Volumes/$VOLNAME" ]]; then
    echo "    detaching a stale /Volumes/$VOLNAME"
    hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true
fi

rm -f "$DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG" | sed 's/^/    /'
rm -rf "$DMG_STAGE"

echo "==> Signing the DMG"
# No --options runtime here: the hardened runtime is a property of executable code, and a disk
# image is not. It still needs a timestamp to notarise.
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=1 "$DMG" 2>&1 | sed 's/^/    /'

if [[ $NOTARIZE -eq 1 ]]; then
    notarize "$DMG" "DMG"

    echo "==> Stapling the ticket to the DMG"
    xcrun stapler staple "$DMG" 2>&1 | sed 's/^/    /'

    echo "==> Gatekeeper assessment"
    # The real question: not "is it signed" but "would this Mac open it from a download".
    # source=Notarized Developer ID is the line to look for.
    spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /' || true
    spctl --assess --type exec -vv "$APP" 2>&1 | sed 's/^/    /' || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# The .mcpb bundle
#
# Built against the path the DMG installs to, not against build/, so the manifest describes
# where the app will actually live once someone drags it out of this DMG.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Building the .mcpb bundle"
MEMOIR_MCP_PATH="/Applications/Memoir.app/Contents/MacOS/memoir-mcp" \
    bash "$ROOT/Scripts/make-mcpb.sh" --allow-missing | sed 's/^/    /'

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "==> Released"
echo "    $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "    $DIST/memoir.mcpb"
if [[ $NOTARIZE -eq 0 ]]; then
    cat <<'EOF'

    WARNING: --no-notarize. This DMG is signed but NOT notarised and NOT stapled.
             Gatekeeper will refuse it on any Mac that did not build it. Do not publish it.
EOF
else
    cat <<EOF

    Signed with Developer ID, notarised by Apple, and stapled: the app and the DMG both,
    so it opens on a Mac that is offline.

    Verify the way a user would, on another Mac:
        spctl --assess --type open --context context:primary-signature -vv "$(basename "$DMG")"
EOF
fi
