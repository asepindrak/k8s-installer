#!/usr/bin/env bash
# master.sh -- prepare master node and run 'kubeadm init'
# Improvements:
# - ensures conntrack is installed (common.sh may not include it)
# - supports optional --image-repository for pulling images from a mirror
# - pre-pulls kubeadm images and the recommended pause image (with retries)
# - better error messages and waits for control-plane readiness before saving join command
set -euo pipefail
IFS=$'\n\t'

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTDIR/common.sh" || source "/usr/local/bin/common.sh"

MASTER_IP=""
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
KUBEADM_EXTRA_ARGS=""
IMAGE_REPO=""   # optional mirror, e.g. registry.aliyuncs.com/google_containers
K8S_VERSION="${K8S_VERSION:-1.31.14}" # fallback if not set in common.sh

usage() {
  cat <<EOF
Usage: sudo ./master.sh [--apiserver-advertise-address <ip>] [--pod-cidr <cidr>]
                       [--kubeadm-args "..."] [--image-repository <repo>]
Options:
  --apiserver-advertise-address  IP address the API Server will advertise (default: auto)
  --pod-cidr                    Pod network CIDR (default: ${POD_CIDR})
  --kubeadm-args                Extra args to pass to kubeadm init (quoted)
  --image-repository            Optional image repository mirror for kubeadm image pulls
  -h|--help                     Show this help
EOF
  exit 1
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --apiserver-advertise-address) MASTER_IP="$2"; shift 2;;
    --pod-cidr) POD_CIDR="$2"; shift 2;;
    --kubeadm-args) KUBEADM_EXTRA_ARGS="$2"; shift 2;;
    --image-repository) IMAGE_REPO="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

ensure_conntrack() {
  if ! command_exists conntrack; then
    log "conntrack not found — installing conntrack..."
    apt-get update || true
    apt-get install -y conntrack || {
      log "Failed to install conntrack. Please install it manually and re-run."
      return 1
    }
    log "conntrack installed"
  else
    log "conntrack present"
  fi
}

# helper: pull images with retry
pull_images_with_retry() {
  local repo_arg=()
  if [ -n "$IMAGE_REPO" ]; then
    repo_arg=(--image-repository "$IMAGE_REPO")
    log "Using image repository: $IMAGE_REPO"
  fi

  # Try kubeadm config images pull (retries)
  local -r max_attempts=4
  local attempt=1
  until [ $attempt -gt $max_attempts ]; do
    log "Pulling kubeadm images (attempt $attempt/$max_attempts) ..."
    if sudo kubeadm config images pull --kubernetes-version="v${K8S_VERSION}" "${repo_arg[@]}"; then
      log "Successfully pulled kubeadm images"
      break
    fi
    log "kubeadm image pull failed on attempt $attempt. Retrying in $((attempt * 5))s..."
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done

  if [ $attempt -gt $max_attempts ]; then
    log "Failed to pull kubeadm images after $max_attempts attempts"
    return 1
  fi

  # Pull recommended pause image explicitly (recommended by kubeadm)
  # kubeadm sometimes warns about pause image mismatch; pull recommended tag
  local pause_img="registry.k8s.io/pause:3.10"
  if [ -n "$IMAGE_REPO" ]; then
    # attempt mirrored pause image too (user provided mirror may have different path)
    log "Also attempting to pull mirrored pause image via image-repository..."
    # try the mirror for pause if it looks like google_containers mirror style
    case "$IMAGE_REPO" in
      *google_containers*|*aliyuncs*|*docker.io*|*registry.*)
        # try pull via kubeadm (using repo arg) - kubeadm will translate names
        sudo kubeadm config images pull --kubernetes-version="v${K8S_VERSION}" "${repo_arg[@]}" || true
        ;;
    esac
  fi

  log "Pulling pause image $pause_img with ctr (containerd)"
  # use ctr if available; if not, use crictl; otherwise rely on kubeadm's pulls
  if command_exists ctr; then
    sudo ctr image pull --all-platforms "$pause_img" || {
      log "ctr failed to pull $pause_img, continuing (kubeadm might still pull it)"
    }
  elif command_exists crictl; then
    sudo crictl pull "$pause_img" || log "crictl failed to pull $pause_img"
  else
    log "Neither ctr nor crictl found; relying on kubeadm to pull pause image"
  fi

  return 0
}

wait_control_plane_ready() {
  # wait for kube-system control-plane pods (kube-apiserver etc) to be running
  local -r timeout=180
  local waited=0
  log "Waiting up to ${timeout}s for control-plane pods to be Ready..."
  while [ $waited -lt $timeout ]; do
    # kube-apiserver runs as static pod on master. Check pods in kube-system that have control-plane names.
    if kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '{print $1, $3}' | grep -E 'kube-apiserver|kube-controller-manager|kube-scheduler' | awk '{print $2}' | grep -qv 'Running'; then
      sleep 3
      waited=$((waited + 3))
      continue
    fi

    # ensure all three control-plane pods are Running
    local ready_count
    ready_count=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '{print $1, $3}' | grep -E 'kube-apiserver|kube-controller-manager|kube-scheduler' | awk '{print $2}' | grep -c 'Running' || true)
    if [ -n "$ready_count" ] && [ "$ready_count" -ge 3 ]; then
      log "Control-plane pods appear Running"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done

  log "Timed out waiting for control-plane pods to become Running (waited ${timeout}s)"
  return 1
}

# Start
ensure_root

log "Preparing node (this will run prepare_node from common.sh)..."
prepare_node

# ensure conntrack is present (some environments need it explicitly)
ensure_conntrack || true

log "Initializing Kubernetes master..."

# pre-pull images (helpful in slow or flaky networks)
if ! pull_images_with_retry; then
  log "Image pre-pull failed. You can re-run this script or run 'kubeadm config images pull' manually."
  # do not exit here; allow kubeadm to try, but warn user
fi

# Build kubeadm init command
INIT_CMD=(kubeadm init --pod-network-cidr="${POD_CIDR}" --kubernetes-version="v${K8S_VERSION}")
if [ -n "$MASTER_IP" ]; then
  INIT_CMD+=(--apiserver-advertise-address="${MASTER_IP}")
fi
if [ -n "$IMAGE_REPO" ]; then
  INIT_CMD+=(--image-repository "${IMAGE_REPO}")
fi
if [ -n "$KUBEADM_EXTRA_ARGS" ]; then
  # shellcheck disable=SC2086
  # allow user to pass extra args string
  eval "INIT_CMD+=( ${KUBEADM_EXTRA_ARGS} )"
fi

log "Running: ${INIT_CMD[*]}"

# run kubeadm init, capture exit code and show useful logs on failure
if ! "${INIT_CMD[@]}"; then
  log "kubeadm init failed. Showing kubelet logs for debugging (last 200 lines):"
  sudo journalctl -u kubelet -n 200 --no-pager || true
  exit 1
fi

log "kubeadm init succeeded. Setting up kubeconfig for root..."
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config

# wait for control-plane pods to be ready before saving join command and installing CNI
if wait_control_plane_ready; then
  log "Control-plane running — saving join command and installing Flannel CNI"
else
  log "Control-plane not fully ready (timed out). We will still attempt to save join command and install CNI — check pod status manually."
fi

log "Saving kubeadm join command to /root/kubeadm-join.sh..."
/usr/bin/kubeadm token create --print-join-command >/root/kubeadm-join.sh
chmod 700 /root/kubeadm-join.sh
cat /root/kubeadm-join.sh || true

log "Installing Flannel CNI... (apply manifest and wait briefly)"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml || {
  log "Failed to apply flannel manifest. Check network connectivity and try applying manually."
}

log "Waiting a short time for CNI pods to start..."
sleep 8
kubectl get pods -n kube-system || true

log "Done. Run 'kubectl get nodes' to check status."
