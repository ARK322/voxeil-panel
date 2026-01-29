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

log_ok "Core infrastructure phase complete"
