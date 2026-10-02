#!/bin/bash
# Issue or renew the Let's Encrypt certificate for the relay domain (DNS-01 via
# DNSPod), upload it as an IAM server certificate for CloudFront China, point the
# distribution at it, and delete superseded orca-relay-* certificates.
# Safe to run daily: it does nothing until the current certificate is within
# RENEW_DAYS of expiry.
#
# Needs ~/.config/orca-selfhost/dnspod.env with Tencent_SecretId / Tencent_SecretKey.
set -euo pipefail

DOMAIN="${DOMAIN:-relay.yingchu.cloud}"
PROFILE="${PROFILE:-ychchen-china}"
REGION="${REGION:-cn-northwest-1}"
RENEW_DAYS="${RENEW_DAYS:-30}"
DISTRIBUTION_ID="${DISTRIBUTION_ID:-}"   # empty until CloudFront exists
CONF_DIR="$HOME/.config/orca-selfhost"
ACME="$HOME/.acme.sh/acme.sh"
AWS=(aws --profile "$PROFILE" --region "$REGION")

log() { echo "[$(date '+%F %T')] $*"; }

latest_cert_name() {
  "${AWS[@]}" iam list-server-certificates --path-prefix /cloudfront/ \
    --query "reverse(sort_by(ServerCertificateMetadataList[?starts_with(ServerCertificateName,'orca-relay-')],&Expiration))[0].[ServerCertificateName,Expiration]" \
    --output text
}

# IAM refuses to delete a certificate CloudFront still uses, so failures here are harmless
# and the next daily run retries once the distribution has finished deploying.
cleanup_superseded() {
  [ -n "$DISTRIBUTION_ID" ] || return 0
  local keep="$1"
  "${AWS[@]}" iam list-server-certificates --path-prefix /cloudfront/ \
    --query "ServerCertificateMetadataList[?starts_with(ServerCertificateName,'orca-relay-') && ServerCertificateName!='$keep'].ServerCertificateName" \
    --output text | tr '\t' '\n' | while read -r old; do
      [ -n "$old" ] || continue
      if "${AWS[@]}" iam delete-server-certificate --server-certificate-name "$old" 2>/dev/null; then
        log "deleted superseded $old"
      fi
    done
}

read -r current_name current_expiry < <(latest_cert_name)
if [ "$current_name" != "None" ]; then
  expiry_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${current_expiry%%[+Z]*}" +%s 2>/dev/null || date -d "$current_expiry" +%s)
  days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))
  if [ "$days_left" -gt "$RENEW_DAYS" ]; then
    log "$current_name valid for $days_left more days; nothing to do"
    cleanup_superseded "$current_name"
    exit 0
  fi
  log "$current_name expires in $days_left days; renewing"
fi

# shellcheck source=/dev/null
source "$CONF_DIR/dnspod.env"
export Tencent_SecretId Tencent_SecretKey

if [ ! -x "$ACME" ]; then
  log "installing acme.sh"
  curl -fsSL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh |
    sh -s -- --install-online --nocron -m "${ACME_EMAIL:-warren.chen830@gmail.com}" >/dev/null
fi

# CloudFront China is only known to accept RSA certificates from IAM.
"$ACME" --issue --force --server letsencrypt --dns dns_tencent -d "$DOMAIN" --keylength 2048 >/dev/null
CERT_DIR="$HOME/.acme.sh/$DOMAIN"

new_name="orca-relay-$(date +%Y%m%d%H%M)"
new_id=$("${AWS[@]}" iam upload-server-certificate --path /cloudfront/ \
  --server-certificate-name "$new_name" \
  --certificate-body "file://$CERT_DIR/$DOMAIN.cer" \
  --private-key "file://$CERT_DIR/$DOMAIN.key" \
  --certificate-chain "file://$CERT_DIR/ca.cer" \
  --query ServerCertificateMetadata.ServerCertificateId --output text)
log "uploaded $new_name ($new_id)"

if [ -n "$DISTRIBUTION_ID" ]; then
  tmp=$(mktemp)
  etag=$("${AWS[@]}" cloudfront get-distribution-config --id "$DISTRIBUTION_ID" --query ETag --output text)
  "${AWS[@]}" cloudfront get-distribution-config --id "$DISTRIBUTION_ID" --query DistributionConfig --output json |
    python3 -c "import json,sys; c=json.load(sys.stdin); c['ViewerCertificate']['IAMCertificateId']=sys.argv[1]; print(json.dumps(c))" "$new_id" > "$tmp"
  "${AWS[@]}" cloudfront update-distribution --id "$DISTRIBUTION_ID" --if-match "$etag" \
    --distribution-config "file://$tmp" >/dev/null
  rm -f "$tmp"
  log "distribution $DISTRIBUTION_ID now uses $new_name"
  cleanup_superseded "$new_name"

fi
