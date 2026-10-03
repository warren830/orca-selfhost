#!/bin/bash
# Make the Orca desktop app always use the self-hosted relay, however it is launched
# (Dock, Spotlight, open -a). Orca reads its cloud endpoints only from the environment,
# so a LaunchAgent sets them in the user launchd session at every login.
#
# Usage: macos/install-env.sh <relay-domain>     e.g. dxxxx.cloudfront.net
#        macos/install-env.sh --uninstall        back to the official Orca Cloud relay
set -euo pipefail

LABEL=com.orca-selfhost.env
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
VARS=(ORCA_CLOUD_API_URL ORCA_CLOUD_CLIENT_ID ORCA_RELAY_URL)

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$PLIST"
  for v in "${VARS[@]}"; do launchctl unsetenv "$v"; done
  echo "Removed. Quit Orca (Cmd+Q) and reopen it to return to the official relay."
  exit 0
fi

DOMAIN="${1:?usage: install-env.sh <relay-domain> | --uninstall}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%/}"

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>/bin/launchctl setenv ORCA_CLOUD_API_URL https://$DOMAIN; /bin/launchctl setenv ORCA_CLOUD_CLIENT_ID orca-desktop; /bin/launchctl setenv ORCA_RELAY_URL https://$DOMAIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST
plutil -lint -s "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1
for v in "${VARS[@]}"; do echo "$v=$(launchctl getenv "$v")"; done
echo "Done. Quit Orca (Cmd+Q) once and reopen it normally; it will use https://$DOMAIN from now on."
