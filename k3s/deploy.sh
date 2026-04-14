#!/usr/bin/env bash
# Deploy k3s on dstack and set up kubectl access.
#
# Usage:
#   export CLOUDFLARE_API_TOKEN=xxx
#   export CERTBOT_EMAIL=you@example.com
#   ./deploy.sh k3s.example.com
#
# Prerequisites:
#   - phala CLI installed and authenticated (phala auth login)
#   - kubectl and jq installed

set -euo pipefail

CLUSTER_DOMAIN="${1:-${CLUSTER_DOMAIN:-}}"
CVM_NAME="${CVM_NAME:-my-k3s}"
INSTANCE_TYPE="${INSTANCE_TYPE:-tdx.medium}"
DISK_SIZE="${DISK_SIZE:-50G}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-k3s.yaml}"

if [[ -z "$CLUSTER_DOMAIN" ]]; then
  echo "Usage: $0 <cluster-domain>"
  echo "  e.g. $0 k3s.example.com"
  echo ""
  echo "Required env vars:"
  echo "  CLOUDFLARE_API_TOKEN   Cloudflare API token (Zone:Read + DNS:Edit)"
  echo "  CERTBOT_EMAIL          Email for Let's Encrypt registration"
  echo ""
  echo "Optional env vars:"
  echo "  CVM_NAME               CVM name (default: my-k3s)"
  echo "  INSTANCE_TYPE          Instance type (default: tdx.medium)"
  echo "  DISK_SIZE              Disk size (default: 50G)"
  echo "  KUBECONFIG_FILE        Output kubeconfig path (default: k3s.yaml)"
  exit 1
fi

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required}"

for cmd in phala kubectl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd is required but not found"; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Step 1: Deploy the CVM ----------

echo "==> Deploying CVM '${CVM_NAME}'..."
phala deploy \
  -n "$CVM_NAME" \
  -c "${SCRIPT_DIR}/docker-compose.yaml" \
  -t "$INSTANCE_TYPE" \
  --disk-size "$DISK_SIZE" \
  --dev-os \
  -e "CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}" \
  -e "CERTBOT_EMAIL=${CERTBOT_EMAIL}" \
  -e "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}" \
  --wait

# ---------- Step 2: Extract APP_ID and GATEWAY_DOMAIN ----------

echo "==> Fetching CVM info..."
CVM_JSON=$(phala cvms get "$CVM_NAME" --json 2>/dev/null)
APP_ID=$(echo "$CVM_JSON" | jq -r '.app_id')
GATEWAY_DOMAIN=$(echo "$CVM_JSON" | jq -r '.gateway.base_domain')

echo "    App ID:         ${APP_ID}"
echo "    Gateway domain: ${GATEWAY_DOMAIN}"

# ---------- Step 3: Wait for SSH and extract kubeconfig ----------

echo "==> Waiting for CVM to boot (this takes 2-3 minutes)..."
for i in $(seq 1 30); do
  if phala ssh "$APP_ID" -- "echo ok" >/dev/null 2>&1; then
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "Error: SSH not available after 5 minutes"
    exit 1
  fi
  sleep 10
done

echo "==> Extracting kubeconfig..."
for i in $(seq 1 12); do
  if phala ssh "$APP_ID" -- \
    "docker exec dstack-k3s-1 cat /etc/rancher/k3s/k3s.yaml" \
    2>/dev/null > "$KUBECONFIG_FILE" && [[ -s "$KUBECONFIG_FILE" ]]; then
    break
  fi
  if [[ $i -eq 12 ]]; then
    echo "Error: could not extract kubeconfig after 2 minutes"
    exit 1
  fi
  sleep 10
done

# Rewrite API server URL to use the gateway TLS passthrough endpoint
sed -i "s|https://127.0.0.1:6443|https://${APP_ID}-6443s.${GATEWAY_DOMAIN}|" "$KUBECONFIG_FILE"

export KUBECONFIG="${KUBECONFIG_FILE}"

# ---------- Step 4: Wait for node Ready ----------

echo "==> Waiting for k3s node to become Ready..."
for i in $(seq 1 30); do
  STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$STATUS" == "True" ]]; then
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "Error: node not Ready after 5 minutes"
    exit 1
  fi
  sleep 10
done

echo "==> Node is Ready:"
kubectl get nodes

# ---------- Step 5: Wait for wildcard certificate ----------

echo "==> Waiting for wildcard TLS certificate (this takes 5-8 minutes)..."
CERT_TEST_URL="https://test.${CLUSTER_DOMAIN}/"
for i in $(seq 1 60); do
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$CERT_TEST_URL" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" != "000" ]]; then
    echo "    Certificate is ready (got HTTP ${HTTP_CODE})"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "Warning: certificate not ready after 10 minutes, continuing anyway"
    break
  fi
  sleep 10
done

# ---------- Step 6: Deploy test workload ----------

echo "==> Deploying nginx test workload..."
NGINX_HOST="nginx.${CLUSTER_DOMAIN}"

kubectl run nginx --image=nginx:alpine --port=80 --restart=Never 2>/dev/null || true
kubectl expose pod nginx --port=80 --target-port=80 --name=nginx 2>/dev/null || true

kubectl apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: nginx
spec:
  entryPoints: [web]
  routes:
    - match: Host(\`${NGINX_HOST}\`)
      kind: Rule
      services:
        - name: nginx
          port: 80
EOF

kubectl wait --for=condition=Ready pod/nginx --timeout=120s
sleep 10

# ---------- Smoke test ----------

echo ""
echo "==> Smoke test..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${NGINX_HOST}/" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  echo "    PASS: https://${NGINX_HOST}/ returned 200"
else
  echo "    WARN: https://${NGINX_HOST}/ returned ${HTTP_CODE} (cert may still be propagating)"
fi

# ---------- Done ----------

echo ""
echo "============================================"
echo "  k3s on dstack is ready!"
echo "============================================"
echo ""
echo "  Kubeconfig:  export KUBECONFIG=$(pwd)/${KUBECONFIG_FILE}"
echo "  kubectl:     kubectl get nodes"
echo "  Test URL:    https://${NGINX_HOST}/"
echo "  Evidence:    https://${NGINX_HOST}/evidences/quote"
echo ""
echo "  To clean up:"
echo "    kubectl delete ingressroute.traefik.io nginx && kubectl delete svc nginx && kubectl delete pod nginx"
echo "    echo y | phala cvms delete ${CVM_NAME} && rm ${KUBECONFIG_FILE}"
