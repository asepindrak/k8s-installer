#!/usr/bin/env bash
# master.sh -- prepare master node and run 'kubeadm init'
set -euo pipefail
IFS=$'\n\t'

# This script expects to be run as root (sudo). It will:
# - prepare the node (containerd, kubeadm packages)
# - kubeadm init with a default pod network CIDR (Flannel default)
# - install flannel CNI
# - create /root/kubeadm-join.sh containing the join command for workers

SCRIPTDIR="$(dirname "$0")"
source "$SCRIPTDIR/common.sh" || source "/usr/local/bin/common.sh"

MASTER_IP=""
POD_CIDR="${POD_CIDR}"
KUBEADM_EXTRA_ARGS=""

usage() {
  cat <<EOF
Usage: sudo ./master.sh [--apiserver-advertise-address <ip>] [--pod-cidr <cidr>] [--kubeadm-args "..."]

Options:
  --apiserver-advertise-address  IP address the API Server will advertise (default: auto)
  --pod-cidr                    Pod network CIDR (default: ${POD_CIDR})
  --kubeadm-args                Extra args to pass to kubeadm init
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apiserver-advertise-address) MASTER_IP="$2"; shift 2;;
    --pod-cidr) POD_CIDR="$2"; shift 2;;
    --kubeadm-args) KUBEADM_EXTRA_ARGS="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

prepare_node

log "Initializing Kubernetes master..."

INIT_CMD=(kubeadm init --pod-network-cidr=${POD_CIDR})
if [ -n "$MASTER_IP" ]; then
  INIT_CMD+=(--apiserver-advertise-address=$MASTER_IP)
fi
if [ -n "$KUBEADM_EXTRA_ARGS" ]; then
  # shellcheck disable=SC2086
  INIT_CMD+=( $KUBEADM_EXTRA_ARGS )
fi

"${INIT_CMD[@]}"

log "Setting up kubeconfig for the current user (root)..."
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

log "Saving kubeadm join command to /root/kubeadm-join.sh..."
/usr/bin/kubeadm token create --print-join-command >/root/kubeadm-join.sh
chmod 700 /root/kubeadm-join.sh
cat /root/kubeadm-join.sh

log "Installing Flannel CNI... (wait for pods to become ready)"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

log "Done. Run 'kubectl get nodes' to check status."
