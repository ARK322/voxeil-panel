#!/usr/bin/env bash
# Uninstall phase: Remove infrastructure
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "uninstall/30-remove-infra"

# Ensure kubectl is available
ensure_kubectl || exit 1

# Remove infrastructure (after applications)
log_info "Removing infrastructure..."
if ! kubectl delete -k "${SCRIPT_DIR}/../../infra/k8s/clusters/prod" --ignore-not-found --request-timeout=120s; then
  log_warn "Some resources may not have been found (this is expected during uninstall)"
fi

log_ok "Infrastructure removal phase complete"
