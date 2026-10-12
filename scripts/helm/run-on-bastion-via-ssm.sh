#!/usr/bin/env bash
# Run deploy script on bastion via SSM. Set GPG_KEY, IMAGE_TAG, etc. in caller env.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
STACK="${CFN_STACK_NAME:-spendsmart-dev}"
BUCKET="${CFN_TEMPLATE_BUCKET:-spendsmart-cfn-packages}"
INSTANCE_ID="${BASTION_INSTANCE_ID:-}"

if [[ -z "$INSTANCE_ID" ]]; then
  INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='BastionInstanceId'].OutputValue | [0]" --output text)
fi
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] || { echo "BastionInstanceId not found"; exit 1; }

SCRIPT_LOCAL="${1:-${ROOT}/scripts/helm/deploy-spendsmart-on-bastion.sh}"
REMOTE_NAME="$(basename "$SCRIPT_LOCAL")"

[[ -n "${GPG_KEY:-}" ]] || { echo "GPG_KEY must be set in caller environment (Jenkins spendsmart-gpg-key)"; exit 1; }

if [[ -z "${ALB_DNS:-}" ]]; then
  ALB_DNS=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue | [0]" --output text)
fi
[[ -n "$ALB_DNS" && "$ALB_DNS" != "None" ]] || { echo "AlbDnsName not found for stack $STACK"; exit 1; }
echo "ALB_DNS=$ALB_DNS (passed to bastion via deploy-spendsmart.env)"

ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT
{
  echo "export AWS_REGION=$(printf '%q' "$REGION")"
  echo "export CFN_STACK_NAME=$(printf '%q' "$STACK")"
  echo "export CFN_TEMPLATE_BUCKET=$(printf '%q' "$BUCKET")"
  for v in EKS_CLUSTER_NAME NAME_PREFIX NAMESPACE ECR_REPO_PREFIX IMAGE_TAG ECR_REGISTRY \
    GPG_KEY KEYCLOAK_ADMIN_PASSWORD ALB_DNS; do
    if [[ -n "${!v:-}" ]]; then
      echo "export ${v}=$(printf '%q' "${!v}")"
    fi
  done
} >"$ENV_FILE"

aws s3 cp "$SCRIPT_LOCAL" "s3://${BUCKET}/bastion-assets/${REMOTE_NAME}" --region "$REGION"
aws s3 cp "$ENV_FILE" "s3://${BUCKET}/bastion-assets/deploy-spendsmart.env" --region "$REGION"

CMD_ID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" --region "$REGION" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[
    \"aws s3 cp s3://${BUCKET}/bastion-assets/${REMOTE_NAME} /tmp/${REMOTE_NAME} --region ${REGION}\",
    \"aws s3 cp s3://${BUCKET}/bastion-assets/deploy-spendsmart.env /tmp/deploy-spendsmart.env --region ${REGION}\",
    \"chmod +x /tmp/${REMOTE_NAME}\",
    \"sudo bash -c 'set -a && source /tmp/deploy-spendsmart.env && set +a && bash /tmp/${REMOTE_NAME}' || { echo '--- tail /var/log/spendsmart-helm-deploy.log ---'; sudo tail -120 /var/log/spendsmart-helm-deploy.log 2>/dev/null || true; exit 1; }\"
  ]" \
  --query 'Command.CommandId' --output text)

echo "SSM CommandId: $CMD_ID (instance $INSTANCE_ID)"
for _ in $(seq 1 120); do
  sleep 15
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'Status' --output text 2>/dev/null || echo Pending)
  echo "  status=$STATUS"
  case "$STATUS" in
    Success)
      aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --region "$REGION" \
        --query 'StandardOutputContent' --output text | tail -40
      exit 0
      ;;
    Failed|Cancelled|TimedOut)
      aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --region "$REGION" \
        --query '[StandardOutputContent,StandardErrorContent]' --output text
      exit 1
      ;;
  esac
done
echo "Timed out waiting for SSM"
exit 1
