#!/usr/bin/env bash
# Uninstall phase: Remove applications
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "uninstall/20-remove-apps"

# Ensure kubectl is available
ensure_kubectl || exit 1

# Remove applications first (before infrastructure)
log_info "Removing applications..."
if ! run_kubectl delete -k "${SCRIPT_DIR}/../../apps/deploy/clusters/prod" --ignore-not-found --request-timeout=120s; then
  log_warn "Some resources may not have been found (this is expected during uninstall)"
fi

# Wait for resources to be deleted before proceeding
log_info "Waiting for application resources to be deleted..."
TIMEOUT="${VOXEIL_WAIT_TIMEOUT:-600}"

# Wait for platform namespace resources to be cleaned up
if run_kubectl get namespace platform >/dev/null 2>&1; then
  # Wait for deployments to be deleted
  waited=0
  while [ "${waited}" -lt "${TIMEOUT}" ]; do
    deploy_count=$(run_kubectl get deployments -n platform --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "${deploy_count}" -eq "0" ]; then
      log_ok "All application deployments deleted"
      break
    fi
    if [ $((waited % 10)) -eq 0 ] && [ ${waited} -gt 0 ]; then
      log_info "Still waiting for deployments to be deleted... (${waited}/${TIMEOUT}s)"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  
  if [ "${waited}" -ge "${TIMEOUT}" ]; then
    log_warn "Some deployments may still exist (will be cleaned up in namespace phase)"
  fi
fi

log_ok "Applications removal phase complete"
