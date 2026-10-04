#!/usr/bin/env bash

set -Eeuo pipefail

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


KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.35.9}"
METALLB_VERSION="${METALLB_VERSION:-v0.16.1}"
NGF_VERSION="${NGF_VERSION:-2.7.2}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"
PROM_STACK_VERSION="${PROM_STACK_VERSION:-91.9.0}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-7.3.0}"

if [[ -f "${ROOT_DIR}/versions.env" ]]; then
    source "${ROOT_DIR}/versions.env"
fi

required_vars=(
    CONTROL_PLANE_IP
    POD_CIDR
    METALLB_POOL_START
    METALLB_POOL_END
    GATEWAY_HOSTNAME
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "[ERROR] Required variable '$var' is not set in cluster.env"
        exit 1
    fi
done

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

info() {
    echo "[INFO] $1"
}

ok() {
    echo "[OK] $1"
}

die() {
    echo "[ERROR] $1" >&2
    exit 1
}

wait_for_crd() {
    local crd="$1"

    info "Waiting for CRD: ${crd}"

    kubectl wait \
        --for=condition=Established \
        "crd/${crd}" \
        --timeout=180s
}

section "[0/10] Preliminary checks"

for cmd in kubectl helm curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "Required command '${cmd}' is not installed."
    fi
done

info "Checking Kubernetes API..."

kubectl cluster-info >/dev/null 2>&1 \
    || die "Kubernetes API is unavailable."

ok "Kubernetes API is reachable."

kubectl get nodes -o wide

NOT_READY="$(
    kubectl get nodes \
        --no-headers \
        | awk '$2 != "Ready" {print $1}'
)"

if [[ -n "$NOT_READY" ]]; then
    echo "Nodes not Ready:"
    echo "$NOT_READY"
    die "All Kubernetes nodes must be Ready before deployment."
fi

ok "All Kubernetes nodes are Ready."

section "[1/10] Installing MetalLB ${METALLB_VERSION}"

kubectl apply -f \
"https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

wait_for_crd "ipaddresspools.metallb.io"
wait_for_crd "l2advertisements.metallb.io"

info "Waiting for MetalLB controller..."

kubectl rollout status \
    deployment/controller \
    -n metallb-system \
    --timeout=300s

info "Waiting for MetalLB speakers..."

kubectl rollout status \
    daemonset/speaker \
    -n metallb-system \
    --timeout=300s

ok "MetalLB is ready."

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: hackathon-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_POOL_START}-${METALLB_POOL_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: hackathon-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - hackathon-pool
EOF

kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system

section "[2/10] Installing Gateway API CRDs"

kubectl kustomize \
"https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v${NGF_VERSION}" \
| kubectl apply -f -

wait_for_crd "gatewayclasses.gateway.networking.k8s.io"
wait_for_crd "gateways.gateway.networking.k8s.io"
wait_for_crd "httproutes.gateway.networking.k8s.io"

ok "Gateway API CRDs are ready."

section "[3/10] Installing NGINX Gateway Fabric ${NGF_VERSION}"

helm upgrade --install ngf \
    oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
    --version "${NGF_VERSION}" \
    --namespace nginx-gateway \
    --create-namespace \
    --wait \
    --timeout 5m

kubectl rollout status \
    deployment/ngf-nginx-gateway-fabric \
    -n nginx-gateway \
    --timeout=300s

kubectl get pods -n nginx-gateway -o wide

ok "NGINX Gateway Fabric is ready."

section "[4/10] Installing cert-manager ${CERT_MANAGER_VERSION}"

helm upgrade --install cert-manager \
    oci://quay.io/jetstack/charts/cert-manager \
    --version "${CERT_MANAGER_VERSION}" \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --set config.gatewayAPI.enabled=true \
    --wait \
    --timeout 5m

wait_for_crd "certificates.cert-manager.io"
wait_for_crd "issuers.cert-manager.io"
wait_for_crd "clusterissuers.cert-manager.io"

kubectl rollout status \
    deployment/cert-manager \
    -n cert-manager \
    --timeout=300s

kubectl rollout status \
    deployment/cert-manager-webhook \
    -n cert-manager \
    --timeout=300s

kubectl rollout status \
    deployment/cert-manager-cainjector \
    -n cert-manager \
    --timeout=300s

kubectl get pods -n cert-manager

ok "cert-manager is ready."

section "[5/10] Deploying application"

kubectl apply -f "${ROOT_DIR}/k8s/app/"

kubectl rollout status \
    deployment/nginx \
    -n hackathon \
    --timeout=300s

kubectl get pods -n hackathon -o wide
kubectl get svc -n hackathon

ok "Application is ready."

section "[6/10] Deploying TLS resources"

kubectl apply -f "${ROOT_DIR}/k8s/tls/selfsigned-issuer.yaml"

sed "s/__GATEWAY_HOSTNAME__/${GATEWAY_HOSTNAME}/g" \
    "${ROOT_DIR}/k8s/tls/certificate.yaml" \
    | kubectl apply -f -

if ! kubectl wait \
    --for=condition=Ready \
    certificate/hackathon-tls \
    -n hackathon \
    --timeout=180s; then

    kubectl describe certificate hackathon-tls -n hackathon || true
    die "TLS certificate was not issued."
fi

kubectl get certificate -n hackathon
kubectl get secret hackathon-tls -n hackathon

ok "TLS certificate is ready."

section "[7/10] Deploying Gateway and HTTPRoute"

sed "s/__GATEWAY_HOSTNAME__/${GATEWAY_HOSTNAME}/g" \
    "${ROOT_DIR}/k8s/gateway/gateway.yaml" \
    | kubectl apply -f -

kubectl apply -f "${ROOT_DIR}/k8s/gateway/httproute.yaml"

if ! kubectl wait \
    --for=condition=Programmed \
    gateway/hackathon-gateway \
    -n hackathon \
    --timeout=300s; then

    kubectl describe gateway hackathon-gateway -n hackathon || true
    die "Gateway did not become Programmed."
fi

sleep 5

kubectl get gateway -n hackathon -o wide
kubectl get httproute -n hackathon

GATEWAY_IP="$(
    kubectl get gateway hackathon-gateway \
        -n hackathon \
        -o jsonpath='{.status.addresses[0].value}' \
        2>/dev/null || true
)"

if [[ -z "$GATEWAY_IP" ]]; then
    die "Gateway has no external address."
fi

ok "Gateway external IP: ${GATEWAY_IP}"

section "[8/10] Installing Prometheus and Grafana"

helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts \
    --force-update

helm repo update

helm upgrade --install monitoring \
    prometheus-community/kube-prometheus-stack \
    --version "${PROM_STACK_VERSION}" \
    --namespace monitoring \
    --create-namespace \
    --wait \
    --timeout 10m

kubectl get pods -n monitoring

ok "Prometheus and Grafana are deployed."

section "[9/10] Installing Loki ${LOKI_CHART_VERSION}"

helm repo add grafana \
    https://grafana.github.io/helm-charts \
    --force-update

helm repo update

helm upgrade --install loki \
    grafana/loki \
    --version "${LOKI_CHART_VERSION}" \
    --namespace logging \
    --create-namespace \
    --values "${ROOT_DIR}/k8s/loki/values.yaml" \
    --wait \
    --timeout 10m

kubectl get pods -n logging

ok "Loki is deployed."

section "[10/10] Deploying Fluentd"

kubectl apply -f "${ROOT_DIR}/k8s/logging/"

kubectl rollout status \
    daemonset/fluentd \
    -n logging \
    --timeout=300s

kubectl get pods -n logging -o wide

ok "Fluentd is ready."

section "Configuring Loki datasource for Grafana"

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-loki-datasource
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki-gateway.logging.svc.cluster.local
        isDefault: false
        editable: true
EOF

ok "Loki datasource configuration applied."

section "Final smoke tests"

kubectl get nodes -o wide
kubectl get pods -n hackathon -o wide
kubectl get gateway -n hackathon -o wide
kubectl get httproute -n hackathon
kubectl get certificate -n hackathon
kubectl get pods -n monitoring
kubectl get pods -n logging -o wide

info "Testing HTTPS through Gateway..."

HTTPS_RESPONSE="$(
    curl -k -s --max-time 15 \
  --resolve "${GATEWAY_HOSTNAME}:443:${GATEWAY_IP}" \
  "https://${GATEWAY_HOSTNAME}/" \
        || true
)"

if echo "$HTTPS_RESPONSE" | grep -q "Hello World"; then
    ok "HTTPS Gateway test passed."
else
    echo "Gateway response:"
    echo "$HTTPS_RESPONSE"

    kubectl get pods -n nginx-gateway -o wide || true
    kubectl get pods -n hackathon -o wide || true

    die "HTTPS Gateway smoke test failed."
fi

info "Testing Kubernetes API connectivity from inside cluster..."

kubectl run deployment-api-test \
    --image=curlimages/curl \
    --restart=Never \
    --rm \
    -i \
    --command \
    -- \
    sh -c '
        CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
        --max-time 10 https://10.96.0.1:443/api || true)

        echo "Kubernetes API HTTP status: ${CODE}"

        case "$CODE" in
            200|401|403)
                exit 0
                ;;
            *)
                exit 1
                ;;
        esac
    '

ok "Kubernetes API is reachable from Pods."

section "DEPLOYMENT COMPLETED SUCCESSFULLY"

echo "Kubernetes: ${KUBERNETES_VERSION}"
echo "MetalLB: ${METALLB_VERSION}"
echo "NGINX Gateway Fabric: ${NGF_VERSION}"
echo "cert-manager: ${CERT_MANAGER_VERSION}"
echo "kube-prometheus-stack: ${PROM_STACK_VERSION}"
echo "Loki Helm chart: ${LOKI_CHART_VERSION}"
echo "Gateway IP: ${GATEWAY_IP}"
echo
echo "HTTPS test:"
echo "curl -k --resolve ${GATEWAY_HOSTNAME}:443:${GATEWAY_IP} https://${GATEWAY_HOSTNAME}/"
echo
echo "SUCCESS"
