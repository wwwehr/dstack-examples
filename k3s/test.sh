#!/usr/bin/env bash
# Deploy a test workload to a k3s-on-dstack cluster and run smoke tests.
# Leaves the workload running so you can test manually afterward.
#
# Usage:
#   export KUBECONFIG=./k3s.yaml
#   ./test.sh k3s.example.com
#
# Prerequisites:
#   - kubectl configured (steps 1-3 in README)
#   - Wildcard cert issued (step 4 in README)

set -euo pipefail

CLUSTER_DOMAIN="${1:-${CLUSTER_DOMAIN:-}}"
if [[ -z "$CLUSTER_DOMAIN" ]]; then
  echo "Usage: $0 <cluster-domain>"
  echo "  e.g. $0 k3s.example.com"
  exit 1
fi

NGINX_HOST="nginx.${CLUSTER_DOMAIN}"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# ---------- Deploy test workload ----------

echo "==> Deploying test workload..."

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

echo "==> Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/nginx --timeout=120s

echo "==> Waiting for route propagation (15s)..."
sleep 15

# ---------- Smoke tests ----------

echo ""
echo "==> Running smoke tests..."
echo ""

# 1. HTTPS to nginx workload
echo "[HTTPS workload]"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${NGINX_HOST}/" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  pass "https://${NGINX_HOST}/ returned 200"
else
  fail "https://${NGINX_HOST}/ returned ${HTTP_CODE} (expected 200)"
fi

# 2. TLS certificate validity
echo "[TLS certificate]"
CERT_CN=$(echo | openssl s_client -servername "${NGINX_HOST}" -connect "${NGINX_HOST}:443" 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K.*' || echo "")
if [[ "$CERT_CN" == "*.${CLUSTER_DOMAIN}" ]]; then
  pass "TLS cert CN matches *.${CLUSTER_DOMAIN}"
else
  fail "TLS cert CN is '${CERT_CN}' (expected *.${CLUSTER_DOMAIN})"
fi

# 3. Evidence endpoints
echo "[Evidence endpoints]"
for path in /evidences/quote /evidences/cc_eventlog /evidences/raw_quote; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${NGINX_HOST}${path}" 2>/dev/null || echo "000")
  if [[ "$CODE" == "200" ]]; then
    pass "${path} returned 200"
  else
    fail "${path} returned ${CODE} (expected 200)"
  fi
done

# 4. k3s API server (via gateway TLS passthrough)
echo "[k3s API]"
K3S_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
if [[ -n "$K3S_SERVER" ]]; then
  API_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${K3S_SERVER}/version" 2>/dev/null || echo "000")
  if [[ "$API_CODE" == "200" ]]; then
    pass "k3s API /version returned 200"
  else
    fail "k3s API /version returned ${API_CODE} (expected 200)"
  fi
else
  fail "could not determine k3s API server from kubeconfig"
fi

# 5. kubectl works
echo "[kubectl]"
NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$NODE_STATUS" == "True" ]]; then
  pass "kubectl reports node Ready"
else
  fail "kubectl reports node status '${NODE_STATUS}' (expected True)"
fi

# ---------- Summary ----------

echo ""
TOTAL=$((PASS + FAIL))
echo "==> Results: ${PASS}/${TOTAL} passed"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Some tests failed. Check the wildcard cert and ingress logs:"
  echo "  phala ssh <app-id> -- \"docker logs dstack-dstack-ingress-1 2>&1 | tail -30\""
  exit 1
fi

echo ""
echo "==> Test workload is running. Try it yourself:"
echo "    curl https://${NGINX_HOST}/"
echo ""
echo "==> To clean up later:"
echo "    kubectl delete ingressroute.traefik.io nginx"
echo "    kubectl delete svc nginx"
echo "    kubectl delete pod nginx"
