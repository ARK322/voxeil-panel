#!/usr/bin/env bash
# Local CI simulation - mirrors GitHub Actions k3s integration test
# Usage: ./scripts/ci-local.sh [--debug]
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Parse arguments
DEBUG_MODE=false
if [[ "${1:-}" == "--debug" ]]; then
  DEBUG_MODE=true
  set -x
fi

# Artifacts directory
ARTIFACTS_DIR="${REPO_ROOT}/ci-artifacts"
rm -rf "${ARTIFACTS_DIR}"
mkdir -p "${ARTIFACTS_DIR}"

# Logging
log_info() {
  echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_error() {
  echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_debug() {
  if [[ "${DEBUG_MODE}" == "true" ]]; then
    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
  fi
}

# Debug bundle collection
collect_debug_bundle() {
  local phase="$1"
  log_info "Collecting debug bundle for phase: ${phase}"
  
  local bundle_file="${ARTIFACTS_DIR}/debug-bundle-${phase}.txt"
  {
    echo "=========================================="
    echo "DEBUG BUNDLE: ${phase}"
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "=========================================="
    echo ""
    echo "=== All Pods Status ==="
    kubectl get pods -A -o wide 2>&1 || true
    echo ""
    echo "=== Recent Events (sorted by timestamp) ==="
    kubectl get events -A --sort-by='.lastTimestamp' 2>&1 | tail -n 200 || true
    echo ""
    echo "=== Controller Deployment ==="
    kubectl describe deployment controller -n platform 2>&1 || true
    echo ""
    echo "=== Panel Deployment ==="
    kubectl describe deployment panel -n platform 2>&1 || true
    echo ""
    echo "=== Controller Pods ==="
    kubectl get pods -n platform -l app=controller -o wide 2>&1 || true
    for pod in $(kubectl get pods -n platform -l app=controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
      if [[ -n "${pod}" ]]; then
        echo "--- Logs: ${pod} (current) ---"
        kubectl logs "${pod}" -n platform --tail=200 2>&1 || true
        echo "--- Logs: ${pod} (previous) ---"
        kubectl logs "${pod}" -n platform --previous --tail=200 2>&1 || true
      fi
    done
    echo ""
    echo "=== Panel Pods ==="
    kubectl get pods -n platform -l app=panel -o wide 2>&1 || true
    for pod in $(kubectl get pods -n platform -l app=panel -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
      if [[ -n "${pod}" ]]; then
        echo "--- Logs: ${pod} (current) ---"
        kubectl logs "${pod}" -n platform --tail=200 2>&1 || true
        echo "--- Logs: ${pod} (previous) ---"
        kubectl logs "${pod}" -n platform --previous --tail=200 2>&1 || true
      fi
    done
    echo ""
    echo "=== PostgreSQL StatefulSet ==="
    kubectl describe statefulset postgres -n infra-db 2>&1 || true
    echo ""
    echo "=== PostgreSQL Pods ==="
    kubectl get pods -n infra-db -l app=postgres -o wide 2>&1 || true
    echo ""
    echo "=== StorageClass ==="
    kubectl get storageclass 2>&1 || true
    echo ""
    echo "=== PVCs ==="
    kubectl get pvc -A 2>&1 || true
    echo ""
    echo "=== Secrets (names only) ==="
    kubectl get secrets -A 2>&1 || true
    echo ""
    echo "=========================================="
    echo "END DEBUG BUNDLE: ${phase}"
    echo "=========================================="
  } > "${bundle_file}"
  
  log_info "Debug bundle saved to: ${bundle_file}"
}

# Error handler
on_error() {
  local phase="${1:-unknown}"
  log_error "Failure in phase: ${phase}"
  collect_debug_bundle "${phase}"
  exit 1
}

trap 'on_error "ci-local"' ERR

# Check prerequisites
log_info "Checking prerequisites..."
if ! command -v kubectl &>/dev/null; then
  log_error "kubectl not found"
  exit 1
fi

if ! command -v k3s &>/dev/null && ! kubectl cluster-info &>/dev/null; then
  log_error "k3s not found and no kubeconfig available"
  log_error "Please install k3s or set KUBECONFIG"
  exit 1
fi

# Set up environment (CI mode)
export VOXEIL_CI=1
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# Get current commit SHA
GITHUB_SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
OWNER_LC="ark322"
IMAGE_SHA_TAG="sha-${GITHUB_SHA:0:7}"
CONTROLLER_IMAGE="ghcr.io/${OWNER_LC}/voxeil-controller:${IMAGE_SHA_TAG}"
PANEL_IMAGE="ghcr.io/${OWNER_LC}/voxeil-panel:${IMAGE_SHA_TAG}"

export VOXEIL_CONTROLLER_IMAGE="${CONTROLLER_IMAGE}"
export VOXEIL_PANEL_IMAGE="${PANEL_IMAGE}"

log_info "CI mode enabled"
log_info "Controller image: ${CONTROLLER_IMAGE}"
log_info "Panel image: ${PANEL_IMAGE}"
log_info "KUBECONFIG: ${KUBECONFIG}"

# Verify cluster access
log_info "Verifying cluster access..."
if ! kubectl cluster-info &>/dev/null; then
  log_error "Cannot access cluster"
  exit 1
fi

kubectl get nodes -o wide || {
  log_error "Cannot get nodes"
  exit 1
}

# Make scripts executable
log_info "Making scripts executable..."
chmod +x voxeil.sh || true
find cmd phases lib tools scripts -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true

# First install
log_info "=========================================="
log_info "PHASE 1: First install"
log_info "=========================================="
if ! bash voxeil.sh install --skip-k3s; then
  on_error "first-install"
fi

# Collect debug bundle after first install (if debug mode or on failure)
if [[ "${DEBUG_MODE}" == "true" ]]; then
  collect_debug_bundle "after-first-install"
fi

# First doctor check
log_info "=========================================="
log_info "PHASE 2: First doctor check"
log_info "=========================================="
if ! bash voxeil.sh doctor; then
  on_error "first-doctor"
fi

# Uninstall
log_info "=========================================="
log_info "PHASE 3: Uninstall"
log_info "=========================================="
if ! bash voxeil.sh uninstall --force; then
  on_error "uninstall"
fi

# Second install
log_info "=========================================="
log_info "PHASE 4: Second install"
log_info "=========================================="
if ! bash voxeil.sh install --skip-k3s; then
  on_error "second-install"
fi

# Collect debug bundle after second install (if debug mode or on failure)
if [[ "${DEBUG_MODE}" == "true" ]]; then
  collect_debug_bundle "after-second-install"
fi

# Final doctor check
log_info "=========================================="
log_info "PHASE 5: Final doctor check"
log_info "=========================================="
if ! bash voxeil.sh doctor; then
  on_error "final-doctor"
fi

# Success
log_info "=========================================="
log_info "✅ CI LOCAL SIMULATION PASSED"
log_info "=========================================="
log_info "Debug artifacts: ${ARTIFACTS_DIR}"
exit 0
