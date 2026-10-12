#!/usr/bin/env bash
# Upload Helm bastion deploy script to the CFN template bucket (bastion-assets/).
set -euo pipefail
BUCKET="${1:?usage: sync-helm-assets-to-s3.sh <cfn-template-bucket> [region]}"
REGION="${2:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="${ROOT}/scripts/helm/deploy-spendsmart-on-bastion.sh"
[[ -f "$DEPLOY" ]] || { echo "missing $DEPLOY"; exit 1; }
aws s3 cp "$DEPLOY" "s3://${BUCKET}/bastion-assets/deploy-spendsmart-on-bastion.sh" --region "$REGION"
echo "Synced deploy script to s3://${BUCKET}/bastion-assets/deploy-spendsmart-on-bastion.sh"
