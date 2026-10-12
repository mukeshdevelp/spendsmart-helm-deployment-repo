#!/usr/bin/env bash
# Read ALB DNS and app URLs from CloudFormation stack outputs (main.yml).
# Source this file or run: eval "$(bash scripts/cfn-alb-urls.sh)"
set -euo pipefail
STACK_NAME="${CFN_STACK_NAME:-spendsmart-dev}"
REGION="${AWS_REGION:-us-east-1}"

FRONTEND_PORT="${ALB_FRONTEND_PORT:-8080}"
BACKEND_PORT="${ALB_BACKEND_PORT:-8081}"
KEYCLOAK_PORT="${ALB_KEYCLOAK_PORT:-8083}"

fetch_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text 2>/dev/null | head -1
}

ALB_DNS="$(fetch_output AlbDnsName)"
if [[ -z "$ALB_DNS" || "$ALB_DNS" == "None" ]]; then
  echo "ERROR: Output AlbDnsName not found on stack ${STACK_NAME} (${REGION}). Deploy infra (Alb nested stack) first." >&2
  exit 1
fi

# Prefer stack outputs when SpendSmart module has run; else build from AlbDnsName + ports.
FRONTEND_URL="$(fetch_output FrontendUrl)"
BACKEND_URL="$(fetch_output BackendUrl)"
KEYCLOAK_URL="$(fetch_output KeycloakUrl)"

[[ -z "$FRONTEND_URL" || "$FRONTEND_URL" == "None" ]] && FRONTEND_URL="http://${ALB_DNS}:${FRONTEND_PORT}"
[[ -z "$BACKEND_URL" || "$BACKEND_URL" == "None" ]] && BACKEND_URL="http://${ALB_DNS}:${BACKEND_PORT}"
[[ -z "$KEYCLOAK_URL" || "$KEYCLOAK_URL" == "None" ]] && KEYCLOAK_URL="http://${ALB_DNS}:${KEYCLOAK_PORT}"

export ALB_DNS FRONTEND_URL BACKEND_URL KEYCLOAK_URL
export VITE_API_BASE_URL="$BACKEND_URL"
export VITE_KEYCLOAK_URL="$KEYCLOAK_URL"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Print export lines for eval "$(bash scripts/cfn-alb-urls.sh)"
  printf 'export ALB_DNS=%q\n' "$ALB_DNS"
  printf 'export FRONTEND_URL=%q\n' "$FRONTEND_URL"
  printf 'export BACKEND_URL=%q\n' "$BACKEND_URL"
  printf 'export KEYCLOAK_URL=%q\n' "$KEYCLOAK_URL"
  printf 'export VITE_API_BASE_URL=%q\n' "$VITE_API_BASE_URL"
  printf 'export VITE_KEYCLOAK_URL=%q\n' "$VITE_KEYCLOAK_URL"
else
  :
fi
