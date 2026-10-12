#!/usr/bin/env bash
# Test Harbor reachability + credentials (run on PC or Jenkins agent where docker runs).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -f "${ROOT}/deploy/harbor.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT}/deploy/harbor.env"
  set +a
fi

HARBOR_SERVER="${HARBOR_SERVER:-harbor.ldc.opstree.dev}"
TEST_IMAGE="${HARBOR_SERVER}/coe/uniteconpro-backend-prod:${HARBOR_TEST_TAG:-latest}"

echo "=== 1) DNS / TCP ==="
if ! getent hosts "$HARBOR_SERVER" >/dev/null; then
  echo "FAIL: cannot resolve $HARBOR_SERVER"
  exit 1
fi
getent hosts "$HARBOR_SERVER"

if ! curl -fsS --connect-timeout 8 "https://${HARBOR_SERVER}/v2/" >/dev/null 2>&1; then
  echo "NOTE: GET /v2/ without auth may return 401 — checking with credentials next"
  curl -vk --connect-timeout 8 "https://${HARBOR_SERVER}/v2/" 2>&1 | tail -5 || true
fi

echo "=== 2) Credentials ==="
: "${HARBOR_USERNAME:?Set HARBOR_USERNAME (or deploy/harbor.env)}"
: "${HARBOR_PASSWORD:?Set HARBOR_PASSWORD}"

echo "User: ${HARBOR_USERNAME}"
echo "If this is a robot, name must match Harbor UI exactly (e.g. robot\$coe+my-robot)"

echo "=== 3) Harbor API auth (curl) ==="
HTTP=$(curl -sS -o /tmp/harbor-v2.json -w '%{http_code}' --connect-timeout 10 \
  -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" "https://${HARBOR_SERVER}/v2/")
echo "HTTP ${HTTP}"
head -c 200 /tmp/harbor-v2.json 2>/dev/null; echo
case "$HTTP" in
  200|401) ;;
  403) echo "FAIL: 403 — user exists but forbidden; check project coe permissions"; exit 1 ;;
  000) echo "FAIL: cannot reach Harbor (VPN/office network?)"; exit 1 ;;
  *) echo "FAIL: unexpected HTTP $HTTP — wrong password or username"; exit 1 ;;
esac

echo "=== 4) docker login ==="
command -v docker >/dev/null || { echo "docker not installed"; exit 1; }
printf '%s' "$HARBOR_PASSWORD" | docker login "$HARBOR_SERVER" -u "$HARBOR_USERNAME" --password-stdin

echo "=== 5) docker pull (coe project) ==="
docker pull "$TEST_IMAGE"
echo "OK: Harbor login and pull work for ${TEST_IMAGE}"
