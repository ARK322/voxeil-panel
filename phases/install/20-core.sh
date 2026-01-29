#!/usr/bin/env bash
# Install phase: Core infrastructure (cert-manager, kyverno, flux, traefik, platform)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "install/20-core"

# Ensure kubectl is available and context is valid
ensure_kubectl || exit 1
check_kubectl_context || exit 1

# Apply core infrastructure
log_info "Applying core infrastructure manifests..."
if ! run_kubectl apply -k "${SCRIPT_DIR}/../../infra/k8s/clusters/prod"; then
  log_error "Failed to apply core infrastructure"
  exit 1
fi

# Wait for critical core infrastructure deployments to be ready
log_info "Waiting for core infrastructure deployments to be ready..."
TIMEOUT="${VOXEIL_WAIT_TIMEOUT}"

# Wait for cert-manager (critical for TLS)
if run_kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
  wait_rollout_status "cert-manager" "deployment" "cert-manager" "${TIMEOUT}" || log_warn "cert-manager deployment not ready (may continue)"
fi

# Wait for kyverno admission controller (critical for policy enforcement)
if run_kubectl get deployment kyverno-admission-controller -n kyverno >/dev/null 2>&1; then
  wait_rollout_status "kyverno" "deployment" "kyverno-admission-controller" "${TIMEOUT}" || log_warn "kyverno-admission-controller deployment not ready (may continue)"
fi

log_ok "Core infrastructure phase complete"
