#!/usr/bin/env bash
# common.sh -- shared helper functions for k8s installer
set -euo pipefail
IFS=$'\n\t'

K8S_VERSION="1.31.0"  # apt package channel version prefix (will use k8s apt repo)
POD_CIDR="10.244.0.0/16"

log() { echo "[k8s-installer] $*"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_root() {
  if [ "$EUID" -ne 0 ]; then
    log "This script must be run with sudo or as root."
    exit 1
  fi
}

disable_swap() {
  log "Disabling swap..."
  swapoff -a || true
  sed -i.bak -r 's#(^.*swap.*$)#\#\1#' /etc/fstab || true
}

install_prereqs() {
  log "Updating apt and installing prerequisites..."
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common
}

install_containerd() {
  log "Installing containerd..."
  apt-get install -y containerd
  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml
  # enable systemd cgroup for better compatibility
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
  systemctl restart containerd
  systemctl enable containerd
}

add_kubernetes_repo() {
  log "Adding Kubernetes apt repository..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" >/etc/apt/sources.list.d/kubernetes.list
  apt-get update
}

install_kubernetes_pkgs() {
  log "Installing kubeadm, kubelet, kubectl..."
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
}

prepare_node() {
  ensure_root
  disable_swap
  install_prereqs
  install_containerd
  add_kubernetes_repo
  install_kubernetes_pkgs
}
