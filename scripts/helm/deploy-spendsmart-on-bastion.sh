#!/bin/bash
# SpendSmart Helm + Keycloak on EKS (bastion, after infra + DB bootstrap).
# Required: GPG_KEY. Images from account ECR (mirror via mirror-harbor-to-ecr.sh first).
# Optional: AWS_REGION, EKS_CLUSTER_NAME, NAME_PREFIX, NAMESPACE, ECR_REPO_PREFIX, IMAGE_TAG,
#           ECR_REGISTRY, KEYCLOAK_ADMIN_PASSWORD, CFN_STACK_NAME, ALB_DNS

set -euo pipefail

LOG=/var/log/spendsmart-helm-deploy.log
if [[ -z "${GPG_KEY:-}" ]]; then
  echo "GPG_KEY is not set (check Jenkins spendsmart-gpg-key / deploy-spendsmart.env)" >&2
  exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER="${EKS_CLUSTER_NAME:-spendsmart}"
NAME_PREFIX="${NAME_PREFIX:-spendsmart-dev}"
NAMESPACE="${NAMESPACE:-spendsmart}"
CHART_REPO="${CHART_REPO:-https://github.com/OT-CONTAINER-KIT/helm-charts.git}"
CHART_BRANCH="${CHART_BRANCH:-feature/spendsmart-helm-chart}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-spendsmart-keycloak-admin}"
ROOT_STACK="${CFN_STACK_NAME:-spendsmart-dev}"
ECR_REPO_PREFIX="${ECR_REPO_PREFIX:-spendsmart}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

exec >>"$LOG" 2>&1

if [[ -z "${ALB_DNS:-}" ]]; then
  ALB_DNS=$(aws cloudformation describe-stacks --stack-name "$ROOT_STACK" --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue | [0]" --output text 2>/dev/null || true)
fi
[[ -n "$ALB_DNS" && "$ALB_DNS" != "None" ]] || {
  echo "ALB_DNS missing — set in deploy-spendsmart.env (run-on-bastion-via-ssm fetches from CFN using Jenkins creds)"
  exit 1
}

echo "=== deploy-spendsmart-on-bastion $(date -u +%Y-%m-%dT%H:%M:%SZ) alb=$ALB_DNS tag=$IMAGE_TAG ==="

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ECR_REGISTRY:-${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
BACKEND_REPO="${ECR_REGISTRY}/${ECR_REPO_PREFIX}/backend"
FRONTEND_REPO="${ECR_REGISTRY}/${ECR_REPO_PREFIX}/frontend"
ENGINE_REPO="${ECR_REGISTRY}/${ECR_REPO_PREFIX}/engine"

for comp in backend frontend engine; do
  if ! aws ecr describe-images --repository-name "${ECR_REPO_PREFIX}/${comp}" --region "$AWS_REGION" \
    --image-ids "imageTag=${IMAGE_TAG}" >/dev/null 2>&1; then
    echo "ECR image missing: ${ECR_REGISTRY}/${ECR_REPO_PREFIX}/${comp}:${IMAGE_TAG}"
    echo "Run mirror with same IMAGE_TAG (Jenkins RESOLVED_IMAGE_TAG=${IMAGE_TAG}) or set IMAGE_TAG=latest if you pushed latest only"
    exit 1
  fi
done
echo "ECR images OK under ${ECR_REGISTRY}/${ECR_REPO_PREFIX}/*:${IMAGE_TAG}"

dnf install -y git tar gzip python3
command -v curl >/dev/null || dnf install -y curl-minimal
command -v helm >/dev/null || {
  curl -fsSL https://get.helm.sh/helm-v3.17.3-linux-amd64.tar.gz -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
}

export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
if [[ ! -f "$KUBECONFIG" ]]; then
  KUBECONFIG=/home/ec2-user/.kube/config
fi
mkdir -p "$(dirname "$KUBECONFIG")"
aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG"

kubectl wait --for=condition=Ready node --all --timeout=900s
kubectl -n databases wait --for=condition=Ready pod -l app=clickhouse --timeout=900s

CH_JSON=$(aws secretsmanager get-secret-value --secret-id "${NAME_PREFIX}/clickhouse" --region "$AWS_REGION" --query SecretString --output text)
CHPASS=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["password"])' "$CH_JSON")
CHUSER=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["username"])' "$CH_JSON")
CHDB=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["database"])' "$CH_JSON")

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<CHSVC
apiVersion: v1
kind: Service
metadata:
  name: clickhouse
  namespace: ${NAMESPACE}
spec:
  type: ExternalName
  externalName: clickhouse.databases.svc.cluster.local
CHSVC

kubectl -n "$NAMESPACE" create secret generic encryption-key \
  --from-literal=GPG_KEY="$GPG_KEY" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create secret generic clickhouse \
  --from-literal=CLICKHOUSE_HOST=clickhouse \
  --from-literal=CLICKHOUSE_PORT=8123 \
  --from-literal=CLICKHOUSE_USER="$CHUSER" \
  --from-literal=CLICKHOUSE_PASSWORD="$CHPASS" \
  --from-literal=CLICKHOUSE_DATABASE="$CHDB" \
  --from-literal=CLICKHOUSE_TABLE=service_costs \
  --from-literal=CLICKHOUSE_TLS=false \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create secret generic clickhouse-db \
  --from-literal=CLICKHOUSE_HOST=clickhouse \
  --from-literal=CLICKHOUSE_PORT=8123 \
  --from-literal=CLICKHOUSE_USER="$CHUSER" \
  --from-literal=CLICKHOUSE_PASSWORD="$CHPASS" \
  --from-literal=CLICKHOUSE_DATABASE="$CHDB" \
  --from-literal=CLICKHOUSE_TABLE=service_costs \
  --dry-run=client -o yaml | kubectl apply -f -

API_URL="http://${ALB_DNS}:8081"
KC_URL="http://${ALB_DNS}:8083"

cat >/tmp/client-a-values.yaml <<EOF
backend:
  enabled: true
  image:
    repository: ${BACKEND_REPO}
    tag: ${IMAGE_TAG}
  nodeSelector:
    spendsmart.io/workload: backend
  service:
    type: NodePort
  annotations: {}
frontend:
  enabled: true
  image:
    repository: ${FRONTEND_REPO}
    tag: ${IMAGE_TAG}
  nodeSelector:
    spendsmart.io/workload: frontend
  service:
    type: NodePort
  configMap:
    name: uniteconpro-frontend
    data:
      VITE_API_BASE_URL: "${API_URL}"
      VITE_CLOUD_SENTRY_API_BASE_URL: ""
      VITE_KEYCLOAK_CLIENT_ID: spendsmart-frontend
      VITE_KEYCLOAK_REALM: spendsmart
      VITE_KEYCLOAK_URL: "${KC_URL}"
  nginx:
    enabled: true
    configMap:
      name: spendsmart-frontend-nginx
    csp:
      connectSrc:
        - "'self'"
        - "${API_URL}"
        - "${KC_URL}"
        - "wss:"
      frameSrc:
        - "'self'"
        - "${KC_URL}"
        - "https:"

  annotations: {}
cloudsentry:
  enabled: false
engine:
  enabled: true
  image:
    repository: ${ENGINE_REPO}
    tag: ${IMAGE_TAG}
  schedule: "5 11,23 * * *"
  nodeSelector:
    spendsmart.io/workload: backend
EOF

kubectl apply -f - <<KEYCLOAK
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      nodeSelector:
        spendsmart.io/workload: frontend
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:latest
          args: ["start-dev"]
          env:
            - name: KEYCLOAK_ADMIN
              value: admin
            - name: KEYCLOAK_ADMIN_PASSWORD
              value: "${KEYCLOAK_ADMIN_PASSWORD}"
            - name: KC_HTTP_PORT
              value: "8080"
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app: keycloak
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      nodePort: 30083
KEYCLOAK
kubectl -n "$NAMESPACE" rollout status deployment/keycloak --timeout=900s

rm -rf /opt/helm-charts
git clone --depth 1 --branch "$CHART_BRANCH" "$CHART_REPO" /opt/helm-charts
helm upgrade --install spendsmart /opt/helm-charts/charts/spendsmart \
  --namespace "$NAMESPACE" \
  --values /tmp/client-a-values.yaml \
  --wait --timeout 30m

patch_np() {
  local svc="$1" np="$2" port="$3" target="$4"
  kubectl patch svc "$svc" -n "$NAMESPACE" --type merge \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"http\",\"port\":$port,\"targetPort\":$target,\"nodePort\":$np,\"protocol\":\"TCP\"}]}}"
}
patch_np spendsmart-frontend 30080 80 80
patch_np spendsmart-backend 30081 80 8000

kubectl -n "$NAMESPACE" get deploy,svc,pods
echo "=== deploy complete ==="
