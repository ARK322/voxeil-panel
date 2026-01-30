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

# Apply applications
log_info "Applying application manifests..."
if ! run_kubectl apply -k "${REPO_ROOT}/apps/deploy/clusters/prod"; then
  log_error "Failed to apply applications"
  exit 1
fi

# Wait for application deployments to be ready (if they exist)
log_info "Waiting for application deployments to be ready..."
TIMEOUT="${VOXEIL_WAIT_TIMEOUT}"

# Wait for controller (if deployment exists)
if run_kubectl get deployment controller -n platform >/dev/null 2>&1; then
  wait_rollout_status "platform" "deployment" "controller" "${TIMEOUT}" || die 1 "controller deployment not ready"
else
  log_info "Controller deployment not found (may be excluded in kustomization)"
fi

# Wait for panel (if deployment exists)
if run_kubectl get deployment panel -n platform >/dev/null 2>&1; then
  wait_rollout_status "platform" "deployment" "panel" "${TIMEOUT}" || die 1 "panel deployment not ready"
else
  log_info "Panel deployment not found (may be excluded in kustomization)"
fi

log_ok "Applications phase complete"
