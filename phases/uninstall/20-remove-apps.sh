#!/usr/bin/env bash
# Uninstall phase: Remove applications
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "uninstall/20-remove-apps"

# Ensure kubectl is available
ensure_kubectl || exit 1

# Remove applications first (before infrastructure)
log_info "Removing applications..."
if ! kubectl delete -k "${SCRIPT_DIR}/../../apps/deploy/clusters/prod" --ignore-not-found; then
  log_warn "Some resources may not have been found (this is expected during uninstall)"
fi

log_ok "Applications removal phase complete"
