#!/usr/bin/env bash
# worker.sh -- prepare a worker node and join to the control plane
set -euo pipefail
IFS=$'\n\t'

SCRIPTDIR="$(dirname "$0")"
source "$SCRIPTDIR/common.sh" || source "/usr/local/bin/common.sh"

JOIN_CMD=""

usage() {
  cat <<EOF
Usage:
  sudo ./worker.sh --join "<kubeadm join ...>"
  OR
  sudo ./worker.sh --token <token> --master-ip <ip:6443> --discovery-hash sha256:<hash>

Examples:
  sudo ./worker.sh --join "kubeadm join 10.0.0.5:6443 --token abcd.efgh --discovery-token-ca-cert-hash sha256:xxx"
EOF
  exit 1
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --join) JOIN_CMD="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --master-ip) MASTER_IP="$2"; shift 2;;
    --discovery-hash) DISCOVERY_HASH="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

prepare_node

if [ -n "${JOIN_CMD:-}" ]; then
  log "Using provided join command..."
  eval "${JOIN_CMD}"
  exit 0
fi

if [ -n "${TOKEN:-}" ] && [ -n "${MASTER_IP:-}" ] && [ -n "${DISCOVERY_HASH:-}" ]; then
  log "Joining using token + master IP + discovery hash..."
  kubeadm join ${MASTER_IP} --token ${TOKEN} --discovery-token-ca-cert-hash ${DISCOVERY_HASH}
  exit 0
fi

log "No join command provided. Use --join or provide token/master-ip/discovery-hash."
usage
