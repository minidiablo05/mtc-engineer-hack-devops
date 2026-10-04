#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

CLUSTER_ENV="${ROOT_DIR}/cluster.env"

if [[ ! -f "$CLUSTER_ENV" ]]; then
    echo "[ERROR] cluster.env not found."
    echo "Create it from the example:"
    echo "cp cluster.env.example cluster.env"
    exit 1
fi

source "$CLUSTER_ENV"

if [[ -z "${GATEWAY_HOSTNAME:-}" ]]; then
    echo "[ERROR] GATEWAY_HOSTNAME is not set in cluster.env"
    exit 1
fi


PASS=0
FAIL=0

ok() {
  echo "[OK] $1"
  PASS=$((PASS+1))
}

fail() {
  echo "[FAIL] $1"
  FAIL=$((FAIL+1))
}

echo
echo "1. Kubernetes nodes"
echo "--------------------------------------"

kubectl get nodes -o wide

NOT_READY=$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}')

if [[ -z "$NOT_READY" ]]; then
  ok "All Kubernetes nodes are Ready"
else
  fail "Some nodes are not Ready: $NOT_READY"
fi


echo
echo "2. Application pods"
echo "--------------------------------------"

kubectl get pods -n hackathon -o wide

BAD_PODS=$(kubectl get pods -n hackathon \
  --no-headers \
  | awk '$3 != "Running" {print $1}')

if [[ -z "$BAD_PODS" ]]; then
  ok "Application pods are Running"
else
  fail "Application has unhealthy pods: $BAD_PODS"
fi



echo
echo "3. GatewayClass"
echo "--------------------------------------"

kubectl get gatewayclass

if kubectl get gatewayclass nginx >/dev/null 2>&1; then
  ok "GatewayClass nginx exists"
else
  fail "GatewayClass nginx not found"
fi


echo
echo "4. Gateway"
echo "--------------------------------------"

kubectl get gateway -n hackathon

if kubectl get gateway hackathon-gateway \
  -n hackathon >/dev/null 2>&1; then
  ok "Gateway exists"
else
  fail "Gateway not found"
fi


echo
echo "5. HTTPRoute"
echo "--------------------------------------"

kubectl get httproute -n hackathon

if kubectl get httproute nginx-route \
  -n hackathon >/dev/null 2>&1; then
  ok "HTTPRoute exists"
else
  fail "HTTPRoute not found"
fi


echo
echo "6. Gateway status"
echo "--------------------------------------"

GATEWAY_PROGRAMMED=$(
  kubectl get gateway hackathon-gateway \
    -n hackathon \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' \
    2>/dev/null
)

if [[ "$GATEWAY_PROGRAMMED" == "True" ]]; then
  ok "Gateway is Programmed"
else
  fail "Gateway is not Programmed"
fi


echo
echo "7. HTTPRoute status"
echo "--------------------------------------"

ROUTE_ACCEPTED=$(
  kubectl get httproute nginx-route \
    -n hackathon \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' \
    2>/dev/null
)

ROUTE_RESOLVED=$(
  kubectl get httproute nginx-route \
    -n hackathon \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' \
    2>/dev/null
)

if [[ "$ROUTE_ACCEPTED" == "True" ]]; then
  ok "HTTPRoute is Accepted"
else
  fail "HTTPRoute is not Accepted"
fi

if [[ "$ROUTE_RESOLVED" == "True" ]]; then
  ok "HTTPRoute backend references are resolved"
else
  fail "HTTPRoute references are not resolved"
fi


echo
echo "8. TLS certificate"
echo "--------------------------------------"

kubectl get certificate -n hackathon

CERT_READY=$(
  kubectl get certificate hackathon-tls \
    -n hackathon \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null
)

if [[ "$CERT_READY" == "True" ]]; then
  ok "TLS certificate is Ready"
else
  fail "TLS certificate is not Ready"
fi


echo
echo "9. External Gateway IP"
echo "--------------------------------------"

EXTERNAL_IP=$(
  kubectl get gateway hackathon-gateway \
    -n hackathon \
    -o jsonpath='{.status.addresses[0].value}' \
    2>/dev/null
)

echo "Gateway address: ${EXTERNAL_IP:-not-found}"

if [[ -n "$EXTERNAL_IP" ]]; then
  ok "Gateway has an external address"
else
  fail "Gateway external address not found"
fi


echo
echo "10. HTTP/HTTPS application test"
echo "--------------------------------------"

if [[ -n "$EXTERNAL_IP" ]]; then

  RESPONSE=$(
    curl -k -s \
      --resolve "${GATEWAY_HOSTNAME}:443:${EXTERNAL_IP}" \
    "https://${GATEWAY_HOSTNAME}/" \
      2>/dev/null
  )

  if echo "$RESPONSE" | grep -q "Hello World"; then
    ok "HTTPS request through Gateway returned Hello World"
  else
    fail "HTTPS request through Gateway failed"
  fi

else
  fail "HTTPS test skipped because Gateway address is missing"
fi


echo
echo "11. Prometheus"
echo "--------------------------------------"

kubectl get pods -n monitoring

PROM_BAD=$(
  kubectl get pods -n monitoring \
    --no-headers \
    | awk '$3 != "Running" && $3 != "Completed" {print $1}'
)

if [[ -z "$PROM_BAD" ]]; then
  ok "Monitoring pods are healthy"
else
  fail "Some monitoring pods are unhealthy: $PROM_BAD"
fi


echo
echo "12. Loki and Fluentd"
echo "--------------------------------------"

kubectl get pods -n logging -o wide

if kubectl get daemonset fluentd \
  -n logging >/dev/null 2>&1; then

  DESIRED=$(
    kubectl get daemonset fluentd \
      -n logging \
      -o jsonpath='{.status.desiredNumberScheduled}'
  )

  READY=$(
    kubectl get daemonset fluentd \
      -n logging \
      -o jsonpath='{.status.numberReady}'
  )

  if [[ "$DESIRED" == "$READY" ]]; then
    ok "Fluentd DaemonSet is ready on all scheduled nodes"
  else
    fail "Fluentd is not ready on every scheduled node"
  fi

else
  fail "Fluentd DaemonSet not found"
fi


echo
echo "======================================"
echo " Verification completed"
echo "======================================"

echo
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
