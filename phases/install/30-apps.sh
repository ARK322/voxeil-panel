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

log_ok "Applications phase complete"
