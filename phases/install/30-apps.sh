#!/usr/bin/env bash
# Install phase: Applications (controller, panel)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/lib/common.sh"
source "${REPO_ROOT}/lib/kube.sh"

log_phase "install/30-apps"

# Ensure kubectl is available and context is valid
ensure_kubectl || exit 1
check_kubectl_context || exit 1

# Apply applications (required)
log_info "Applying application manifests..."
APPS_DIR="${REPO_ROOT}/apps/deploy/clusters/prod"
if [ ! -f "${APPS_DIR}/kustomization.yaml" ]; then
  log_error "Application kustomization not found: ${APPS_DIR}/kustomization.yaml"
  exit 1
fi

# Check if kustomization has resources (more robust check)
if ! grep -E '^resources:' "${APPS_DIR}/kustomization.yaml" >/dev/null 2>&1; then
  log_error "Application kustomization missing 'resources:' field"
  exit 1
fi

# Check if there are any uncommented resource entries
resource_count=$(grep -E '^\s+-' "${APPS_DIR}/kustomization.yaml" 2>/dev/null | grep -v '^[[:space:]]*#' | wc -l || echo "0")
if [ "${resource_count}" -eq "0" ]; then
  log_error "Application kustomization has no resources defined (found ${resource_count} resource entries)"
  exit 1
fi

if ! run_kubectl apply -k "${APPS_DIR}"; then
  log_error "Failed to apply applications"
  exit 1
fi

# Wait for application deployments to be ready (required)
log_info "Waiting for application deployments to be ready..."
TIMEOUT="${VOXEIL_WAIT_TIMEOUT}"

# Wait for controller (required)
if ! run_kubectl get deployment controller -n platform >/dev/null 2>&1; then
  log_error "Controller deployment not found after applying manifests"
  exit 1
fi
wait_rollout_status "platform" "deployment" "controller" "${TIMEOUT}" || die 1 "controller deployment not ready"

# Wait for panel (required)
if ! run_kubectl get deployment panel -n platform >/dev/null 2>&1; then
  log_error "Panel deployment not found after applying manifests"
  exit 1
fi
wait_rollout_status "platform" "deployment" "panel" "${TIMEOUT}" || die 1 "panel deployment not ready"

log_ok "Applications phase complete"
