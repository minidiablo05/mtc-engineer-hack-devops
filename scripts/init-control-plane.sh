#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script with sudo:"
    echo "sudo ./scripts/init-control-plane.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_ENV="${ROOT_DIR}/cluster.env"

if [[ ! -f "$CLUSTER_ENV" ]]; then
    echo "[ERROR] cluster.env not found."
    echo "Create it first:"
    echo "cp cluster.env.example cluster.env"
    exit 1
fi

source "$CLUSTER_ENV"

KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.35.9}"
CALICO_VERSION="${CALICO_VERSION:-v3.33.0}"

if [[ -f "${ROOT_DIR}/versions.env" ]]; then
    source "${ROOT_DIR}/versions.env"
fi

required_vars=(
    CONTROL_PLANE_IP
    POD_CIDR
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "[ERROR] Required variable '$var' is not set."
        exit 1
    fi
done

if ! ip -4 addr show | grep -qw "${CONTROL_PLANE_IP}"; then
    echo "[ERROR] CONTROL_PLANE_IP=${CONTROL_PLANE_IP}"
    echo "is not assigned to this machine."
    echo
    ip -4 addr show
    exit 1
fi

echo
echo "Control-plane configuration"
echo "--------------------------------------"
echo "Node:               $(hostname)"
echo "Control-plane IP:   ${CONTROL_PLANE_IP}"
echo "Pod CIDR:           ${POD_CIDR}"
echo "Kubernetes:         ${KUBERNETES_VERSION}"
echo "Calico:             ${CALICO_VERSION}"
echo

if [[ ! -f /etc/kubernetes/admin.conf ]]; then

    echo "[1/5] Initializing Kubernetes control-plane"

    kubeadm init \
        --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
        --pod-network-cidr="${POD_CIDR}" \
        --kubernetes-version="${KUBERNETES_VERSION}" \
        --cri-socket="unix:///var/run/containerd/containerd.sock"

else

    echo "[1/5] Kubernetes control-plane already initialized."
    echo "Skipping kubeadm init."

fi

echo "[2/5] Configuring kubectl"

TARGET_USER="${SUDO_USER:-root}"

if [[ "$TARGET_USER" == "root" ]]; then
    TARGET_HOME="/root"
else
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi

mkdir -p "${TARGET_HOME}/.kube"

cp -f /etc/kubernetes/admin.conf \
    "${TARGET_HOME}/.kube/config"

chown -R "${TARGET_USER}:${TARGET_USER}" \
    "${TARGET_HOME}/.kube"

export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl cluster-info

echo "[3/5] Installing Calico CRDs"

kubectl apply --server-side -f \
"https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/v3_projectcalico_org-v1beta1.yaml"

echo "[4/5] Installing Tigera Operator"

kubectl apply -f \
"https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

echo "Waiting for Tigera Operator..."

kubectl rollout status \
    deployment/tigera-operator \
    -n tigera-operator \
    --timeout=300s

echo "[5/5] Configuring Calico network"

CALICO_RESOURCES="$(mktemp)"

curl -fsSL \
"https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" \
-o "$CALICO_RESOURCES"

sed -i \
    "s#cidr: 192.168.0.0/16#cidr: ${POD_CIDR}#" \
    "$CALICO_RESOURCES"

if ! grep -q "cidr: ${POD_CIDR}" "$CALICO_RESOURCES"; then
    echo "[ERROR] Failed to configure Calico Pod CIDR."
    rm -f "$CALICO_RESOURCES"
    exit 1
fi

kubectl apply -f "$CALICO_RESOURCES"

rm -f "$CALICO_RESOURCES"

echo
echo "Waiting for Calico..."

kubectl wait \
    --for=condition=Available \
    tigerastatus/calico \
    --timeout=600s

echo
kubectl get tigerastatus

echo
echo "Waiting for Kubernetes node..."

kubectl wait \
    --for=condition=Ready \
    node \
    --all \
    --timeout=600s

echo
kubectl get nodes -o wide

echo
echo "Generating worker join configuration..."

JOIN_COMMAND="$(
    kubeadm token create \
        --print-join-command
)"

JOIN_TOKEN="$(
    echo "$JOIN_COMMAND" \
    | awk '{
        for (i=1; i<=NF; i++)
            if ($i == "--token")
                print $(i+1)
    }'
)"

JOIN_CA_HASH="$(
    echo "$JOIN_COMMAND" \
    | awk '{
        for (i=1; i<=NF; i++)
            if ($i == "--discovery-token-ca-cert-hash")
                print $(i+1)
    }'
)"

cat > "${ROOT_DIR}/join.env" <<EOF
JOIN_CONTROL_PLANE_ENDPOINT=${CONTROL_PLANE_IP}:6443
JOIN_TOKEN=${JOIN_TOKEN}
JOIN_CA_HASH=${JOIN_CA_HASH}
EOF

chmod 600 "${ROOT_DIR}/join.env"

if [[ -n "${SUDO_USER:-}" ]]; then
    chown "${SUDO_USER}:${SUDO_USER}" \
        "${ROOT_DIR}/join.env"
fi

echo
echo "Worker join configuration created:"
echo "${ROOT_DIR}/join.env"

echo
echo "Worker join command:"
echo "--------------------------------------"
echo "$JOIN_COMMAND"
echo "--------------------------------------"

echo
echo "Copy join.env to each worker and run:"
echo "sudo ./scripts/join-worker.sh"
