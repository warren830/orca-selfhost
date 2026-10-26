#!/bin/bash
# Build everything the host needs on this machine and upload it to S3.
# The host has no internet route (and China regions reach GitHub, npm and Docker Hub
# poorly), so it never downloads from them: it only pulls this bundle from same-region S3.
#
# Usage: ./build-artifacts.sh <s3-bucket> [aws-profile] [aws-region]
# Env:   ORCA_DIR (default ~/code/orca): a clone of stablyai/orca to build the relay from
set -euo pipefail

BUCKET="${1:?usage: build-artifacts.sh <s3-bucket> [aws-profile] [aws-region]}"
PROFILE="${2:-default}"
REGION="${3:-ap-east-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ORCA_DIR="${ORCA_DIR:-$HOME/code/orca}"
NODE_MAJOR=24
ARCH=arm64

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/orca-selfhost"
mkdir -p "$OUT/bin"

echo "==> relay (orca $(git -C "$ORCA_DIR" rev-parse --short HEAD))"
(
  cd "$ORCA_DIR/cloud"
  pnpm install --frozen-lockfile >/dev/null
  pnpm --filter @orca-cloud/postgres-schema build >/dev/null
  pnpm --filter @orca-cloud/relay-contract build >/dev/null
  pnpm --filter @orca-cloud/relay build >/dev/null
  pnpm --filter @orca-cloud/relay deploy --prod --legacy "$OUT/relay" >/dev/null
)
rm -rf "$OUT/relay/src" "$OUT/relay/node_modules/@orca-cloud"/*/src
git -C "$ORCA_DIR" rev-parse HEAD > "$OUT/relay/ORCA_COMMIT"

# Upstream combined mode only accepts assignment epoch 1, but every re-placement (e.g. a
# lease that expired while the Mac slept) bumps the epoch and locks the host out with
# relay_control_not_active. Check the stored epoch instead, as stamped cells do.
# shellcheck disable=SC2016 # the ${...} below is a JavaScript template literal
node -e '
const fs = require("fs")
const file = process.argv[1]
const from = "hello.data.assignmentEpoch === 1"
const to = "await this.assignments.verifyCellAssignment({ userId: identity.sub, relayHostId: identity.relayHostId, cellId: this.config.cellId, assignmentEpoch: hello.data.assignmentEpoch })"
const src = fs.readFileSync(file, "utf8")
if (src.split(from).length !== 2) throw new Error(`relay patch: expected one "${from}" in ${file}; upstream changed`)
fs.writeFileSync(file, src.replace(from, to))
' "$OUT/relay/dist/host-session-registry.js"
echo "    patched combined-mode assignment epoch check"

echo "==> auth"
mkdir -p "$OUT/auth"
cp "$HERE/auth/server.mjs" "$HERE/auth/package.json" "$HERE/auth/package-lock.json" "$OUT/auth/"
(cd "$OUT/auth" && npm ci --omit=dev --silent)

echo "==> node ${NODE_MAJOR} linux-${ARCH}"
NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json |
  node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(JSON.parse(s).find(r=>r.version.startsWith('v${NODE_MAJOR}.')).version))")"
curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${ARCH}.tar.xz" -o "$WORK/node.tar.xz"
curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" |
  grep " node-${NODE_VERSION}-linux-${ARCH}.tar.xz\$" | awk '{print $1"  '"$WORK"'/node.tar.xz"}' | shasum -a 256 -c - >/dev/null
tar -xJf "$WORK/node.tar.xz" -C "$WORK"
cp "$WORK/node-${NODE_VERSION}-linux-${ARCH}/bin/node" "$OUT/bin/node"
echo "    $NODE_VERSION"

cp "$HERE/host/install.sh" "$OUT/"
cp -R "$HERE/host/systemd" "$OUT/systemd"

echo "==> upload"
tar -czf "$WORK/orca-selfhost.tar.gz" -C "$WORK" orca-selfhost
aws s3 cp "$WORK/orca-selfhost.tar.gz" "s3://${BUCKET}/orca-selfhost.tar.gz" \
  --profile "$PROFILE" --region "$REGION" --only-show-errors
echo "    s3://${BUCKET}/orca-selfhost.tar.gz ($(du -h "$WORK/orca-selfhost.tar.gz" | cut -f1))"
