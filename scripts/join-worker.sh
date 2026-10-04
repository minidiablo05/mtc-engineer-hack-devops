#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script with sudo:"
    echo "sudo ./scripts/join-worker.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

JOIN_ENV="${ROOT_DIR}/join.env"

if [[ ! -f "$JOIN_ENV" ]]; then
    echo "[ERROR] join.env not found."
    echo
    echo "Generate it on the control-plane using:"
    echo "sudo ./scripts/init-control-plane.sh"
    echo
    echo "Then copy join.env to this worker."
    exit 1
fi

source "$JOIN_ENV"

required_vars=(
    JOIN_CONTROL_PLANE_ENDPOINT
    JOIN_TOKEN
    JOIN_CA_HASH
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "[ERROR] Required variable '$var' is missing from join.env"
        exit 1
    fi
done

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    echo "[INFO] This node already appears to be joined to Kubernetes."
    echo
    echo "/etc/kubernetes/kubelet.conf already exists."
    exit 0
fi

echo
echo "Joining Kubernetes cluster"
echo "--------------------------------------"
echo "Node:          $(hostname)"
echo "Control-plane: ${JOIN_CONTROL_PLANE_ENDPOINT}"
echo

systemctl is-active --quiet containerd || {
    echo "[ERROR] containerd is not running."
    exit 1
}

echo "[1/2] Joining cluster"

kubeadm join "${JOIN_CONTROL_PLANE_ENDPOINT}" \
    --token "${JOIN_TOKEN}" \
    --discovery-token-ca-cert-hash "${JOIN_CA_HASH}" \
    --cri-socket="unix:///var/run/containerd/containerd.sock"

echo "[2/2] Checking kubelet"

systemctl restart kubelet

if systemctl is-active --quiet kubelet; then
    echo "[OK] kubelet is running."
else
    echo "[ERROR] kubelet is not running."
    systemctl status kubelet --no-pager
    exit 1
fi

echo
echo "Worker successfully joined the Kubernetes cluster."
echo
echo "Verify it on the control-plane:"
echo "kubectl get nodes -o wide"
