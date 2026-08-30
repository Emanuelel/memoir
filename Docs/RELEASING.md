# Releasing Memoir

Moved out of `README.md`: this is maintainer detail, and it was a third of the front page.

## Releasing

`Scripts/build-app.sh` builds for the machine that just built it. `Scripts/release.sh` builds
for everybody else, and the two are separate on purpose: an ad-hoc signature is a small
annoyance locally and a fatal one in a DMG, where it surfaces as *"Memoir.app is damaged and
can't be opened"*, a message that blames the download rather than the build. **`release.sh`
has no ad-hoc fallback.** With no Developer ID certificate it stops before it builds anything.

```bash
bash Scripts/release.sh
```

Hardened runtime and `--options runtime --timestamp` throughout, inner binaries signed before
the bundle (not `--deep`, which is deprecated for signing and would hand `memoir-mcp` the
app's microphone and Reminders entitlements), then `notarytool submit --wait`, `stapler
staple`, a `hdiutil` DMG with an `/Applications` symlink, and `dist/memoir.mcpb`. The app and
the DMG are both stapled, so the app still opens on a Mac that is offline.

### What you have to do once, first

None of it can be scripted: it needs your own Apple credentials, and `release.sh` never sees
them.

1. **Join the Apple Developer Program** ($99/year). A free Apple ID cannot issue a Developer
   ID certificate, and Developer ID is the only kind Gatekeeper accepts outside the App Store.
2. **Create a "Developer ID Application" certificate** and install it in your login keychain:
   Xcode → Settings → Accounts → Manage Certificates → **+** → Developer ID Application. Check
   it landed with `security find-identity -v -p codesigning`.
3. **Create an app-specific password** at [appleid.apple.com](https://appleid.apple.com) →
   Sign-In and Security → App-Specific Passwords. Your real password will not work.
4. **Store all three in the keychain, once**, so nothing sensitive ever reaches a script, a
   shell history or a CI log:

   ```bash
   xcrun notarytool store-credentials "memoir-notary" \
       --apple-id "you@example.com" --team-id "YOURTEAMID" \
       --password "abcd-efgh-ijkl-mnop"
   ```

After that, `bash Scripts/release.sh` is the whole release. Two environment variables, both
optional: `MEMOIR_RELEASE_IDENTITY` (needed only if you hold more than one Developer ID) and
`MEMOIR_NOTARY_PROFILE` (default `memoir-notary`). No Apple ID, Team ID or password appears in
any script, and the identity string is redacted before it is printed, because it ends in your
Team ID and build logs get pasted into issue reports.

### Entitlements

`Packaging/Memoir.entitlements` is three keys, and the file explains at length why it is only
three. Under the hardened runtime TCC refuses a protected resource when the entitlement is
absent, and refuses it *silently*: the app never appears in the System Settings list, so the
user sees a feature that does nothing. That failure cannot happen in the ad-hoc dev build,
which means only someone opening the DMG can discover it.

| Key | For |
|---|---|
| `com.apple.security.automation.apple-events` | reading which app is frontmost |
| `com.apple.security.device.audio-input` | dictation into the ask bar |
| `com.apple.security.personal-information.calendars` | writing confirmed todos to Reminders |

Accessibility has **no** entitlement: widely-repeated advice to declare
`com.apple.security.accessibility` is a stale App Sandbox artefact, and `tccd` does not
recognise the key. Nor does Memoir declare the App Sandbox: it makes other apps'
accessibility trees unreadable, which would end the product rather than harden it.

---

