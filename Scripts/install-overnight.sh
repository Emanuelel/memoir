#!/usr/bin/env bash
#
# Memoir: schedule the overnight deep pass.
#
# Installs a LaunchAgent that runs `memoir-ask --overnight` once a night. The pass reads
# the last day of captures with whatever model you point it at, which for the case this
# exists to serve is a big model on a machine you own.
#
#   Scripts/install-overnight.sh                       3am, Qwen on the address you set
#   Scripts/install-overnight.sh --hour 4              a different hour
#   Scripts/install-overnight.sh --uninstall           stop it
#
# The model's address is the consent, exactly as it is for `memoir-ask --brain localNetwork`:
# nothing leaves this Mac until you name the machine it goes to. Set it before installing.
#
#   export MEMOIR_LOCAL_URL=http://your-machine.local:1234/v1
#   export MEMOIR_LOCAL_MODEL=qwen3-30b-a3b-instruct-2507-mlx
#
# The values are baked into the plist at install time rather than read from your shell,
# because launchd does not have your shell. Re-run this script after changing them.
#
set -euo pipefail

LABEL="com.memoir.overnight"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HOUR=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hour) HOUR="$2"; shift 2 ;;
    --uninstall)
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
      rm -f "$PLIST"
      echo "Overnight pass removed. Nothing is scheduled any more."
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/release/memoir-ask"
if [[ ! -x "$BIN" ]]; then
  echo "memoir-ask is not built yet. Run: swift build -c release" >&2
  exit 1
fi

if [[ -z "${MEMOIR_LOCAL_URL:-}" ]]; then
  cat >&2 <<'MSG'
MEMOIR_LOCAL_URL is not set, so the pass would fall back to the on-device model, which is
the small one, and reading a whole day with it is the thing nobody would wait for.

Set the address of the machine running your model first:

  export MEMOIR_LOCAL_URL=http://your-machine.local:1234/v1
  export MEMOIR_LOCAL_MODEL=qwen3-30b-a3b-instruct-2507-mlx

Then run this again. Pass --brain appleOnDevice by hand if you really do want the small one.
MSG
  exit 1
fi

LOGS="$HOME/Library/Application Support/Memoir/logs"
mkdir -p "$LOGS" "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>--overnight</string>
    <string>--days</string><string>1</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MEMOIR_LOCAL_URL</key><string>${MEMOIR_LOCAL_URL}</string>
    <key>MEMOIR_LOCAL_MODEL</key><string>${MEMOIR_LOCAL_MODEL:-local-model}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$HOUR</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <!-- Runs on wake if the Mac was asleep at the scheduled hour, which it usually was.
       Without this the pass silently never runs on a laptop that sleeps at night. -->
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$LOGS/overnight.log</string>
  <key>StandardErrorPath</key><string>$LOGS/overnight.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Overnight pass scheduled for ${HOUR}:00 daily."
echo "  model:  ${MEMOIR_LOCAL_MODEL:-local-model} at ${MEMOIR_LOCAL_URL}"
echo "  log:    $LOGS/overnight.log"
echo
echo "It reports into the health check. Run 'memoir-ask --doctor' any time to see"
echo "when it last ran and whether the model actually answered."
