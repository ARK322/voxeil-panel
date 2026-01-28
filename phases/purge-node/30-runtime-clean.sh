#!/usr/bin/env bash
# Purge-node phase: Runtime cleanup
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/fs.sh"

log_phase "purge-node/30-runtime-clean"

# Remove /var/lib/voxeil (state registry)
log_info "Removing /var/lib/voxeil..."
safe_rm "/var/lib/voxeil"

# Clean up Docker images if Docker is available
if command_exists docker && docker info >/dev/null 2>&1; then
  log_info "Cleaning up Voxeil Docker images..."
  docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "(voxeil|ghcr.io/.*/voxeil)" | while read -r image; do
    log_info "Removing Docker image: ${image}"
    docker rmi "${image}" 2>/dev/null || true
  done
  docker image prune -f 2>/dev/null || true
fi

# Clean up containerd images
if command_exists ctr; then
  log_info "Cleaning up Voxeil containerd images..."
  ctr -n k8s.io images ls 2>/dev/null | grep -E "(voxeil|ghcr.io/.*/voxeil)" | awk '{print $1":"$2}' | grep -v "^$" | while read -r image; do
    if [ -n "${image}" ]; then
      log_info "Removing containerd image: ${image}"
      ctr -n k8s.io images rm "${image}" 2>/dev/null || true
    fi
  done
elif command_exists crictl; then
  log_info "Cleaning up Voxeil containerd images..."
  crictl images 2>/dev/null | grep -E "(voxeil|ghcr.io/.*/voxeil)" | awk '{print $1":"$2}' | grep -v "^$" | while read -r image; do
    if [ -n "${image}" ]; then
      log_info "Removing containerd image: ${image}"
      crictl rmi "${image}" 2>/dev/null || true
    fi
  done
fi

log_ok "Runtime cleanup phase complete"
