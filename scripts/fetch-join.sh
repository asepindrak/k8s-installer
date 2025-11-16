#!/usr/bin/env bash
# fetch-join.sh -- simple helper to scp the join file from the master
# Usage: ./fetch-join.sh user@master.example.com:/root/kubeadm-join.sh
set -euo pipefail
IFS=$'\n\t'

if [ $# -ne 1 ]; then
  echo "Usage: $0 user@master:/root/kubeadm-join.sh"
  exit 1
fi

REMOTE="$1"
scp "$REMOTE" .
echo "Fetched file: $(basename "$REMOTE")"
