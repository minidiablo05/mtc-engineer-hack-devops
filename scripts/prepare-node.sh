#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script with sudo:"
    echo "sudo ./scripts/prepare-node.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBERNETES_VERSION="v1.35.9"

if [[ -f "${ROOT_DIR}/versions.env" ]]; then
    source "${ROOT_DIR}/versions.env"
fi

K8S_MINOR="$(echo "${KUBERNETES_VERSION#v}" | cut -d. -f1,2)"
K8S_PATCH="${KUBERNETES_VERSION#v}"

echo
echo "Preparing node for Kubernetes ${KUBERNETES_VERSION}"
echo

echo "[1/8] Disabling swap"

swapoff -a

sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

echo "[2/8] Loading kernel modules"

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "[3/8] Configuring sysctl"

cat > /etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo "[4/8] Installing base packages"

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    gpg \
    apt-transport-https \
    containerd

echo "[5/8] Configuring containerd"

mkdir -p /etc/containerd

containerd config default > /etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' \
    /etc/containerd/config.toml

systemctl enable containerd
systemctl restart containerd

echo "[6/8] Adding Kubernetes repository"

mkdir -p /etc/apt/keyrings

rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor \
    -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /
EOF

apt-get update

echo "[7/8] Installing Kubernetes packages"

PACKAGE_VERSION="$(
    apt-cache madison kubeadm \
    | awk -v version="${K8S_PATCH}" \
      '$3 ~ "^"version"-" {print $3; exit}'
)"

if [[ -z "${PACKAGE_VERSION}" ]]; then
    echo "[ERROR] Kubernetes package ${K8S_PATCH} was not found."
    echo "Available versions:"
    apt-cache madison kubeadm
    exit 1
fi

echo "Installing package version: ${PACKAGE_VERSION}"

apt-get install -y \
    kubelet="${PACKAGE_VERSION}" \
    kubeadm="${PACKAGE_VERSION}" \
    kubectl="${PACKAGE_VERSION}"

apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo "[8/8] Verification"

echo
echo "containerd:"
containerd --version

echo
echo "kubeadm:"
kubeadm version -o short

echo
echo "kubectl:"
kubectl version --client

echo
echo "Swap:"
swapon --show

echo
echo "IP forwarding:"
sysctl net.ipv4.ip_forward

echo
echo "Node preparation completed successfully."
echo "A kubelet restart loop before kubeadm init/join is normal."
