#!/bin/bash
# Launch the installed Orca desktop app against the self-hosted auth + relay.
# Quit Orca first: a running instance would just receive the launch and keep its old endpoints.
set -euo pipefail

# Auth and relay share one CloudFront domain, split by path at the ALB.
RELAY_DOMAIN="${RELAY_DOMAIN:-relay.yingchu.cloud}"

if pgrep -xq Orca; then
  echo "Orca is running; quit it (Cmd+Q) and run this again." >&2
  exit 1
fi

export ORCA_CLOUD_API_URL="https://${RELAY_DOMAIN}"
export ORCA_CLOUD_CLIENT_ID="orca-desktop"
export ORCA_RELAY_URL="https://${RELAY_DOMAIN}"

nohup /Applications/Orca.app/Contents/MacOS/Orca >/dev/null 2>&1 &
echo "Orca started with auth=${ORCA_CLOUD_API_URL} relay=${ORCA_RELAY_URL}"
