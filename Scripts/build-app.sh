#!/bin/bash
# Builds Memoir.app from the SwiftPM products and ad-hoc signs it.
#
# Accessibility permission is bound to the bundle ID *and* the code signature, so
# re-running this after a code change will usually invalidate the permission you
# already granted. See the README.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Memoir.app"

# The version is shared with the .mcpb manifest and the DMG file name, so it lives in one
# file rather than as a literal in each of them. Checked explicitly: a bare `.` failing
# under `set -e` aborts with nothing but a line number.
if [[ ! -f "$ROOT/Scripts/version.sh" ]]; then
    echo "build-app.sh: Scripts/version.sh is missing; it holds the version number" >&2
    exit 2
fi
# shellcheck source=version.sh
. "$ROOT/Scripts/version.sh"
VERSION="$MEMOIR_VERSION"

cd "$ROOT"

echo "==> Building release binaries"
swift build -c release

BIN="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/MemoirApp" "$APP/Contents/MacOS/Memoir"
cp "$BIN/memoir-mcp" "$APP/Contents/MacOS/memoir-mcp"

# The skill rides inside the bundle so the app can install it to ~/.claude/skills/memoir/.
# Twelve MCP tools an agent never calls are twelve tools that do not exist, and the skill is
# the half that says *when* to call them. Left in the repo it reaches only people who cloned
# the repo, which is nobody who installed from a DMG.
#
# Copied before signing, deliberately: Resources are sealed by the signature, so a skill
# added afterwards invalidates the bundle ("a sealed resource is missing or invalid").
if [[ -d "$ROOT/Skills/memoir" ]]; then
    mkdir -p "$APP/Contents/Resources/Skills"
    cp -R "$ROOT/Skills/memoir" "$APP/Contents/Resources/Skills/memoir"
    echo "  skill: Contents/Resources/Skills/memoir ($(find "$ROOT/Skills/memoir" -type f | wc -l | tr -d ' ') file(s))"
else
    # Not fatal: the app is still a working capture-and-recall product without it. But say so
    # loudly, because the symptom otherwise is an "install the skill" action that silently
    # installs an empty directory, and that looks like a bug in the app rather than the build.
    echo "  WARNING: no Skills/memoir/ in the repo. The bundle ships without the skill."
    echo "           Anything that installs it to ~/.claude/skills/ will find nothing to copy."
fi

# The icon. Also before signing, and for the same reason as the skill above.
#
# An app with no CFBundleIconFile gets the blank sheet of paper macOS hands out, and Memoir
# is asked for Accessibility, the microphone, speech and Reminders: every one of those is a
# system dialog naming an app the user is being asked to trust, next to a generic placeholder.
# Regenerate with Scripts/make-icon.sh when the mark changes.
if [[ -f "$ROOT/Assets/Memoir.icns" ]]; then
    cp "$ROOT/Assets/Memoir.icns" "$APP/Contents/Resources/Memoir.icns"
    echo "  icon: Contents/Resources/Memoir.icns"
else
    echo "  WARNING: no Assets/Memoir.icns. The bundle ships with the blank document icon."
    echo "           Run Scripts/make-icon.sh to build it from Assets/memoir-mark.svg."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>            <string>sh.memoir.app</string>
    <key>CFBundleName</key>                  <string>Memoir</string>
    <key>CFBundleDisplayName</key>           <string>Memoir</string>
    <key>CFBundleExecutable</key>            <string>Memoir</string>
    <key>CFBundleIconFile</key>              <string>Memoir</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>        <string>15.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Memoir reads the on-screen text your apps publish to macOS so it can remember what you worked on. It stays on this Mac.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Memoir reads which app is in front so it can tell your work apart.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Memoir opens the microphone only while the ask bar is listening, so you can dictate your question instead of typing it. The audio is transcribed on this Mac, is never uploaded, and is never saved to disk.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Memoir turns what you say into the text of your question using Apple's on-device speech models. Your speech is transcribed on this Mac and is never sent to Apple or anyone else.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Memoir adds the todos you write yourself to Reminders, so a deadline you set at the desk still reaches you when you are away from it. It only ever writes the ones you typed and confirmed, never anything it guessed, and it never reads the reminders you already have.</string>
    <key>NSContactsUsageDescription</key>
    <string>Memoir reads your contacts so it knows the names of the people in your life from the first day instead of learning them slowly, and re-reads them so someone you add next month is known too. Names only, read on this Mac, never uploaded, and nothing is ever written back to your address book.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Memoir reads your calendar so your memory reaches back years instead of starting empty today, and keeps reading it so it does not stop at the day you installed it. It reads what you were doing and who was there, on this Mac, never uploaded, and it never adds, changes or deletes an event.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Memoir keeps two things about each photo, the date it was taken and roughly where, so it knows the places you keep going back to. The pictures themselves are only ever shown back to you: today's appear above the journal so there is something to write about. None are copied or kept, none are uploaded, screenshots are skipped, and nothing is ever written back to your library. macOS offers no way to ask for less than the whole library, so this dialog is broader than what Memoir actually takes.</string>
    <key>NSLocationUsageDescription</key>
    <string>Only if you switch the weather on in Settings. Memoir asks macOS for an approximate location (a district, never an address), rounds it to about 11 km, and uses it to ask what the weather was on the day you are writing about. It is not stored, not written to your memory, and used for nothing else. Leave the weather switch off and Memoir never asks where you are.</string>
    <key>NSLocationAlwaysUsageDescription</key>
    <string>Only if you switch the weather on in Settings. Memoir asks macOS for an approximate location (a district, never an address), rounds it to about 11 km, and uses it to ask what the weather was on the day you are writing about. It is not stored, not written to your memory, and used for nothing else. Leave the weather switch off and Memoir never asks where you are.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (ad-hoc)"
# The hardened runtime (--options runtime, below) refuses Contacts, Calendars, Photos,
# the microphone and Apple Events outright unless the binary carries the matching
# entitlement, and it refuses SILENTLY: no prompt, and the app never appears in that
# resource's System Settings list, so there is nothing for the user to switch on.
#
# Packaging/Memoir.entitlements used to say this gate did not apply to a local ad-hoc
# build, and release.sh was the only script that passed it. That was wrong, and it cost a
# real debugging session: "Read them now" reported that nothing was granted, and the Photos
# pane had no Memoir row to grant. The gate is a property of --options runtime, not of who
# signed. Both scripts sign the same way, so both pass the same entitlements.
#
# The file itself is mostly prose and AMFI's parser rejects comments, so it goes through
# Scripts/entitlements.sh rather than to codesign directly. See that file for the error it
# produces and why the failure was silent here.
if [[ ! -f "$ROOT/Scripts/entitlements.sh" ]]; then
    echo "build-app.sh: Scripts/entitlements.sh is missing; it prepares the entitlements" >&2
    exit 2
fi
# shellcheck source=entitlements.sh
. "$ROOT/Scripts/entitlements.sh"
if ! ENTITLEMENTS="$(memoir_entitlements "$ROOT/Packaging/Memoir.entitlements" "$BUILD")"; then
    echo "build-app.sh: without entitlements the app cannot read Contacts, Calendar," >&2
    echo "              Photos or the microphone, and macOS says nothing about why." >&2
    exit 2
fi
# Sign with a STABLE identity if one exists, so macOS keeps trusting the app across
# rebuilds and Accessibility permission survives. Ad-hoc (-) changes the code hash on
# every build, which makes TCC treat each build as a brand-new app and re-prompt.
#
# The certificate's NAME is a local label in your own keychain, not anything shipped: what
# keeps the grant is the key behind it staying the same. **Set MEMOIR_SIGN_IDENTITY to whatever
# yours is called**: that is the supported way in, and neither name below will exist on your
# machine. The "Pip Local Dev" fallback is kept for the one keychain whose key predates the
# rename: looking for a label that does not exist drops silently to ad-hoc signing, which costs
# an Accessibility re-grant on every single rebuild.
SIGN_ID="${MEMOIR_SIGN_IDENTITY:-Memoir Local Dev}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID" \
    && security find-identity -v -p codesigning 2>/dev/null | grep -q "Pip Local Dev"; then
    echo "  no '$SIGN_ID' certificate; falling back to an older local key for a stable signature"
    SIGN_ID="Pip Local Dev"
fi
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    # The private key may require an interactive keychain unlock. In a background or
    # non-interactive build that dialog is never answered, codesign blocks forever and
    # then leaves a half-signed bundle behind ("code has no resources but signature
    # indicates they must be present"). Bound it, and fall back cleanly.
    echo "  signing with stable identity: $SIGN_ID"
    if perl -e 'alarm 25; exec { $ARGV[0] } @ARGV;' \
        codesign --force --deep --sign "$SIGN_ID" --options runtime --entitlements "$ENTITLEMENTS" "$APP"; then
        :
    else
        echo "  NOTE: keychain did not release the signing key (no one answered the prompt)."
        echo "        Falling back to ad-hoc. Accessibility permission will reset on this build."
        echo "        Fix permanently by allowing codesign to always access the key:"
        echo "          security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <login-password> ~/Library/Keychains/login.keychain-db"
        # A killed codesign leaves both *.cstemp files and a half-written _CodeSignature
        # behind. --force alone does not recover from that: the bundle then fails
        # verification with "a sealed resource is missing or invalid" or "code has no
        # resources but signature indicates they must be present". Strip both first.
        find "$APP" -name "*.cstemp" -delete 2>/dev/null || true
        find "$APP" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true
        codesign --force --deep --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP" || true
    fi
else
    echo "  WARNING: no stable identity '$SIGN_ID' found, falling back to ad-hoc."
    echo "           Accessibility permission will reset on every rebuild."
    codesign --force --deep --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP"
fi

echo "==> Verifying"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'

# Passing --entitlements is not proof they landed: a fallback path that forgets the flag, or
# a codesign killed mid-write, both produce a bundle that looks signed and reads nothing.
# Ask the signed bundle what it actually carries.
MISSING=""
SIGNED_ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
for key in personal-information.photos-library \
           personal-information.addressbook \
           personal-information.calendars \
           device.audio-input \
           automation.apple-events; do
    case "$SIGNED_ENTS" in
        *"com.apple.security.$key"*) ;;
        *) MISSING="$MISSING $key" ;;
    esac
done
if [[ -n "$MISSING" ]]; then
    echo "    WARNING: the signed app is missing entitlements:$MISSING"
    echo "             Under the hardened runtime those resources are refused silently:"
    echo "             no prompt, and no row in System Settings for the user to switch on."
else
    echo "    entitlements present: Photos, Contacts, Calendars, microphone, Apple Events"
fi

cat <<EOF

Built: $APP

Next:
  1. open "$BUILD"           and drag Memoir.app to /Applications
  2. Launch it. Memoir lives in the menu bar, not the dock.
  3. Grant Accessibility when asked:
     System Settings > Privacy & Security > Accessibility > add Memoir
  4. Press Option-Space anywhere to ask it something.

  If you rebuild, macOS may stop trusting the new signature. Remove Memoir from the
  Accessibility list and add it again.

  MCP server for Claude Code:
     $APP/Contents/MacOS/memoir-mcp
EOF
