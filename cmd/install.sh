#!/usr/bin/env bash
# Install orchestrator - runs install phases in order
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASES_DIR="${SCRIPT_DIR}/../phases/install"

# Source common
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# Parse arguments (same as installer.sh)
DRY_RUN=false
FORCE=false
DOCTOR=false
SKIP_K3S=false
INSTALL_K3S=false
KUBECONFIG=""
PROFILE="full"
WITH_MAIL=false
WITH_DNS=false
VERSION=""
CHANNEL="main"
BUILD_IMAGES=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --doctor) DOCTOR=true; shift ;;
    --skip-k3s) SKIP_K3S=true; shift ;;
    --install-k3s) INSTALL_K3S=true; shift ;;
    --kubeconfig) KUBECONFIG="$2"; export KUBECONFIG; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --with-mail) WITH_MAIL=true; shift ;;
    --with-dns) WITH_DNS=true; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --build-images) BUILD_IMAGES=true; shift ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

# Export variables for phases
export DRY_RUN FORCE DOCTOR SKIP_K3S INSTALL_K3S KUBECONFIG PROFILE WITH_MAIL WITH_DNS VERSION CHANNEL BUILD_IMAGES

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
    log_error "Installation failed at phase: ${failed_phase}"
    return 1
  fi
  
  log_ok "All installation phases completed successfully"
  return 0
}

# Main
main() {
  log_info "Starting Voxeil Panel installation"
  
  # Run phases
  run_phases "${PHASES_DIR}" || exit 1
  
  log_ok "Installation complete"
}

main "$@"
