#!/usr/bin/env bash
# CI loop driver - simulates GitHub Actions k3s integration test
# Usage: ./scripts/ci-loop.sh [--skip-k3s] [--max-attempts N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Parse arguments
SKIP_K3S=false
MAX_ATTEMPTS=2
for arg in "$@"; do
  case "$arg" in
    --skip-k3s)
      SKIP_K3S=true
      ;;
    --max-attempts=*)
      MAX_ATTEMPTS="${arg#*=}"
      ;;
    --max-attempts)
      shift
      MAX_ATTEMPTS="$1"
      ;;
  esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

# Debug bundle collection (same as in install/30-apps.sh)
collect_debug_bundle() {
  local namespace="${1:-}"
  local resource_type="${2:-}"
  local resource_name="${3:-}"
  
  echo ""
  echo "=========================================="
  echo "DEBUG BUNDLE START"
  echo "=========================================="
  
  if [ -n "${namespace}" ] && [ -n "${resource_type}" ] && [ -n "${resource_name}" ]; then
    echo ""
    echo "--- Failing Resource: ${resource_type}/${resource_name} in ${namespace} ---"
    kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" -o wide 2>&1 || true
    kubectl describe "${resource_type}" "${resource_name}" -n "${namespace}" 2>&1 | head -100 || true
  fi
  
  echo ""
  echo "--- All Pods Status ---"
  kubectl get pods -A -o wide 2>&1 || true
  
  echo ""
  echo "--- Recent Events (all namespaces, sorted by timestamp) ---"
  kubectl get events -A --sort-by='.lastTimestamp' 2>&1 | tail -120 || true
  
  if [ -n "${namespace}" ] && [ -n "${resource_name}" ]; then
    echo ""
    echo "--- Pod Logs (${namespace}/${resource_name}) ---"
    local pods
    pods=$(kubectl get pods -n "${namespace}" -l "app=${resource_name}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${pods}" ]; then
      pods=$(kubectl get pods -n "${namespace}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    if [ -n "${pods}" ]; then
      for pod in ${pods}; do
        echo "--- Logs: ${pod} ---"
        kubectl logs "${pod}" -n "${namespace}" --tail=200 2>&1 || true
      done
    fi
  fi
  
  echo ""
  echo "=========================================="
  echo "DEBUG BUNDLE END"
  echo "=========================================="
  echo ""
}

# Run install with error handling
run_install() {
  local attempt_num="$1"
  log_info "Install attempt ${attempt_num}..."
  
  local install_cmd="./voxeil.sh install"
  if [ "${SKIP_K3S}" = "true" ]; then
    install_cmd="${install_cmd} --skip-k3s"
  fi
  
  if ${install_cmd}; then
    log_info "Install attempt ${attempt_num} succeeded"
    return 0
  else
    local exit_code=$?
    log_error "Install attempt ${attempt_num} failed with exit code ${exit_code}"
    
    # Collect debug bundle
    collect_debug_bundle "platform" "deployment" "controller"
    collect_debug_bundle "platform" "deployment" "panel"
    
    return ${exit_code}
  fi
}

# Main loop
main() {
  log_info "Starting CI loop (max attempts: ${MAX_ATTEMPTS})"
  log_info "Skip k3s: ${SKIP_K3S}"
  
  # Ensure voxeil.sh is executable
  chmod +x voxeil.sh || true
  
  local attempt=1
  local success_count=0
  
  while [ ${attempt} -le ${MAX_ATTEMPTS} ]; do
    log_info ""
    log_info "========================================"
    log_info "CI Loop Attempt ${attempt}/${MAX_ATTEMPTS}"
    log_info "========================================"
    log_info ""
    
    # First install
    if ! run_install "${attempt}"; then
      log_error "First install failed in attempt ${attempt}"
      exit 1
    fi
    
    # Doctor check
    log_info "Running doctor check..."
    if ! ./voxeil.sh doctor; then
      log_error "Doctor check failed"
      collect_debug_bundle "" "" ""
      exit 1
    fi
    
    # Uninstall
    log_info "Running uninstall..."
    if ! ./voxeil.sh uninstall --force; then
      log_warn "Uninstall had issues (continuing anyway)"
    fi
    
    # Second install (idempotency test)
    log_info "Running second install (idempotency test)..."
    if ! run_install "${attempt}-2"; then
      log_error "Second install failed in attempt ${attempt}"
      exit 1
    fi
    
    # Final doctor check
    log_info "Running final doctor check..."
    if ! ./voxeil.sh doctor; then
      log_error "Final doctor check failed"
      collect_debug_bundle "" "" ""
      exit 1
    fi
    
    success_count=$((success_count + 1))
    log_info "Attempt ${attempt} completed successfully"
    
    if [ ${attempt} -lt ${MAX_ATTEMPTS} ]; then
      log_info "Waiting 10 seconds before next attempt..."
      sleep 10
    fi
    
    attempt=$((attempt + 1))
  done
  
  log_info ""
  log_info "========================================"
  log_info "CI Loop Complete - All ${MAX_ATTEMPTS} attempts passed!"
  log_info "========================================"
}

main "$@"
