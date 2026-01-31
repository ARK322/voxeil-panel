#!/usr/bin/env bash
# Uninstall orchestrator - runs uninstall phases in order
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASES_DIR="${SCRIPT_DIR}/../phases/uninstall"

# Source common
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# Parse arguments (same as uninstaller.sh)
DRY_RUN=false
FORCE=false
DOCTOR=false
PURGE_NODE=false
KEEP_VOLUMES=false
KUBECONFIG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --doctor) DOCTOR=true; shift ;;
    --purge-node) PURGE_NODE=true; shift ;;
    --keep-volumes) KEEP_VOLUMES=true; shift ;;
    --kubeconfig) KUBECONFIG="$2"; export KUBECONFIG; shift 2 ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

# Export variables for phases
export DRY_RUN FORCE DOCTOR PURGE_NODE KEEP_VOLUMES KUBECONFIG

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
    log_error "Uninstallation failed at phase: ${failed_phase}"
    return 1
  fi
  
  log_ok "All uninstallation phases completed successfully"
  return 0
}

# Main
main() {
  log_info "Starting Voxeil Panel uninstallation"
  
  # Run phases
  run_phases "${PHASES_DIR}" || exit 1
  
  log_ok "Uninstallation complete"
}

main "$@"
