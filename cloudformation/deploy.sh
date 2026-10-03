#!/bin/bash
# One-shot deploy of cloudformation/orca-relay.yaml into a region's default VPC,
# then build + upload the host bundle. Re-running updates the stack and bundle.
#
# Usage: cloudformation/deploy.sh [stack-name] [region] [aws-profile]
# Env:   OWNER_EMAIL (default: git user.email), OWNER_PASSWORD (generated if unset)
set -euo pipefail

STACK="${1:-orca-relay}"
REGION="${2:-ap-east-1}"
PROFILE="${3:-default}"
HERE="$(cd "$(dirname "$0")" && pwd)"
AWS=(aws --profile "$PROFILE" --region "$REGION")

vpc=$("${AWS[@]}" ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$vpc" != "None" ] || { echo "no default VPC in $REGION; pass VpcId via the console instead" >&2; exit 1; }
az=$("${AWS[@]}" ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=instance-type,Values=t4g.small --query 'InstanceTypeOfferings[].Location' --output text |
  tr '\t' '\n' | sort | head -1)
prefix_list=$("${AWS[@]}" ec2 describe-managed-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text)
email="${OWNER_EMAIL:-$(git config user.email)}"

password_args=()
if [ -n "${OWNER_PASSWORD:-}" ]; then
  password="$OWNER_PASSWORD"
elif ! "${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
  password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
fi
# On updates an omitted parameter keeps its previous value, so the password survives re-runs.
[ -z "${password:-}" ] || password_args=("OwnerPassword=$password")

echo "==> deploying stack $STACK in $REGION (vpc $vpc, az $az, prefix list $prefix_list)"
"${AWS[@]}" cloudformation deploy \
  --stack-name "$STACK" \
  --template-file "$HERE/orca-relay.yaml" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "VpcId=$vpc" "AvailabilityZone=$az" "CloudFrontPrefixListId=$prefix_list" \
    "OwnerEmail=$email" ${password_args[@]+"${password_args[@]}"}

output() {
  "${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
bucket=$(output BundleBucket)
url=$(output RelayUrl)

echo "==> building and uploading host bundle"
"$HERE/../build-artifacts.sh" "$bucket" "$PROFILE" "$REGION"

echo
echo "Relay URL: $url"
if [ -n "${password:-}" ]; then
  echo "Sign-in password (shown once, store it now): $password"
fi
echo "The instance installs itself within a few minutes; then run:"
echo "  node smoke-test.mjs $url <password>"
echo "  ./macos/install-env.sh ${url#https://}"
