#!/usr/bin/env bash
# Install phase: Core infrastructure (cert-manager, kyverno, flux, traefik, platform)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/lib/common.sh"
source "${REPO_ROOT}/lib/kube.sh"

log_phase "install/20-core"

# Ensure kubectl is available and context is valid
ensure_kubectl || exit 1
check_kubectl_context || exit 1

# Ensure kyverno namespace exists before applying install.yaml
log_info "Ensuring kyverno namespace exists..."
KYVERNO_NS="${REPO_ROOT}/infra/k8s/base/namespaces/kyverno.yaml"
if [ -f "${KYVERNO_NS}" ]; then
  run_kubectl apply -f "${KYVERNO_NS}"
fi

# Apply Kyverno CRDs directly first (to avoid annotation size limit issues with kustomize)
log_info "Applying Kyverno CRDs directly (bypassing kustomize to avoid annotation size limits)..."
KYVERNO_CRDS="${REPO_ROOT}/infra/k8s/components/kyverno/install.yaml"
run_kubectl apply --server-side --force-conflicts --field-manager=voxeil -f "${KYVERNO_CRDS}"

# Apply core infrastructure
log_info "Applying core infrastructure manifests..."
if ! run_kubectl apply -k "${REPO_ROOT}/infra/k8s/clusters/prod"; then
  log_error "Failed to apply core infrastructure"
  exit 1
fi

# Wait for critical core infrastructure deployments to be ready
log_info "Waiting for core infrastructure deployments to be ready..."
TIMEOUT="${VOXEIL_WAIT_TIMEOUT}"

# Wait for cert-manager (critical for TLS, required)
log_info "Checking cert-manager deployment..."
if ! run_kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
  log_error "cert-manager deployment not found after applying infrastructure"
  log_info "Available deployments in cert-manager namespace:"
  run_kubectl get deployments -n cert-manager 2>&1 || true
  exit 1
fi
log_info "cert-manager deployment found, waiting for rollout..."
wait_rollout_status "cert-manager" "deployment" "cert-manager" "${TIMEOUT}" || die 1 "cert-manager deployment not ready"

# Wait for kyverno admission controller (critical for policy enforcement, required)
log_info "Checking kyverno-admission-controller deployment..."
if ! run_kubectl get deployment kyverno-admission-controller -n kyverno >/dev/null 2>&1; then
  log_error "kyverno-admission-controller deployment not found after applying infrastructure"
  log_info "Available deployments in kyverno namespace:"
  run_kubectl get deployments -n kyverno 2>&1 || true
  exit 1
fi
log_info "kyverno-admission-controller deployment found, waiting for rollout..."
wait_rollout_status "kyverno" "deployment" "kyverno-admission-controller" "${TIMEOUT}" || die 1 "kyverno-admission-controller deployment not ready"

# Ensure local-path StorageClass exists (required for PVCs)
log_info "Checking for local-path StorageClass..."
if ! run_kubectl get storageclass local-path >/dev/null 2>&1; then
  log_warn "local-path StorageClass not found. Waiting for it to appear..."
  SC_WAIT_ATTEMPTS=30
  sc_found=false
  for i in $(seq 1 ${SC_WAIT_ATTEMPTS}); do
    if run_kubectl get storageclass local-path >/dev/null 2>&1; then
      log_ok "local-path StorageClass found"
      sc_found=true
      break
    fi
    if [ $((i % 5)) -eq 0 ]; then
      log_info "Still waiting for local-path StorageClass... ($i/${SC_WAIT_ATTEMPTS})"
    fi
    sleep 2
  done
  if [ "${sc_found}" != "true" ]; then
    log_error "local-path StorageClass not found after $((SC_WAIT_ATTEMPTS * 2))s. PVCs may not bind."
    run_kubectl get storageclass || true
  fi
else
  log_ok "local-path StorageClass exists"
fi

# Wait for PVCs to be bound (required for postgres, pgadmin, bind9)
log_info "Waiting for PVCs to be bound..."
PVC_WAIT_TIMEOUT=120
PVC_WAIT_INTERVAL=5
PVC_WAIT_ATTEMPTS=$((PVC_WAIT_TIMEOUT / PVC_WAIT_INTERVAL))

# Wait for infra-db PVCs
for pvc_name in postgres-pvc pgadmin-pvc; do
  if run_kubectl get pvc "${pvc_name}" -n infra-db >/dev/null 2>&1; then
    log_info "Waiting for PVC ${pvc_name} to be bound..."
    pvc_bound=false
    for i in $(seq 1 ${PVC_WAIT_ATTEMPTS}); do
      local pvc_phase
      pvc_phase=$(run_kubectl get pvc "${pvc_name}" -n infra-db -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      if [ "${pvc_phase}" = "Bound" ]; then
        log_ok "PVC ${pvc_name} is bound"
        pvc_bound=true
        break
      fi
      if [ $((i % 4)) -eq 0 ]; then
        log_info "Still waiting for PVC ${pvc_name}... ($i/${PVC_WAIT_ATTEMPTS}) - Current phase: ${pvc_phase}"
        # Show PVC details for debugging
        run_kubectl get pvc "${pvc_name}" -n infra-db -o jsonpath='{.status}' 2>/dev/null | head -3 || true
      fi
      sleep ${PVC_WAIT_INTERVAL}
    done
    if [ "${pvc_bound}" != "true" ]; then
      log_error "PVC ${pvc_name} not bound after ${PVC_WAIT_TIMEOUT}s"
      log_info "PVC details:"
      run_kubectl get pvc "${pvc_name}" -n infra-db -o yaml || true
      log_info "StorageClass status:"
      run_kubectl get storageclass local-path -o yaml 2>&1 | head -20 || true
    fi
  else
    log_warn "PVC ${pvc_name} not found in infra-db namespace (may be created later)"
  fi
done

# Wait for dns-zone PVC
if run_kubectl get pvc dns-zones-pvc -n dns-zone >/dev/null 2>&1; then
  log_info "Waiting for PVC dns-zones-pvc to be bound..."
  pvc_bound=false
  for i in $(seq 1 ${PVC_WAIT_ATTEMPTS}); do
    if run_kubectl get pvc dns-zones-pvc -n dns-zone -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Bound"; then
      log_ok "PVC dns-zones-pvc is bound"
      pvc_bound=true
      break
    fi
    if [ $((i % 4)) -eq 0 ]; then
      log_info "Still waiting for PVC dns-zones-pvc... ($i/${PVC_WAIT_ATTEMPTS})"
    fi
    sleep ${PVC_WAIT_INTERVAL}
  done
  if [ "${pvc_bound}" != "true" ]; then
    log_error "PVC dns-zones-pvc not bound after ${PVC_WAIT_TIMEOUT}s"
    run_kubectl get pvc dns-zones-pvc -n dns-zone -o yaml || true
  fi
fi

log_ok "Core infrastructure phase complete"
