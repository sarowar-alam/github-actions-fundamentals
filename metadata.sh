#!/usr/bin/env bash

set -euo pipefail

METADATA_URL="http://169.254.169.254/latest"

echo "🔐 Fetching IMDSv2 token..."
TOKEN=$(curl -s -X PUT "${METADATA_URL}/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

if [[ -z "$TOKEN" ]]; then
  echo "❌ Failed to retrieve IMDSv2 token"
  exit 1
fi

md() {
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "$1"
}

echo
echo "=============================="
echo "🖥️  INSTANCE METADATA"
echo "=============================="

echo "Instance ID        : $(md $METADATA_URL/meta-data/instance-id)"
echo "Instance Type      : $(md $METADATA_URL/meta-data/instance-type)"
echo "AMI ID             : $(md $METADATA_URL/meta-data/ami-id)"
echo "Hostname           : $(md $METADATA_URL/meta-data/hostname)"
echo "Local Hostname     : $(md $METADATA_URL/meta-data/local-hostname)"

echo
echo "=============================="
echo "🌍 NETWORK"
echo "=============================="

echo "Private IP         : $(md $METADATA_URL/meta-data/local-ipv4)"
echo "Public IP          : $(md $METADATA_URL/meta-data/public-ipv4 || echo 'N/A')"
echo "MAC Address        : $(md $METADATA_URL/meta-data/mac)"

echo
echo "=============================="
echo "📍 LOCATION"
echo "=============================="

echo "Availability Zone  : $(md $METADATA_URL/meta-data/placement/availability-zone)"
echo "Region             : $(md $METADATA_URL/meta-data/placement/region)"

echo
echo "=============================="
echo "🔐 IAM"
echo "=============================="

IAM_ROLE=$(md $METADATA_URL/meta-data/iam/security-credentials/ || true)

if [[ -n "$IAM_ROLE" ]]; then
  echo "IAM Role           : $IAM_ROLE"
  echo
  echo "IAM Credentials (sensitive fields redacted):"
  # Fetch credentials but redact SecretAccessKey, Token, and AccessKeyId
  # to avoid leaking live AWS credentials into CI/CD logs
  md "$METADATA_URL/meta-data/iam/security-credentials/$IAM_ROLE" \
    | sed \
        -e 's/\("SecretAccessKey"\s*:\s*"\)[^"]*"/\1****REDACTED***"/g' \
        -e 's/\("Token"\s*:\s*"\)[^"]*"/\1****REDACTED***"/g' \
        -e 's/\("AccessKeyId"\s*:\s*"\)[^"]*"/\1****REDACTED***"/g'
else
  echo "IAM Role           : None"
fi

echo
echo "=============================="
echo "📦 STORAGE"
echo "=============================="

echo "Block Devices:"
md "$METADATA_URL/meta-data/block-device-mapping/" || echo "N/A"

echo
echo "=============================="
echo "🏷️  TAGS (if enabled)"
echo "=============================="

md "$METADATA_URL/meta-data/tags/instance/" || echo "Tags not enabled"

echo
echo "=============================="
echo "📄 RAW METADATA TREE"
echo "=============================="

md "$METADATA_URL/meta-data/"
