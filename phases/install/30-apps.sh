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

# Wait for webhook deployments to be ready (required before applying apps)
log_info "Waiting for webhook deployments to be ready (required for app admission)..."
TIMEOUT="${VOXEIL_WAIT_TIMEOUT}"

# Wait for cert-manager-webhook
if run_kubectl get deployment cert-manager-webhook -n cert-manager >/dev/null 2>&1; then
  log_info "Waiting for cert-manager-webhook..."
  if ! wait_rollout_status "cert-manager" "deployment" "cert-manager-webhook" "${TIMEOUT}"; then
    log_error "cert-manager-webhook not ready after ${TIMEOUT}s"
    die 1 "cert-manager-webhook must be ready before applying apps"
  fi
  log_ok "cert-manager-webhook is ready"
fi

# Wait for kyverno-admission-controller
if run_kubectl get deployment kyverno-admission-controller -n kyverno >/dev/null 2>&1; then
  log_info "Waiting for kyverno-admission-controller..."
  if ! wait_rollout_status "kyverno" "deployment" "kyverno-admission-controller" "${TIMEOUT}"; then
    log_error "kyverno-admission-controller not ready after ${TIMEOUT}s"
    die 1 "kyverno-admission-controller must be ready before applying apps"
  fi
  log_ok "kyverno-admission-controller is ready"
fi

# Wait for PostgreSQL to be ready (controller depends on it)
log_info "Waiting for PostgreSQL to be ready (controller dependency)..."
if run_kubectl get statefulset postgres -n infra-db >/dev/null 2>&1; then
  log_info "PostgreSQL StatefulSet found, waiting for rollout..."
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
  
  # Verify PostgreSQL is actually accepting connections (controller requires this)
  # Use kubectl exec into postgres pod instead of creating test pod (more reliable)
  log_info "Verifying PostgreSQL accepts connections..."
  POSTGRES_CONNECT_OK=false
  POSTGRES_POD=""
  # Find postgres pod
  for i in $(seq 1 30); do
    POSTGRES_POD=$(run_kubectl get pods -n infra-db -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${POSTGRES_POD}" ]; then
      pod_status=$(run_kubectl get pod "${POSTGRES_POD}" -n infra-db -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      if [ "${pod_status}" = "Running" ]; then
        break
      fi
    fi
    if [ $((i % 5)) -eq 0 ]; then
      log_info "Waiting for postgres pod to be Running... ($i/30)"
    fi
    sleep 2
  done
  
  if [ -n "${POSTGRES_POD}" ]; then
    # Test connection using kubectl exec (more reliable than test pod)
    for i in $(seq 1 20); do
      if run_kubectl exec "${POSTGRES_POD}" -n infra-db -- pg_isready -U postgres >/dev/null 2>&1; then
        POSTGRES_CONNECT_OK=true
        break
      fi
      if [ $((i % 5)) -eq 0 ]; then
        log_info "Still waiting for PostgreSQL to accept connections... ($i/20)"
      fi
      sleep 2
    done
  fi
  
  if [ "${POSTGRES_CONNECT_OK}" = "true" ]; then
    log_ok "PostgreSQL is accepting connections"
  else
    log_warn "PostgreSQL connection test failed, but proceeding (controller may fail to start)"
    log_info "PostgreSQL pod status:"
    run_kubectl get pods -n infra-db -l app=postgres -o wide 2>&1 || true
  fi
else
  log_warn "PostgreSQL service endpoint not ready, but proceeding (may cause connection errors)"
fi

# Verify PostgreSQL password sync (self-healing check)
log_info "Verifying PostgreSQL password sync between infra-db/postgres-secret and platform/platform-secrets..."
if run_kubectl get secret postgres-secret -n infra-db >/dev/null 2>&1 && run_kubectl get secret platform-secrets -n platform >/dev/null 2>&1; then
  # Read passwords from both secrets
  POSTGRES_PWD_FROM_INFRA=""
  POSTGRES_PWD_FROM_PLATFORM=""
  
  if command_exists base64; then
    POSTGRES_PWD_FROM_INFRA=$(run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.stringData.POSTGRES_PASSWORD}' 2>/dev/null || echo "")
    POSTGRES_PWD_FROM_PLATFORM=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.POSTGRES_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.POSTGRES_ADMIN_PASSWORD}' 2>/dev/null || echo "")
  else
    POSTGRES_PWD_FROM_INFRA=$(run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.stringData.POSTGRES_PASSWORD}' 2>/dev/null || echo "")
    POSTGRES_PWD_FROM_PLATFORM=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.POSTGRES_ADMIN_PASSWORD}' 2>/dev/null || echo "")
  fi
  
  if [ -n "${POSTGRES_PWD_FROM_INFRA}" ] && [ -n "${POSTGRES_PWD_FROM_PLATFORM}" ]; then
    if [ "${POSTGRES_PWD_FROM_INFRA}" != "${POSTGRES_PWD_FROM_PLATFORM}" ]; then
      log_warn "PostgreSQL password mismatch detected - auto-syncing..."
      # Sync password (use same logic as 20-core.sh)
      # Read all existing platform-secrets values
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
      
      # Update password to match infra-db secret
      POSTGRES_ADMIN_PASSWORD="${POSTGRES_PWD_FROM_INFRA}"
      
      # Recreate secret
      run_kubectl delete secret platform-secrets -n platform --ignore-not-found --request-timeout=30s >/dev/null 2>&1
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
        log_error "Failed to sync PostgreSQL password"
        die 1 "PostgreSQL password sync failed - controller will not be able to connect"
      }
      log_ok "PostgreSQL password auto-synced (self-healing)"
      
      # After syncing, delete controller pods to force recreation with new secret
      log_info "Deleting controller pods to force recreation with synced password..."
      if run_kubectl get deployment controller -n platform >/dev/null 2>&1; then
        # Delete all controller pods to force recreation with new secret
        run_kubectl delete pods -n platform -l app=controller --ignore-not-found --request-timeout=30s >/dev/null 2>&1 || true
        log_info "Controller pods deleted (will be recreated with new secret)"
        # Wait for pods to be recreated
        sleep 10
        # Verify pods are being recreated
        if run_kubectl get pods -n platform -l app=controller --no-headers 2>/dev/null | grep -q .; then
          log_ok "Controller pods are being recreated"
        else
          log_warn "Controller pods not yet recreated (deployment will create them)"
        fi
      fi
    else
      log_ok "PostgreSQL passwords match"
    fi
  else
    log_warn "Could not verify password sync (secrets may use different formats)"
  fi
  
  # Final verification: test connection with actual password from platform-secrets
  log_info "Final verification: testing PostgreSQL connection with platform-secrets password..."
  if run_kubectl get secret platform-secrets -n platform >/dev/null 2>&1; then
    FINAL_POSTGRES_PWD=""
    if command_exists base64; then
      FINAL_POSTGRES_PWD=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.POSTGRES_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.POSTGRES_ADMIN_PASSWORD}' 2>/dev/null || echo "")
    else
      FINAL_POSTGRES_PWD=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.POSTGRES_ADMIN_PASSWORD}' 2>/dev/null || echo "")
    fi
    
    if [ -n "${FINAL_POSTGRES_PWD}" ]; then
      POSTGRES_POD=$(run_kubectl get pods -n infra-db -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [ -n "${POSTGRES_POD}" ]; then
        # Test connection using the actual password from platform-secrets
        if run_kubectl exec "${POSTGRES_POD}" -n infra-db -- env PGPASSWORD="${FINAL_POSTGRES_PWD}" psql -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
          log_ok "PostgreSQL connection verified with platform-secrets password"
          
          # Also verify the password matches postgres-secret
          POSTGRES_SECRET_PWD=""
          if command_exists base64; then
            POSTGRES_SECRET_PWD=$(run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.stringData.POSTGRES_PASSWORD}' 2>/dev/null || echo "")
          else
            POSTGRES_SECRET_PWD=$(run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.stringData.POSTGRES_PASSWORD}' 2>/dev/null || echo "")
          fi
          
          if [ "${FINAL_POSTGRES_PWD}" = "${POSTGRES_SECRET_PWD}" ]; then
            log_ok "Password values match between postgres-secret and platform-secrets"
          else
            log_error "Password mismatch detected! postgres-secret and platform-secrets have different values"
            log_error "This will cause controller authentication failures"
            die 1 "Password sync verification failed - passwords do not match"
          fi
        else
          log_warn "PostgreSQL connection test failed with platform-secrets password (controller may still fail)"
        fi
      fi
    fi
  fi
else
  log_warn "Could not verify password sync (secrets not found)"
fi

# VALIDATION GATES: Must pass before applying controller/panel
log_info "Running validation gates before applying applications..."

# Gate 1: StorageClass local-path exists
log_info "Gate 1/10: Checking StorageClass local-path..."
if ! run_kubectl get storageclass local-path >/dev/null 2>&1; then
  log_error "StorageClass 'local-path' not found"
  die 1 "StorageClass 'local-path' must exist before applying applications"
fi
log_ok "StorageClass local-path exists"

# Gate 2: Required namespaces exist
log_info "Gate 2/10: Checking required namespaces..."
REQUIRED_NAMESPACES=("platform" "infra-db" "cert-manager" "kyverno")
for ns in "${REQUIRED_NAMESPACES[@]}"; do
  if ! run_kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log_error "Required namespace '${ns}' not found"
    die 1 "Namespace '${ns}' must exist before applying applications"
  fi
done
log_ok "All required namespaces exist"

# Gate 3: All core PVCs are Bound
log_info "Gate 3/10: Checking core PVCs are Bound..."
REQUIRED_PVCS=(
  "infra-db/postgres-pvc"
  "infra-db/pgadmin-pvc"
  "dns-zone/dns-zones-pvc"
  "platform/controller-config-pvc"
)
for pvc in "${REQUIRED_PVCS[@]}"; do
  ns="${pvc%%/*}"
  name="${pvc##*/}"
  
  # Check if PVC exists
  if ! run_kubectl get pvc "${name}" -n "${ns}" >/dev/null 2>&1; then
    log_error "PVC '${pvc}' does not exist"
    die 1 "PVC '${pvc}' must exist before applying applications"
  fi
  
  pvc_phase=$(run_kubectl get pvc "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  
  if [ "${pvc_phase}" != "Bound" ]; then
    # For WaitForFirstConsumer PVCs, we need to pre-bind by creating a temporary pod
    log_info "PVC '${pvc}' is ${pvc_phase}, checking binding mode..."
    binding_mode=$(run_kubectl get storageclass local-path -o jsonpath='{.volumeBindingMode}' 2>/dev/null || echo "Immediate")
    
    if [ "${binding_mode}" = "WaitForFirstConsumer" ]; then
      log_info "StorageClass uses WaitForFirstConsumer, pre-binding PVC '${pvc}'..."
      # Create a temporary pod to trigger binding
      # Use alpine:3.19 which is already pre-pulled in CI
      TEMP_PREBIND_POD="prebind-${name}-$(date +%s)"
      cat <<EOF | run_kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${TEMP_PREBIND_POD}
  namespace: ${ns}
spec:
  containers:
  - name: prebind
    image: alpine:3.19
    command: ["sleep", "10"]
    volumeMounts:
    - name: pvc
      mountPath: /data
  volumes:
  - name: pvc
    persistentVolumeClaim:
      claimName: ${name}
  restartPolicy: Never
EOF
      
      # Wait for PVC to bind (timeout: 60s)
      log_info "Waiting for PVC '${pvc}' to bind..."
      for i in $(seq 1 30); do
        pvc_phase=$(run_kubectl get pvc "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [ "${pvc_phase}" = "Bound" ]; then
          log_ok "PVC '${pvc}' is now Bound"
          break
        fi
        if [ $i -eq 30 ]; then
          log_error "PVC '${pvc}' did not bind after 60s"
          run_kubectl describe pvc "${name}" -n "${ns}" >&2 || true
          # Clean up prebind pod
          run_kubectl delete pod "${TEMP_PREBIND_POD}" -n "${ns}" --ignore-not-found --request-timeout=30s >/dev/null 2>&1 || true
          die 1 "PVC '${pvc}' must be Bound before applying applications"
        fi
        sleep 2
      done
      
      # Delete the prebind pod and wait for it to be fully deleted
      log_info "Deleting prebind pod..."
      run_kubectl delete pod "${TEMP_PREBIND_POD}" -n "${ns}" --ignore-not-found --request-timeout=30s >/dev/null 2>&1 || true
      # Wait for pod to be fully deleted (max 30s)
      for i in $(seq 1 15); do
        if ! run_kubectl get pod "${TEMP_PREBIND_POD}" -n "${ns}" >/dev/null 2>&1; then
          break
        fi
        if [ $i -eq 15 ]; then
          log_warn "Prebind pod still exists after 30s, forcing deletion..."
          run_kubectl delete pod "${TEMP_PREBIND_POD}" -n "${ns}" --force --grace-period=0 --request-timeout=30s >/dev/null 2>&1 || true
        fi
        sleep 2
      done
      # Verify PVC is still Bound after pod deletion
      pvc_phase_after=$(run_kubectl get pvc "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
      if [ "${pvc_phase_after}" != "Bound" ]; then
        log_error "PVC '${pvc}' became unbound after prebind pod deletion (phase: ${pvc_phase_after})"
        die 1 "PVC '${pvc}' must remain Bound after prebind pod deletion"
      fi
      log_ok "Prebind pod deleted, PVC remains Bound"
    else
      # Immediate binding mode - PVC should bind quickly
      log_info "StorageClass uses Immediate binding, waiting for PVC '${pvc}' to bind..."
      for i in $(seq 1 30); do
        pvc_phase=$(run_kubectl get pvc "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [ "${pvc_phase}" = "Bound" ]; then
          break
        fi
        if [ $i -eq 30 ]; then
          log_error "PVC '${pvc}' did not bind after 60s (binding mode: ${binding_mode})"
          run_kubectl describe pvc "${name}" -n "${ns}" >&2 || true
          die 1 "PVC '${pvc}' must be Bound before applying applications"
        fi
        sleep 2
      done
    fi
    
    # Final verification
    pvc_phase=$(run_kubectl get pvc "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [ "${pvc_phase}" != "Bound" ]; then
      log_error "PVC '${pvc}' is still not Bound (phase: ${pvc_phase})"
      run_kubectl describe pvc "${name}" -n "${ns}" >&2 || true
      die 1 "PVC '${pvc}' must be Bound before applying applications"
    fi
  fi
done
log_ok "All core PVCs are Bound"

# Gate 4: cert-manager-webhook Ready
log_info "Gate 4/7: Checking cert-manager-webhook is Ready..."
if ! run_kubectl get deployment cert-manager-webhook -n cert-manager >/dev/null 2>&1; then
  log_error "cert-manager-webhook deployment not found"
  die 1 "cert-manager-webhook must exist and be Ready before applying applications"
fi
webhook_ready=$(run_kubectl get deployment cert-manager-webhook -n cert-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
webhook_desired=$(run_kubectl get deployment cert-manager-webhook -n cert-manager -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
if [ "${webhook_ready}" != "${webhook_desired}" ] || [ "${webhook_ready}" = "0" ]; then
  log_error "cert-manager-webhook is not Ready (ready: ${webhook_ready}, desired: ${webhook_desired})"
  die 1 "cert-manager-webhook must be Ready before applying applications"
fi
log_ok "cert-manager-webhook is Ready"

# Gate 5: kyverno-admission-controller Ready
log_info "Gate 5/10: Checking kyverno-admission-controller is Ready..."
if ! run_kubectl get deployment kyverno-admission-controller -n kyverno >/dev/null 2>&1; then
  log_error "kyverno-admission-controller deployment not found"
  die 1 "kyverno-admission-controller must exist and be Ready before applying applications"
fi
kyverno_ready=$(run_kubectl get deployment kyverno-admission-controller -n kyverno -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
kyverno_desired=$(run_kubectl get deployment kyverno-admission-controller -n kyverno -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
if [ "${kyverno_ready}" != "${kyverno_desired}" ] || [ "${kyverno_ready}" = "0" ]; then
  log_error "kyverno-admission-controller is not Ready (ready: ${kyverno_ready}, desired: ${kyverno_desired})"
  die 1 "kyverno-admission-controller must be Ready before applying applications"
fi
log_ok "kyverno-admission-controller is Ready"

# Gate 6: Postgres Ready AND accepts password auth (already verified above, but re-check)
log_info "Gate 6/10: Verifying PostgreSQL is Ready and accepts connections..."
if ! run_kubectl get statefulset postgres -n infra-db >/dev/null 2>&1; then
  log_error "PostgreSQL StatefulSet not found"
  die 1 "PostgreSQL must exist and be Ready before applying applications"
fi
postgres_ready=$(run_kubectl get statefulset postgres -n infra-db -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
postgres_desired=$(run_kubectl get statefulset postgres -n infra-db -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
if [ "${postgres_ready}" != "${postgres_desired}" ] || [ "${postgres_ready}" = "0" ]; then
  log_error "PostgreSQL is not Ready (ready: ${postgres_ready}, desired: ${postgres_desired})"
  die 1 "PostgreSQL must be Ready before applying applications"
fi
# Connection test was already done above, but verify it's still working
POSTGRES_POD=$(run_kubectl get pods -n infra-db -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "${POSTGRES_POD}" ]; then
  log_error "PostgreSQL pod not found"
  die 1 "PostgreSQL pod must exist before applying applications"
fi
if ! run_kubectl exec "${POSTGRES_POD}" -n infra-db -- pg_isready -U postgres >/dev/null 2>&1; then
  log_error "PostgreSQL is not accepting connections"
  die 1 "PostgreSQL must accept connections before applying applications"
fi
log_ok "PostgreSQL is Ready and accepting connections"

# Gate 7: Secrets are not placeholder/empty and are consistent
log_info "Gate 7/10: Verifying secrets are not placeholder/empty and are consistent..."
# Check postgres-secret
if ! run_kubectl get secret postgres-secret -n infra-db >/dev/null 2>&1; then
  log_error "postgres-secret not found in infra-db namespace"
  die 1 "postgres-secret must exist before applying applications"
fi
POSTGRES_SECRET_PWD=""
if command_exists base64; then
  POSTGRES_SECRET_PWD=$(run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.stringData.POSTGRES_PASSWORD}' 2>/dev/null || echo "")
else
  POSTGRES_SECRET_PWD=$(run_kubectl get secret postgres-secret -n infra-db -o jsonpath='{.stringData.POSTGRES_PASSWORD}' 2>/dev/null || echo "")
fi
if [ -z "${POSTGRES_SECRET_PWD}" ] || [ "${POSTGRES_SECRET_PWD}" = "REPLACE_POSTGRES_PASSWORD" ]; then
  log_error "postgres-secret has placeholder or empty password"
  die 1 "postgres-secret must have a real password before applying applications"
fi

# Check platform-secrets
if ! run_kubectl get secret platform-secrets -n platform >/dev/null 2>&1; then
  log_error "platform-secrets not found in platform namespace"
  die 1 "platform-secrets must exist before applying applications"
fi
PLATFORM_SECRET_PWD=""
if command_exists base64; then
  PLATFORM_SECRET_PWD=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.data.POSTGRES_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.POSTGRES_ADMIN_PASSWORD}' 2>/dev/null || echo "")
else
  PLATFORM_SECRET_PWD=$(run_kubectl get secret platform-secrets -n platform -o jsonpath='{.stringData.POSTGRES_ADMIN_PASSWORD}' 2>/dev/null || echo "")
fi
if [ -z "${PLATFORM_SECRET_PWD}" ]; then
  log_error "platform-secrets has empty POSTGRES_ADMIN_PASSWORD"
  die 1 "platform-secrets must have POSTGRES_ADMIN_PASSWORD before applying applications"
fi

# Verify consistency
if [ "${POSTGRES_SECRET_PWD}" != "${PLATFORM_SECRET_PWD}" ]; then
  log_error "Password mismatch: postgres-secret and platform-secrets have different values"
  log_error "This will cause controller authentication failures"
  die 1 "Secrets must be consistent before applying applications"
fi
log_ok "Secrets are valid and consistent"

# Gate 8: PostgreSQL accepts auth using EXACT credentials controller will use
log_info "Gate 8/10: Verifying PostgreSQL accepts auth with controller credentials..."
if [ -n "${POSTGRES_POD}" ] && [ -n "${PLATFORM_SECRET_PWD}" ]; then
  # Test connection using EXACT credentials from platform-secrets
  if ! run_kubectl exec "${POSTGRES_POD}" -n infra-db -- env PGPASSWORD="${PLATFORM_SECRET_PWD}" psql -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; then
    log_error "PostgreSQL authentication failed with platform-secrets password"
    log_error "Controller will fail to connect with these credentials"
    die 1 "PostgreSQL must accept authentication with controller credentials before applying applications"
  fi
  log_ok "PostgreSQL accepts authentication with controller credentials"
else
  log_error "Cannot verify PostgreSQL auth: pod or password missing"
  die 1 "PostgreSQL auth verification failed"
fi

# Gate 9: NO placeholder / empty / auto-generated secrets at runtime
log_info "Gate 9/10: Verifying no placeholder/empty/auto-generated secrets..."
# Check all required secrets in platform-secrets
REQUIRED_SECRET_KEYS=(
  "ADMIN_API_KEY"
  "JWT_SECRET"
  "PANEL_ADMIN_USERNAME"
  "PANEL_ADMIN_PASSWORD"
  "PANEL_ADMIN_EMAIL"
  "POSTGRES_HOST"
  "POSTGRES_PORT"
  "POSTGRES_ADMIN_USER"
  "POSTGRES_ADMIN_PASSWORD"
  "POSTGRES_DB"
)
for key in "${REQUIRED_SECRET_KEYS[@]}"; do
  secret_value=""
  if command_exists base64; then
    secret_value=$(run_kubectl get secret platform-secrets -n platform -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || run_kubectl get secret platform-secrets -n platform -o jsonpath="{.stringData.${key}}" 2>/dev/null || echo "")
  else
    secret_value=$(run_kubectl get secret platform-secrets -n platform -o jsonpath="{.stringData.${key}}" 2>/dev/null || echo "")
  fi
  if [ -z "${secret_value}" ]; then
    log_error "platform-secrets has empty value for key: ${key}"
    die 1 "platform-secrets must have all required keys with non-empty values before applying applications"
  fi
  # Check for placeholder patterns
  if echo "${secret_value}" | grep -qE "^(REPLACE_|PLACEHOLDER_|AUTO_)"; then
    log_error "platform-secrets has placeholder value for key: ${key}"
    die 1 "platform-secrets must not contain placeholder values before applying applications"
  fi
done
log_ok "All required secrets are present and non-placeholder"

# Determine if ingress should be excluded (BEFORE Gate 10)
# Load panel domain and TLS issuer from state.env (if available)
PANEL_DOMAIN=""
TLS_ISSUER=""
if [ -f "${STATE_ENV_FILE}" ]; then
  PANEL_DOMAIN=$(grep "^PANEL_DOMAIN=" "${STATE_ENV_FILE}" 2>/dev/null | cut -d'=' -f2- || echo "")
  TLS_ISSUER=$(grep "^TLS_ISSUER=" "${STATE_ENV_FILE}" 2>/dev/null | cut -d'=' -f2- || echo "")
fi

# Fallback to environment variables if not in state.env
if [ -z "${PANEL_DOMAIN}" ]; then
  PANEL_DOMAIN="${VOXEIL_PANEL_DOMAIN:-}"
fi
if [ -z "${TLS_ISSUER}" ]; then
  TLS_ISSUER="${VOXEIL_TLS_ISSUER:-letsencrypt-prod}"
fi

# In CI mode, if domain is not provided, exclude ingress from kustomization
# (ingress requires valid domain, cannot use placeholder)
EXCLUDE_INGRESS=false
if [ "${VOXEIL_CI:-0}" = "1" ] && ([ -z "${PANEL_DOMAIN}" ] || [ "${PANEL_DOMAIN}" = "REPLACE_PANEL_DOMAIN" ]); then
  log_info "CI mode: Panel domain not provided, excluding ingress (requires valid domain)"
  EXCLUDE_INGRESS=true
fi

# Gate 10: All manifests render cleanly (no missing vars)
# This gate validates the FINAL manifest that will be applied (after ingress filtering)
log_info "Gate 10/10: Verifying manifests render cleanly..."
if [ ! -f "${APPS_DIR}/kustomization.yaml" ]; then
  log_error "Application kustomization not found: ${APPS_DIR}/kustomization.yaml"
  die 1 "Kustomization file must exist before applying applications"
fi
# Test kustomize build (dry-run)
TEMP_MANIFEST_TEST=$(mktemp) || TEMP_MANIFEST_TEST="/tmp/kustomize-test-$$.yaml"
if ! run_kubectl kustomize "${APPS_DIR}" > "${TEMP_MANIFEST_TEST}" 2>&1; then
  log_error "Kustomize build failed"
  log_error "Build output:"
  cat "${TEMP_MANIFEST_TEST}" >&2 || true
  rm -f "${TEMP_MANIFEST_TEST}"
  die 1 "Kustomize build must succeed before applying applications"
fi

# If ingress should be excluded, filter it out before checking for placeholders
if [ "${EXCLUDE_INGRESS}" = "true" ]; then
  TEMP_FILTERED_TEST=$(mktemp) || TEMP_FILTERED_TEST="/tmp/filtered-test-$$.yaml"
  awk '
    BEGIN {
      skip = 0;
      in_ingress = 0;
    }
    /^---$/ {
      if (!skip) {
        print;
      }
      skip = 0;
      in_ingress = 0;
      next;
    }
    /^kind:[[:space:]]*Ingress/ {
      in_ingress = 1;
      if ($0 ~ /REPLACE_PANEL_DOMAIN/) {
        skip = 1;
        next;
      }
    }
    /REPLACE_PANEL_DOMAIN/ {
      if (in_ingress) {
        skip = 1;
      }
    }
    {
      if (!skip) {
        print;
      }
    }
  ' "${TEMP_MANIFEST_TEST}" > "${TEMP_FILTERED_TEST}" 2>/dev/null || cp "${TEMP_MANIFEST_TEST}" "${TEMP_FILTERED_TEST}"
  mv "${TEMP_FILTERED_TEST}" "${TEMP_MANIFEST_TEST}"
fi

# Check for placeholder patterns in rendered manifest (after filtering)
if grep -qE "REPLACE_[A-Z_]+" "${TEMP_MANIFEST_TEST}" 2>/dev/null; then
  log_error "Rendered manifest contains placeholder values"
  log_error "Placeholders found:"
  grep -E "REPLACE_[A-Z_]+" "${TEMP_MANIFEST_TEST}" | head -n 10 >&2 || true
  rm -f "${TEMP_MANIFEST_TEST}"
  die 1 "Manifests must not contain placeholder values before applying applications"
fi
rm -f "${TEMP_MANIFEST_TEST}"
log_ok "All manifests render cleanly without placeholders"

log_ok "All validation gates passed (10/10)"

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
    # Filter out ingress resources if domain not provided in CI
    if [ "${EXCLUDE_INGRESS}" = "true" ]; then
      # Remove Ingress resources containing REPLACE_PANEL_DOMAIN
      # Use buffer-based approach: collect entire resource, then decide to print
      TEMP_FILTERED=$(mktemp) || TEMP_FILTERED="/tmp/filtered-$$"
      awk '
        BEGIN {
          RS = "\n---\n";
          ORS = "\n---\n";
        }
        {
          # Check if this resource is an Ingress containing REPLACE_PANEL_DOMAIN
          if ($0 ~ /^kind:[[:space:]]*Ingress/ && $0 ~ /REPLACE_PANEL_DOMAIN/) {
            # Skip this entire resource
            next;
          }
          # Otherwise, print the resource
          print;
        }
      ' "${TEMP_MANIFEST}" > "${TEMP_FILTERED}" 2>/dev/null || {
        # Fallback: line-by-line processing if RS approach fails
        awk '
          BEGIN {
            skip = 0;
            in_ingress = 0;
            buffer = "";
          }
          /^---$/ {
            if (!skip && buffer != "") {
              print buffer;
            }
            if (!skip) {
              print;
            }
            skip = 0;
            in_ingress = 0;
            buffer = "";
            next;
          }
          /^kind:[[:space:]]*Ingress/ {
            in_ingress = 1;
            buffer = $0 "\n";
            next;
          }
          /REPLACE_PANEL_DOMAIN/ {
            if (in_ingress) {
              skip = 1;
              buffer = "";
            }
          }
          {
            if (skip) {
              next;
            }
            if (in_ingress) {
              buffer = buffer $0 "\n";
            } else {
              print;
            }
          }
          END {
            if (!skip && buffer != "") {
              print buffer;
            }
          }
        ' "${TEMP_MANIFEST}" > "${TEMP_FILTERED}" 2>/dev/null || cp "${TEMP_MANIFEST}" "${TEMP_FILTERED}"
      }
      mv "${TEMP_FILTERED}" "${TEMP_MANIFEST}"
      log_info "Filtered out ingress resources (domain not provided in CI)"
    fi
    
    # Replace image references in the built manifest (handle both GNU and BSD sed)
    if sed --version >/dev/null 2>&1; then
      # GNU sed (Linux)
      sed -i "s|ghcr.io/[^/]*/voxeil-controller:[^[:space:]]*|${VOXEIL_CONTROLLER_IMAGE}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
      sed -i "s|ghcr.io/[^/]*/voxeil-panel:[^[:space:]]*|${VOXEIL_PANEL_IMAGE}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
      # Replace panel domain and TLS issuer if provided
      if [ -n "${PANEL_DOMAIN}" ] && [ "${PANEL_DOMAIN}" != "REPLACE_PANEL_DOMAIN" ]; then
        sed -i "s|REPLACE_PANEL_DOMAIN|${PANEL_DOMAIN}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
        log_info "Replaced panel domain: ${PANEL_DOMAIN}"
      fi
      if [ -n "${TLS_ISSUER}" ] && [ "${TLS_ISSUER}" != "REPLACE_PANEL_TLS_ISSUER" ]; then
        sed -i "s|REPLACE_PANEL_TLS_ISSUER|${TLS_ISSUER}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
        log_info "Replaced TLS issuer: ${TLS_ISSUER}"
      fi
    else
      # BSD sed (macOS) - requires empty string after -i
      sed -i '' "s|ghcr.io/[^/]*/voxeil-controller:[^[:space:]]*|${VOXEIL_CONTROLLER_IMAGE}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
      sed -i '' "s|ghcr.io/[^/]*/voxeil-panel:[^[:space:]]*|${VOXEIL_PANEL_IMAGE}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
      # Replace panel domain and TLS issuer if provided
      if [ -n "${PANEL_DOMAIN}" ] && [ "${PANEL_DOMAIN}" != "REPLACE_PANEL_DOMAIN" ]; then
        sed -i '' "s|REPLACE_PANEL_DOMAIN|${PANEL_DOMAIN}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
        log_info "Replaced panel domain: ${PANEL_DOMAIN}"
      fi
      if [ -n "${TLS_ISSUER}" ] && [ "${TLS_ISSUER}" != "REPLACE_PANEL_TLS_ISSUER" ]; then
        sed -i '' "s|REPLACE_PANEL_TLS_ISSUER|${TLS_ISSUER}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
        log_info "Replaced TLS issuer: ${TLS_ISSUER}"
      fi
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
  # Non-CI mode: also replace domain/TLS issuer if provided
  if [ -n "${PANEL_DOMAIN}" ] && [ "${PANEL_DOMAIN}" != "REPLACE_PANEL_DOMAIN" ]; then
    log_info "Replacing panel domain and TLS issuer in manifests..."
    TEMP_MANIFEST=$(mktemp) || TEMP_MANIFEST="/tmp/kustomize-$$.yaml"
    if run_kubectl kustomize "${APPS_DIR}" > "${TEMP_MANIFEST}" 2>&1; then
      if sed --version >/dev/null 2>&1; then
        sed -i "s|REPLACE_PANEL_DOMAIN|${PANEL_DOMAIN}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
        sed -i "s|REPLACE_PANEL_TLS_ISSUER|${TLS_ISSUER}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
      else
        sed -i '' "s|REPLACE_PANEL_DOMAIN|${PANEL_DOMAIN}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
        sed -i '' "s|REPLACE_PANEL_TLS_ISSUER|${TLS_ISSUER}|g" "${TEMP_MANIFEST}" 2>/dev/null || true
      fi
      log_info "Applying kustomization with domain/TLS replacements..."
      if ! run_kubectl apply -f "${TEMP_MANIFEST}"; then
        log_error "Failed to apply applications with domain/TLS replacements"
        rm -f "${TEMP_MANIFEST}"
        exit 1
      fi
      rm -f "${TEMP_MANIFEST}"
      log_ok "Applications applied with domain/TLS replacements"
    else
      log_warn "Failed to build kustomization for domain replacement, falling back to standard apply"
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

# Check controller-config PVC before rollout (controller requires it)
log_info "Checking controller-config PVC..."
if run_kubectl get pvc controller-config-pvc -n platform >/dev/null 2>&1; then
  pvc_phase=$(run_kubectl get pvc controller-config-pvc -n platform -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [ "${pvc_phase}" != "Bound" ]; then
    log_warn "controller-config-pvc is not bound (phase: ${pvc_phase}), waiting..."
    for i in $(seq 1 30); do
      pvc_phase=$(run_kubectl get pvc controller-config-pvc -n platform -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      if [ "${pvc_phase}" = "Bound" ]; then
        log_ok "controller-config-pvc is bound"
        break
      fi
      if [ $((i % 5)) -eq 0 ]; then
        log_info "Still waiting for controller-config-pvc... ($i/30) - Current phase: ${pvc_phase}"
      fi
      sleep 2
    done
    if [ "${pvc_phase}" != "Bound" ]; then
      log_error "controller-config-pvc not bound after 60s"
      run_kubectl get pvc controller-config-pvc -n platform -o yaml || true
      die 1 "controller-config-pvc must be bound before controller rollout"
    fi
  else
    log_ok "controller-config-pvc is bound"
  fi
else
  log_warn "controller-config-pvc not found (may be created by deployment)"
fi

wait_rollout_status "platform" "deployment" "controller" "${TIMEOUT}" "app=controller" || {
  # Additional diagnostics on failure
  log_error "Controller deployment failed - collecting additional diagnostics..."
  log_info "Controller pods status:"
  run_kubectl get pods -n platform -l app=controller -o wide 2>&1 || true
  log_info "Controller pod events:"
  run_kubectl get events -n platform --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp' 2>&1 | grep -i controller | tail -20 || true
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
