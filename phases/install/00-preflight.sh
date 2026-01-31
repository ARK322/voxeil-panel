#!/usr/bin/env bash
# Install phase: Preflight checks
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../lib/validate.sh"

log_phase "install/00-preflight"

# Run preflight checks
preflight_checks "install" || die 1 "Preflight checks failed"

# Check if system is already installed (idempotency check)
if [ -f "${STATE_FILE}" ] || [ -f "${STATE_ENV_FILE}" ]; then
  # Check if cluster has voxeil resources
  if command_exists kubectl && kubectl get namespace platform >/dev/null 2>&1; then
    log_warn "Voxeil Panel appears to be already installed"
    log_warn "State file or cluster resources detected"
    
    if [ "${FORCE:-false}" != "true" ]; then
      log_error "Re-installation detected. Use --force to reinstall, or run uninstall first."
      log_error "This prevents accidental duplicate installations."
      exit 1
    else
      log_warn "Proceeding with re-installation (--force specified)"
    fi
  fi
fi

# Initialize render dir (for installer)
if [ -n "${RENDER_DIR:-}" ]; then
  source "${SCRIPT_DIR}/../../lib/fs.sh"
  init_render_dir || die 1 "Failed to initialize render directory"
fi

log_ok "Preflight checks passed"
