#!/bin/bash
# Host installer (Amazon Linux 2023). Pulls the bundle from S3 and (re)starts the
# services. Idempotent: re-run it after uploading a new bundle to update in place.
set -euo pipefail

CONF=/etc/orca-selfhost
APP=/opt/orca-selfhost
DATA=/var/lib/orca-selfhost
# shellcheck source=/dev/null
source "$CONF/site.env"   # RELAY_DOMAIN|RELAY_DOMAIN_PARAM OWNER_EMAIL OWNER_PASSWORD BUNDLE_S3_URI AWS_REGION

# A CloudFront default domain only exists after the distribution (which points at
# this instance) is created, so it is published to SSM instead of user data.
if [ -n "${RELAY_DOMAIN_PARAM:-}" ]; then
  RELAY_DOMAIN="$(aws ssm get-parameter --name "$RELAY_DOMAIN_PARAM" --region "$AWS_REGION" \
    --query Parameter.Value --output text)"
fi
: "${RELAY_DOMAIN:?RELAY_DOMAIN not set}"

id orca >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /sbin/nologin orca

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
aws s3 cp "$BUNDLE_S3_URI" "$work/bundle.tar.gz" --region "$AWS_REGION" --only-show-errors
tar -xzf "$work/bundle.tar.gz" -C "$work"
rm -rf "$APP.new" && mv "$work/orca-selfhost" "$APP.new"
rm -rf "$APP.old" && { [ -d "$APP" ] && mv "$APP" "$APP.old" || true; } && mv "$APP.new" "$APP"
chmod 755 "$APP/bin/node"

mkdir -p "$DATA/relay" "$DATA/auth"
chown -R orca:orca "$DATA"
chmod 700 "$DATA"

# The relay assignment key is generated once on the host and never leaves it.
if [ ! -s "$CONF/assignment-key" ]; then
  umask 077 && openssl rand -base64 48 | tr -d '\n' > "$CONF/assignment-key"
fi

umask 077
cat > "$CONF/relay.env" <<EOF
NODE_ENV=production
PORT=8080
ORCA_RELAY_ROLE=combined
ORCA_RELAY_REGION=asia-east2
ORCA_RELAY_PUBLIC_URL=https://${RELAY_DOMAIN}
ORCA_RELAY_CELL_URL=https://${RELAY_DOMAIN}
ORCA_RELAY_AUTH_ISSUER=https://${RELAY_DOMAIN}
ORCA_RELAY_JWKS_URL=http://127.0.0.1:8787/.well-known/jwks.json
ORCA_RELAY_ASSIGNMENT_SIGNING_KEY=$(cat "$CONF/assignment-key")
ORCA_RELAY_ADMIN_AUDIENCE=https://${RELAY_DOMAIN}
ORCA_RELAY_DEPLOY_SERVICE_ACCOUNT=unused@invalid.example
ORCA_RELAY_DATA_DIR=${DATA}/relay
EOF
cat > "$CONF/auth.env" <<EOF
NODE_ENV=production
PORT=8787
AUTH_ISSUER=https://${RELAY_DOMAIN}
AUTH_DATA_DIR=${DATA}/auth
OWNER_EMAIL=${OWNER_EMAIL}
OWNER_PASSWORD=${OWNER_PASSWORD}
EOF
chmod 600 "$CONF"/*.env

cp "$APP"/systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable orca-auth orca-relay >/dev/null
systemctl restart orca-auth
systemctl restart orca-relay
echo "installed relay $(cat "$APP/relay/ORCA_COMMIT")"
