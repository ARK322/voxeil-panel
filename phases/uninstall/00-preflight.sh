#!/usr/bin/env bash
# Uninstall phase: Preflight checks
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/validate.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "uninstall/00-preflight"

# Load state
state_load

# Check kubectl availability
if ! ensure_kubectl; then
  log_warn "kubectl not available or cluster not accessible"
  log_info "Proceeding with filesystem cleanup only..."
  export KUBECTL_AVAILABLE=false
else
  export KUBECTL_AVAILABLE=true
fi

# Check if state file exists
if [ ! -f "${STATE_FILE}" ]; then
  log_warn "State file not found at ${STATE_FILE}"
  log_info "This may indicate a partial installation or manual cleanup."
  if [ "${FORCE:-false}" != "true" ]; then
    log_info "Use --force to proceed with cleanup based on detected resources."
    log_info "Safe default: exiting without changes."
    exit 0
  fi
  log_info "Proceeding with uninstall based on detected resources (--force)..."
fi

# Confirmation (unless --force)
if [ "${FORCE:-false}" != "true" ] && [ "${DRY_RUN:-false}" != "true" ]; then
  echo "This will remove all Voxeil Panel components."
  echo "Press Enter to continue or Ctrl+C to cancel..."
  read -r
fi

log_ok "Preflight checks complete"
