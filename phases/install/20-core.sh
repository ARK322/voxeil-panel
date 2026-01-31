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

# Sync PostgreSQL password from infra-db/postgres-secret to platform/platform-secrets
# This ensures controller can connect to postgres (postgres-secret is source of truth)
log_info "Syncing PostgreSQL credentials from infra-db/postgres-secret to platform/platform-secrets..."

if run_kubectl get secret postgres-secret -n infra-db >/dev/null 2>&1; then
  # Read postgres password from infra-db/postgres-secret (source of truth)
  POSTGRES_PASSWORD_FROM_SECRET=""
  if command_exists base64; then
    POSTGRES_PASSWORD_FROM_SECRET=$(run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  else
    # Fallback: try to decode with openssl
    POSTGRES_PASSWORD_FROM_SECRET=$(run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | openssl base64 -d -A 2>/dev/null || echo "")
  fi
  
  if [ -z "${POSTGRES_PASSWORD_FROM_SECRET}" ]; then
    # Try stringData if data doesn't exist (some installs use stringData)
    POSTGRES_PASSWORD_FROM_SECRET=$(run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.stringData.POSTGRES_PASSWORD}' 2>/dev/null || echo "")
  fi
  
  # If secret has placeholder, replace it with password from state.env or generate new one
  if [ "${POSTGRES_PASSWORD_FROM_SECRET}" = "REPLACE_POSTGRES_PASSWORD" ] || [ -z "${POSTGRES_PASSWORD_FROM_SECRET}" ]; then
    log_info "postgres-secret has placeholder or is empty, setting password from state.env or generating new one..."
    # Load state.env if available
    STATE_ENV_FILE="${HOME}/.voxeil/state.env"
    if [ -f "${STATE_ENV_FILE}" ]; then
      # shellcheck disable=SC1090
      set +u
      source "${STATE_ENV_FILE}" 2>/dev/null || true
      set -u
    fi
    
    # Use POSTGRES_ADMIN_PASSWORD from state.env if available, otherwise generate
    if [ -n "${POSTGRES_ADMIN_PASSWORD:-}" ]; then
      POSTGRES_PASSWORD_FROM_SECRET="${POSTGRES_ADMIN_PASSWORD}"
    else
      # Generate new password
      if command_exists openssl; then
        POSTGRES_PASSWORD_FROM_SECRET=$(openssl rand -base64 32 | tr -d '\n' || rand)
      else
        POSTGRES_PASSWORD_FROM_SECRET=$(rand)
      fi
      # Save to state.env for consistency
      mkdir -p "$(dirname "${STATE_ENV_FILE}")"
      if ! grep -q "^POSTGRES_ADMIN_PASSWORD=" "${STATE_ENV_FILE}" 2>/dev/null; then
        echo "POSTGRES_ADMIN_PASSWORD=${POSTGRES_PASSWORD_FROM_SECRET}" >> "${STATE_ENV_FILE}"
        chmod 600 "${STATE_ENV_FILE}"
      fi
    fi
    
    # Update postgres-secret with actual password
    run_kubectl delete secret postgres-secret -n infra-db --ignore-not-found >/dev/null 2>&1
    run_kubectl create secret generic postgres-secret \
      --namespace=infra-db \
      --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD_FROM_SECRET}" >/dev/null 2>&1 || {
      log_error "Failed to update postgres-secret with password"
      exit 1
    }
    log_ok "postgres-secret updated with password"
  fi
  
  if [ -n "${POSTGRES_PASSWORD_FROM_SECRET}" ]; then
    log_info "Read PostgreSQL password from infra-db/postgres-secret"
    
    # Get current platform-secrets values (preserve other secrets)
    if run_kubectl get secret platform-secrets -n platform >/dev/null 2>&1; then
      # Read existing values
      ADMIN_API_KEY=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.ADMIN_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.ADMIN_API_KEY}' 2>/dev/null || echo "")
      JWT_SECRET=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.JWT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.JWT_SECRET}' 2>/dev/null || echo "")
      PANEL_ADMIN_USERNAME=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.PANEL_ADMIN_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.PANEL_ADMIN_USERNAME}' 2>/dev/null || echo "")
      PANEL_ADMIN_PASSWORD=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.PANEL_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.PANEL_ADMIN_PASSWORD}' 2>/dev/null || echo "")
      PANEL_ADMIN_EMAIL=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.PANEL_ADMIN_EMAIL}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.PANEL_ADMIN_EMAIL}' 2>/dev/null || echo "")
      SITE_NODEPORT_START=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.SITE_NODEPORT_START}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.SITE_NODEPORT_START}' 2>/dev/null || echo "")
      SITE_NODEPORT_END=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.SITE_NODEPORT_END}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.SITE_NODEPORT_END}' 2>/dev/null || echo "")
      MAILCOW_API_URL=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.MAILCOW_API_URL}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.MAILCOW_API_URL}' 2>/dev/null || echo "")
      MAILCOW_API_KEY=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.MAILCOW_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.MAILCOW_API_KEY}' 2>/dev/null || echo "")
      POSTGRES_HOST=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.POSTGRES_HOST}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.POSTGRES_HOST}' 2>/dev/null || echo "postgres.infra-db.svc.cluster.local")
      POSTGRES_PORT=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.POSTGRES_PORT}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.POSTGRES_PORT}' 2>/dev/null || echo "5432")
      POSTGRES_ADMIN_USER=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.POSTGRES_ADMIN_USER}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.POSTGRES_ADMIN_USER}' 2>/dev/null || echo "postgres")
      POSTGRES_DB=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.POSTGRES_DB}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.POSTGRES_DB}' 2>/dev/null || echo "voxeil")
      
      # Update POSTGRES_ADMIN_PASSWORD to match postgres-secret
      POSTGRES_ADMIN_PASSWORD="${POSTGRES_PASSWORD_FROM_SECRET}"
      
      # Recreate secret with synced password
      run_kubectl delete secret platform-secrets -n platform --ignore-not-found >/dev/null 2>&1
      run_kubectl create secret generic platform-secrets \
        --namespace=platform \
        --from-literal=ADMIN_API_KEY="${ADMIN_API_KEY}" \
        --from-literal=JWT_SECRET="${JWT_SECRET}" \
        --from-literal=PANEL_ADMIN_USERNAME="${PANEL_ADMIN_USERNAME}" \
        --from-literal=PANEL_ADMIN_PASSWORD="${PANEL_ADMIN_PASSWORD}" \
        --from-literal=PANEL_ADMIN_EMAIL="${PANEL_ADMIN_EMAIL}" \
        --from-literal=SITE_NODEPORT_START="${SITE_NODEPORT_START}" \
        --from-literal=SITE_NODEPORT_END="${SITE_NODEPORT_END}" \
        --from-literal=MAILCOW_API_URL="${MAILCOW_API_URL}" \
        --from-literal=MAILCOW_API_KEY="${MAILCOW_API_KEY}" \
        --from-literal=POSTGRES_HOST="${POSTGRES_HOST}" \
        --from-literal=POSTGRES_PORT="${POSTGRES_PORT}" \
        --from-literal=POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER}" \
        --from-literal=POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD}" \
        --from-literal=POSTGRES_DB="${POSTGRES_DB}" >/dev/null 2>&1 || {
        log_error "Failed to sync PostgreSQL password to platform-secrets"
        exit 1
      }
      log_ok "PostgreSQL password synced to platform-secrets"
    else
      log_warn "platform-secrets not found, will be created in 15-secrets phase"
    fi
  else
    log_warn "Could not read POSTGRES_PASSWORD from infra-db/postgres-secret (may use placeholder)"
  fi
else
  log_warn "postgres-secret not found in infra-db namespace (may be created later)"
fi

log_ok "Core infrastructure phase complete"
