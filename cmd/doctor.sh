#!/usr/bin/env bash
# Doctor orchestrator - runs doctor phases in order
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASES_DIR="${SCRIPT_DIR}/../phases/doctor"

# Source common
source "${SCRIPT_DIR}/../lib/common.sh"

# Parse arguments
DRY_RUN=false
FORCE=false
KUBECONFIG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --kubeconfig) KUBECONFIG="$2"; export KUBECONFIG; shift 2 ;;
    *) log_warn "Unknown option: $1 (ignoring)"; shift ;;
  esac
done

# Export variables for phases
export DRY_RUN FORCE KUBECONFIG

# Phase runner: execute phases in order
run_phases() {
  local phase_dir="$1"
  local exit_code=0
  
  # Find all phase scripts and sort them
  local phases
  phases=$(find "${phase_dir}" -name "*.sh" -type f | sort)
  
  if [ -z "${phases}" ]; then
    log_error "No phase scripts found in ${phase_dir}"
    return 1
  fi
  
  # Run each phase (doctor phases may set EXIT_CODE)
  while IFS= read -r phase; do
    local phase_name
    phase_name="$(basename "${phase}")"
    
    log_info "Running phase: ${phase_name}"
    
    # Make phase executable
    chmod +x "${phase}"
    
    # Run phase (capture exit code)
    if ! bash "${phase}"; then
      exit_code=1
    fi
    
    # Check if phase set EXIT_CODE
    if [ -n "${EXIT_CODE:-}" ]; then
      exit_code=${EXIT_CODE}
    fi
  done <<< "${phases}"
  
  return "${exit_code}"
}

# Main
main() {
  log_info "Starting Voxeil Panel doctor check"
  
  # Run phases
  run_phases "${PHASES_DIR}"
  local exit_code=$?
  
  if [ ${exit_code} -eq 0 ]; then
    log_ok "Doctor check passed"
  else
    log_error "Doctor check failed (exit code: ${exit_code})"
  fi
  
  exit ${exit_code}
}

main "$@"
