#!/usr/bin/env bash
# Install phase: Applications (controller, panel)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "install/30-apps"

# Ensure kubectl is available and context is valid
ensure_kubectl || exit 1
check_kubectl_context || exit 1

# Apply applications
log_info "Applying application manifests..."
if ! run_kubectl apply -k "${SCRIPT_DIR}/../../apps/deploy/clusters/prod"; then
  log_error "Failed to apply applications"
  exit 1
fi

# Override images if explicitly provided (useful for CI/local builds)
if [ -n "${CONTROLLER_IMAGE:-}" ]; then
  if run_kubectl get deployment controller -n platform >/dev/null 2>&1; then
    log_info "Setting controller image override to ${CONTROLLER_IMAGE}"
    run_kubectl -n platform set image deployment/controller controller="${CONTROLLER_IMAGE}" >/dev/null
  else
    log_warn "Controller deployment not found; cannot set image override"
  fi
fi

if [ -n "${PANEL_IMAGE:-}" ]; then
  if run_kubectl get deployment panel -n platform >/dev/null 2>&1; then
    log_info "Setting panel image override to ${PANEL_IMAGE}"
    run_kubectl -n platform set image deployment/panel panel="${PANEL_IMAGE}" >/dev/null
  else
    log_warn "Panel deployment not found; cannot set image override"
  fi
fi

# Wait for application deployments to be ready
log_info "Waiting for application deployments to be ready..."
TIMEOUT="${VOXEIL_WAIT_TIMEOUT}"

# Wait for controller (critical)
if run_kubectl get deployment controller -n platform >/dev/null 2>&1; then
  wait_rollout_status "platform" "deployment" "controller" "${TIMEOUT}" || die 1 "controller deployment not ready"
fi

# Wait for panel (critical)
if run_kubectl get deployment panel -n platform >/dev/null 2>&1; then
  wait_rollout_status "platform" "deployment" "panel" "${TIMEOUT}" || die 1 "panel deployment not ready"
fi

log_ok "Applications phase complete"
