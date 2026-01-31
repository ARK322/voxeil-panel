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

# Wait for PostgreSQL to be ready (controller depends on it)
log_info "Waiting for PostgreSQL to be ready (controller dependency)..."
if run_kubectl get statefulset postgres -n infra-db >/dev/null 2>&1; then
  log_info "PostgreSQL StatefulSet found, waiting for rollout..."
  TIMEOUT="${VOXEIL_WAIT_TIMEOUT}"
  if ! wait_rollout_status "infra-db" "statefulset" "postgres" "${TIMEOUT}"; then
    log_error "PostgreSQL StatefulSet not ready after ${TIMEOUT}s"
    log_info "PostgreSQL StatefulSet status:"
    run_kubectl get statefulset postgres -n infra-db -o wide 2>&1 || true
    log_info "PostgreSQL pods:"
    run_kubectl get pods -n infra-db -l app=postgres 2>&1 || true
    die 1 "PostgreSQL must be ready before starting controller/panel"
  fi
  log_ok "PostgreSQL is ready"
else
  log_warn "PostgreSQL StatefulSet not found, proceeding anyway (may fail if postgres is required)"
fi

# Verify PostgreSQL service is available
log_info "Verifying PostgreSQL service endpoint..."
POSTGRES_READY=false
for i in $(seq 1 30); do
  if run_kubectl get endpoints postgres -n infra-db -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; then
    POSTGRES_READY=true
    break
  fi
  if [ $((i % 5)) -eq 0 ]; then
    log_info "Still waiting for PostgreSQL service endpoint... ($i/30)"
  fi
  sleep 2
done
if [ "${POSTGRES_READY}" = "true" ]; then
  log_ok "PostgreSQL service endpoint is ready"
else
  log_warn "PostgreSQL service endpoint not ready, but proceeding (may cause connection errors)"
fi

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

# In CI/integration, override images with SHA tags if provided
# Use kubectl kustomize with envsubst or sed to replace image names
if [ "${VOXEIL_CI:-0}" = "1" ] && [ -n "${VOXEIL_CONTROLLER_IMAGE:-}" ] && [ -n "${VOXEIL_PANEL_IMAGE:-}" ]; then
  log_info "CI mode detected, overriding images with SHA tags..."
  log_info "Controller image: ${VOXEIL_CONTROLLER_IMAGE}"
  log_info "Panel image: ${VOXEIL_PANEL_IMAGE}"
  
  # Create temporary kustomization with image overrides
  # Use kubectl kustomize to build, then sed to replace, then apply
  TEMP_MANIFEST=$(mktemp) || TEMP_MANIFEST="/tmp/kustomize-$$.yaml"
  
  # Build kustomization
  if run_kubectl kustomize "${APPS_DIR}" > "${TEMP_MANIFEST}" 2>&1; then
    # Replace image references in the built manifest (handle both GNU and BSD sed)
    if sed --version >/dev/null 2>&1; then
      # GNU sed (Linux)
      sed -i "s|ghcr.io/[^/]*/voxeil-controller:[^[:space:]]*|${VOXEIL_CONTROLLER_IMAGE}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
      sed -i "s|ghcr.io/[^/]*/voxeil-panel:[^[:space:]]*|${VOXEIL_PANEL_IMAGE}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
    else
      # BSD sed (macOS) - requires empty string after -i
      sed -i '' "s|ghcr.io/[^/]*/voxeil-controller:[^[:space:]]*|${VOXEIL_CONTROLLER_IMAGE}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
      sed -i '' "s|ghcr.io/[^/]*/voxeil-panel:[^[:space:]]*|${VOXEIL_PANEL_IMAGE}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
    fi
    
    log_info "Applying kustomization with CI image overrides..."
    if ! run_kubectl apply -f "${TEMP_MANIFEST}"; then
      log_error "Failed to apply applications with CI image overrides"
      rm -f "${TEMP_MANIFEST}"
      exit 1
    fi
    rm -f "${TEMP_MANIFEST}"
    log_ok "Applications applied with CI image overrides"
  else
    log_warn "Failed to build kustomization, falling back to standard apply"
    # Fall back to standard apply
    if ! run_kubectl apply -k "${APPS_DIR}"; then
      log_error "Failed to apply applications"
      log_info "Checking what was applied:"
      run_kubectl get deployments -n platform 2>&1 || true
      exit 1
    fi
  fi
else

  log_info "Applying kustomization (this may take a moment)..."
  if ! run_kubectl apply -k "${APPS_DIR}"; then
    log_error "Failed to apply applications"
    log_info "Checking what was applied:"
    run_kubectl get deployments -n platform 2>&1 || true
    exit 1
  fi
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
wait_rollout_status "platform" "deployment" "controller" "${TIMEOUT}" "app=controller" || {
  die 1 "controller deployment not ready"
}

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
wait_rollout_status "platform" "deployment" "panel" "${TIMEOUT}" "app=panel" || {
  die 1 "panel deployment not ready"
}

log_ok "Applications phase complete"
