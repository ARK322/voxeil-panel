#!/usr/bin/env bash
# Install phase: Applications (controller, panel)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/lib/common.sh"
source "${REPO_ROOT}/lib/kube.sh"

log_phase "install/30-apps"

# Ensure kubectl is available and context is valid
ensure_kubectl || exit 1
check_kubectl_context || exit 1

# Apply applications (required)
log_info "Applying application manifests..."
APPS_DIR="${REPO_ROOT}/apps/deploy/clusters/prod"
log_info "Kustomization directory: ${APPS_DIR}"

if [ ! -f "${APPS_DIR}/kustomization.yaml" ]; then
  log_error "Application kustomization not found: ${APPS_DIR}/kustomization.yaml"
  exit 1
fi

log_info "Found kustomization.yaml, validating..."
# Check if kustomization has resources (more robust check)
if ! grep -E '^resources:' "${APPS_DIR}/kustomization.yaml" >/dev/null 2>&1; then
  log_error "Application kustomization missing 'resources:' field"
  exit 1
fi

# Check if there are any uncommented resource entries
resource_count=$(grep -E '^\s+-' "${APPS_DIR}/kustomization.yaml" 2>/dev/null | grep -v '^[[:space:]]*#' | wc -l || echo "0")
log_info "Found ${resource_count} resource entries in kustomization"
if [ "${resource_count}" -eq "0" ]; then
  log_error "Application kustomization has no resources defined (found ${resource_count} resource entries)"
  log_info "Kustomization file content:"
  cat "${APPS_DIR}/kustomization.yaml" || true
  exit 1
fi

log_info "Applying kustomization (this may take a moment)..."
if ! run_kubectl apply -k "${APPS_DIR}"; then
  log_error "Failed to apply applications"
  log_info "Checking what was applied:"
  run_kubectl get deployments -n platform 2>&1 || true
  exit 1
fi

log_info "Applications applied successfully. Checking created resources..."
run_kubectl get deployments -n platform 2>&1 || true

# Wait for application deployments to be ready (required)
log_info "Waiting for application deployments to be ready..."
TIMEOUT="${VOXEIL_WAIT_TIMEOUT}"

# Wait for controller (required)
log_info "Checking for controller deployment..."
if ! run_kubectl get deployment controller -n platform >/dev/null 2>&1; then
  log_error "Controller deployment not found after applying manifests"
  log_info "Available deployments in platform namespace:"
  run_kubectl get deployments -n platform 2>&1 || true
  log_info "Checking for controller pods:"
  run_kubectl get pods -n platform -l app=controller 2>&1 || true
  exit 1
fi
log_info "Controller deployment found, checking image..."
run_kubectl get deployment controller -n platform -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1 && echo "" || true
wait_rollout_status "platform" "deployment" "controller" "${TIMEOUT}" || die 1 "controller deployment not ready"

# Wait for panel (required)
log_info "Checking for panel deployment..."
if ! run_kubectl get deployment panel -n platform >/dev/null 2>&1; then
  log_error "Panel deployment not found after applying manifests"
  log_info "Available deployments in platform namespace:"
  run_kubectl get deployments -n platform 2>&1 || true
  log_info "Checking for panel pods:"
  run_kubectl get pods -n platform -l app=panel 2>&1 || true
  exit 1
fi
log_info "Panel deployment found, checking image..."
run_kubectl get deployment panel -n platform -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1 && echo "" || true
wait_rollout_status "platform" "deployment" "panel" "${TIMEOUT}" || die 1 "panel deployment not ready"

log_ok "Applications phase complete"
