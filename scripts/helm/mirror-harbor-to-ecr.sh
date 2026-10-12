#!/usr/bin/env bash
# Pull SpendSmart images from Harbor (machine with Harbor access) and push to ECR.
# Required: docker, aws CLI, HARBOR_USERNAME, HARBOR_PASSWORD (Harbor robot or user with pull on project coe).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -f "${ROOT}/deploy/harbor.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT}/deploy/harbor.env"
  set +a
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
HARBOR_SERVER="${HARBOR_SERVER:-harbor.ldc.opstree.dev}"
HARBOR_TAG="${HARBOR_TAG:-latest}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
ECR_REPO_PREFIX="${ECR_REPO_PREFIX:-spendsmart}"

: "${HARBOR_USERNAME:?HARBOR_USERNAME is required (Jenkins harbor-creds or export before running)}"
: "${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"

echo "Harbor login: ${HARBOR_SERVER} user=${HARBOR_USERNAME}"
if ! printf '%s' "$HARBOR_PASSWORD" | docker login "$HARBOR_SERVER" -u "$HARBOR_USERNAME" --password-stdin 2>&1; then
  echo ""
  echo "Harbor login failed. Fix:"
  echo "  1) PC par: cp deploy/harbor.env.example deploy/harbor.env  (robot token, NOT LDAP password unless UI login works)"
  echo "  2) bash scripts/helm/verify-harbor-login.sh"
  echo "  3) Robot name copy from Harbor → Projects → coe → Robot Accounts (full name robot\$coe+...)"
  echo "  4) Jenkins harbor-creds: Username with password; username mein \$ include karo"
  exit 1
fi

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ECR_REGISTRY:-${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com}"

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

mirror_one() {
  local component="$1" harbor_image="$2"
  local ecr_repo="${ECR_REPO_PREFIX}/${component}"
  local src="${harbor_image}:${HARBOR_TAG}"
  local dst="${ECR_REGISTRY}/${ecr_repo}:${IMAGE_TAG}"

  aws ecr describe-repositories --repository-names "$ecr_repo" --region "$AWS_REGION" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$ecr_repo" --region "$AWS_REGION" >/dev/null

  echo "=== ${src} -> ${dst} ==="
  if ! docker pull "$src"; then
    echo "Harbor pull failed (unauthorized?). User needs pull on project coe for ${harbor_image}"
    echo "On a machine with Harbor access, test: docker pull ${src}"
    exit 1
  fi
  docker tag "$src" "$dst"
  docker push "$dst"
  if [[ "$IMAGE_TAG" != "latest" ]]; then
    local latest_dst="${ECR_REGISTRY}/${ecr_repo}:latest"
    docker tag "$src" "$latest_dst"
    docker push "$latest_dst"
  fi
}

mirror_one backend "${HARBOR_SERVER}/coe/uniteconpro-backend-prod"
mirror_one frontend "${HARBOR_SERVER}/coe/uniteconpro-frontend-prod"
mirror_one engine "${HARBOR_SERVER}/coe/uniteconpro-engine-dev"

echo "Done. ECR images (tag ${IMAGE_TAG}):"
echo "  ${ECR_REGISTRY}/${ECR_REPO_PREFIX}/backend:${IMAGE_TAG}"
echo "  ${ECR_REGISTRY}/${ECR_REPO_PREFIX}/frontend:${IMAGE_TAG}"
echo "  ${ECR_REGISTRY}/${ECR_REPO_PREFIX}/engine:${IMAGE_TAG}"
