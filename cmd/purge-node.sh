#!/usr/bin/env bash
# Purge-node orchestrator - runs purge-node phases in order
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASES_DIR="${SCRIPT_DIR}/../phases/purge-node"

# Source common
source "${SCRIPT_DIR}/../lib/common.sh"

# Parse arguments
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    *) log_warn "Unknown option: $1 (ignoring)"; shift ;;
  esac
done

# Export variables for phases
export DRY_RUN FORCE

# Phase runner: execute phases in order
run_phases() {
  local phase_dir="$1"
  local failed_phase=""
  
  # Find all phase scripts and sort them
  local phases
  phases=$(find "${phase_dir}" -name "*.sh" -type f | sort)
  
  if [ -z "${phases}" ]; then
    log_error "No phase scripts found in ${phase_dir}"
    return 1
  fi
  
  # Run each phase
  while IFS= read -r phase; do
    local phase_name
    phase_name="$(basename "${phase}")"
    
    log_info "Running phase: ${phase_name}"
    
    # Make phase executable
    chmod +x "${phase}"
    
    # Run phase
    if ! bash "${phase}"; then
      failed_phase="${phase_name}"
      log_error "Phase ${phase_name} failed"
      break
    fi
    
    log_ok "Phase ${phase_name} completed"
  done <<< "${phases}"
  
  if [ -n "${failed_phase}" ]; then
    log_error "Purge-node failed at phase: ${failed_phase}"
    return 1
  fi
  
  log_ok "All purge-node phases completed successfully"
  return 0
}

# Main
main() {
  log_info "Starting node purge"
  
  # Run phases
  run_phases "${PHASES_DIR}" || exit 1
  
  log_ok "Node purge complete"
}

main "$@"
