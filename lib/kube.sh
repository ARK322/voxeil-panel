#!/usr/bin/env bash
# Kubernetes utilities for Voxeil scripts
# Source this file: source "$(dirname "$0")/../lib/kube.sh"

# Source common first
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Global kubectl binary path (empty until resolved)
KUBECTL_BIN=""

# Resolve kubectl binary deterministically
resolve_kubectl() {
  # If already resolved, return success
  if [[ -n "${KUBECTL_BIN}" ]]; then
    return 0
  fi
  
  # Check for system kubectl binary first
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL_BIN="$(command -v kubectl)"
    return 0
  fi
  
  # Fallback to k3s kubectl wrapper
  if [[ -f /usr/local/bin/k3s ]]; then
    KUBECTL_BIN="/usr/local/bin/k3s kubectl"
    return 0
  fi
  
  # Check if k3s is in PATH
  if command -v k3s >/dev/null 2>&1; then
    KUBECTL_BIN="$(command -v k3s) kubectl"
    return 0
  fi
  
  # No kubectl found
  return 1
}

# Ensure kubectl is available
ensure_kubectl() {
  if ! resolve_kubectl; then
    log_error "kubectl not found and k3s not available"
    return 1
  fi
  return 0
}

# Run kubectl command with proper binary resolution
run_kubectl() {
  if ! resolve_kubectl; then
    log_error "kubectl not found and k3s not available"
    return 1
  fi
  
  # If KUBECTL_BIN contains space (e.g., "k3s kubectl"), split it
  if [[ "${KUBECTL_BIN}" == *" "* ]]; then
    # Split KUBECTL_BIN into array to handle spaces properly
    read -ra KUBECTL_ARRAY <<< "${KUBECTL_BIN}"
    set -- "${KUBECTL_ARRAY[@]}" "$@"
    "$@"
  else
    "${KUBECTL_BIN}" "$@"
  fi
}

# Check kubectl context
check_kubectl_context() {
  if ! run_kubectl cluster-info >/dev/null 2>&1; then
    log_error "kubectl cannot reach cluster. Check k3s installation."
    return 1
  fi
  local current_context
  current_context="$(run_kubectl config current-context 2>/dev/null || echo "default")"
  log_info "Current kubectl context: ${current_context}"
  return 0
}

# Wait for k3s API to be ready
wait_for_k3s_api() {
  log_info "Waiting for k3s API to be ready"
  local max_attempts=60
  local attempt=0
  
  while [ "${attempt}" -lt "${max_attempts}" ]; do
    if run_kubectl get --raw=/healthz >/dev/null 2>&1; then
      log_ok "k3s API is ready"
      return 0
    fi
    attempt=$((attempt + 1))
    if [ $((attempt % 10)) -eq 0 ]; then
      log_info "Still waiting for k3s API... (${attempt}/${max_attempts})"
    fi
    sleep 2
  done
  log_error "k3s API did not become ready after $((max_attempts * 2)) seconds"
  return 1
}

# Safe kubectl wrapper (with timeout, for uninstall)
kubectl_safe() {
  local timeout_s="${1:-10}"
  shift || true
  if ! resolve_kubectl; then
    log_error "kubectl not found and k3s not available"
    return 1
  fi
  # Build command string for timeout wrapper
  # Use printf %q to properly quote each argument for bash -c
  local cmd="${KUBECTL_BIN}"
  if [ $# -gt 0 ]; then
    for arg in "$@"; do
      cmd="${cmd} $(printf '%q' "$arg")"
    done
  fi
  run_with_timeout "${timeout_s}" "${cmd}"
}

# Run command with timeout (for uninstall)
run_with_timeout() {
  local timeout="${1}"
  shift
  local cmd="$*"
  local start_time=$(date +%s)
  local dry_run="${DRY_RUN:-false}"
  
  if [ "${dry_run}" = "true" ]; then
    echo "[DRY-RUN] ${cmd}"
    return 0
  fi
  
  if command_exists timeout; then
    if timeout "${timeout}" bash -c "${cmd}" 2>/dev/null; then
      return 0
    else
      local elapsed=$(($(date +%s) - start_time))
      if [ "${elapsed}" -ge "${timeout}" ]; then
        log_warn "Command timed out after ${timeout}s: ${cmd}"
        return 1
      fi
      return $?
    fi
  else
    bash -c "${cmd}" &
    local pid=$!
    local waited=0
    while kill -0 ${pid} 2>/dev/null && [ ${waited} -lt ${timeout} ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 ${pid} 2>/dev/null; then
      log_warn "Command timed out after ${timeout}s, killing: ${cmd}"
      kill -9 ${pid} 2>/dev/null || true
      return 1
    fi
    wait ${pid} 2>/dev/null || true
    return $?
  fi
}

# Idempotent kubectl apply helper
safe_apply() {
  local file="$1"
  local desc="${2:-${file}}"
  if ! run_kubectl apply -f "${file}" 2>&1; then
    log_error "Failed to apply ${desc}"
    return 1
  fi
  return 0
}

# Retry kubectl apply with exponential backoff (handles webhook timeouts)
retry_apply() {
  local file="$1"
  local desc="${2:-${file}}"
  local max_attempts="${3:-5}"
  local attempt=1
  local delay=2
  local output=""
  
  while [ "${attempt}" -le "${max_attempts}" ]; do
    output="$(run_kubectl apply --server-side --force-conflicts -f "${file}" 2>&1)"
    if [ $? -eq 0 ]; then
      return 0
    fi
    
    if echo "${output}" | grep -q "webhook.*timeout\|context deadline exceeded"; then
      if [ "${attempt}" -lt "${max_attempts}" ]; then
        log_warn "Webhook timeout detected (server-side), retrying in ${delay}s (attempt ${attempt}/${max_attempts})..."
        sleep "${delay}"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
        continue
      fi
    fi
    
    output="$(run_kubectl apply -f "${file}" 2>&1)"
    if [ $? -eq 0 ]; then
      return 0
    fi
    
    if echo "${output}" | grep -q "webhook.*timeout\|context deadline exceeded"; then
      if [ "${attempt}" -lt "${max_attempts}" ]; then
        log_warn "Webhook timeout detected, retrying in ${delay}s (attempt ${attempt}/${max_attempts})..."
        sleep "${delay}"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
        continue
      fi
    fi
    
    log_error "Failed to apply ${desc} after ${attempt} attempts"
    echo "${output}" >&2
    return 1
  done
}

# Wait for namespace to be ready
wait_ns_ready() {
  local namespace="$1"
  local timeout="${2:-30}"
  local waited=0
  
  while [ "${waited}" -lt "${timeout}" ]; do
    if run_kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      log_ok "Namespace ${namespace} ready"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  
  log_error "Namespace ${namespace} not ready after ${timeout}s"
  return 1
}

# Wait for deployment to be ready
wait_deploy_ready() {
  local namespace="$1"
  local deployment="$2"
  local timeout="${3:-${VOXEIL_WAIT_TIMEOUT}}"
  local waited=0
  
  log_info "Waiting for deployment ${deployment} in namespace ${namespace} (timeout: ${timeout}s)..."
  
  while [ "${waited}" -lt "${timeout}" ]; do
    if run_kubectl get deployment "${deployment}" -n "${namespace}" >/dev/null 2>&1; then
      local ready=$(run_kubectl get deployment "${deployment}" -n "${namespace}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      local desired=$(run_kubectl get deployment "${deployment}" -n "${namespace}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      if [ "${ready}" = "${desired}" ] && [ "${desired}" -gt 0 ]; then
        log_ok "Deployment ${deployment} ready (${ready}/${desired})"
        return 0
      fi
    fi
    if [ $((waited % 10)) -eq 0 ] && [ ${waited} -gt 0 ]; then
      log_info "Still waiting for deployment ${deployment}... (${waited}/${timeout}s)"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  
  log_error "Deployment ${deployment} not ready after ${timeout}s"
  return 1
}

# Wait for statefulset to be ready
wait_sts_ready() {
  local namespace="$1"
  local statefulset="$2"
  local timeout="${3:-${VOXEIL_WAIT_TIMEOUT}}"
  local waited=0
  
  log_info "Waiting for statefulset ${statefulset} in namespace ${namespace} (timeout: ${timeout}s)..."
  
  while [ "${waited}" -lt "${timeout}" ]; do
    if run_kubectl get statefulset "${statefulset}" -n "${namespace}" >/dev/null 2>&1; then
      local ready=$(run_kubectl get statefulset "${statefulset}" -n "${namespace}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      local desired=$(run_kubectl get statefulset "${statefulset}" -n "${namespace}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      if [ "${ready}" = "${desired}" ] && [ "${desired}" -gt 0 ]; then
        log_ok "Statefulset ${statefulset} ready (${ready}/${desired})"
        return 0
      fi
    fi
    if [ $((waited % 10)) -eq 0 ] && [ ${waited} -gt 0 ]; then
      log_info "Still waiting for statefulset ${statefulset}... (${waited}/${timeout}s)"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  
  log_error "Statefulset ${statefulset} not ready after ${timeout}s"
  return 1
}

# Debug dump for failed deployment/statefulset
dump_deployment_debug() {
  local namespace="$1"
  local resource_type="$2"  # deployment or statefulset
  local resource_name="$3"
  local label_selector="${4:-}"
  
  echo ""
  echo "=========================================="
  echo "DEBUG BUNDLE START"
  echo "=========================================="
  echo "Resource: ${resource_type}/${resource_name} in ${namespace}"
  
  # Pods status
  echo ""
  echo "--- Pods Status (${namespace}) ---"
  if [ -n "${label_selector}" ]; then
    run_kubectl get pods -n "${namespace}" -l "${label_selector}" -o wide 2>&1 || true
  else
    run_kubectl get pods -n "${namespace}" -o wide 2>&1 || true
  fi
  
  # Deployment/StatefulSet describe
  echo ""
  echo "--- ${resource_type} Describe: ${resource_name} ---"
  run_kubectl describe "${resource_type}" "${resource_name}" -n "${namespace}" 2>&1 | head -100 || true
  
  # Pods describe
  echo ""
  echo "--- Pods Describe (${namespace}) ---"
  if [ -n "${label_selector}" ]; then
    for pod in $(run_kubectl get pods -n "${namespace}" -l "${label_selector}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
      if [ -n "${pod}" ]; then
        echo "--- Pod: ${pod} ---"
        run_kubectl describe pod "${pod}" -n "${namespace}" 2>&1 | head -80 || true
      fi
    done
  else
    run_kubectl describe pods -n "${namespace}" 2>&1 | head -100 || true
  fi
  
  # Events (sorted by timestamp, most recent last)
  echo ""
  echo "--- Recent Events (${namespace}, sorted by timestamp) ---"
  run_kubectl get events -n "${namespace}" --sort-by='.lastTimestamp' 2>&1 | tail -120 || true
  
  # Pod logs (first pod found, all containers, tail 200)
  echo ""
  echo "--- Pod Logs (first pod, all containers, tail 200) ---"
  local first_pod
  if [ -n "${label_selector}" ]; then
    first_pod=$(run_kubectl get pods -n "${namespace}" -l "${label_selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  else
    first_pod=$(run_kubectl get pods -n "${namespace}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  fi
  
  if [ -n "${first_pod}" ]; then
    local containers
    containers=$(run_kubectl get pod "${first_pod}" -n "${namespace}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "")
    if [ -n "${containers}" ]; then
      for container in ${containers}; do
        echo "--- Logs: ${first_pod}/${container} ---"
        run_kubectl logs "${first_pod}" -n "${namespace}" -c "${container}" --tail=200 2>&1 || true
      done
    else
      # No containers found, try without container name
      run_kubectl logs "${first_pod}" -n "${namespace}" --tail=200 2>&1 || true
    fi
  else
    echo "No pods found for logging"
  fi
  
  echo ""
  echo "=========================================="
  echo "DEBUG BUNDLE END"
  echo "=========================================="
  echo ""
}

# Wait for rollout status (deployment or statefulset)
wait_rollout_status() {
  local namespace="$1"
  local resource_type="$2"  # deployment or statefulset
  local resource_name="$3"
  local timeout="${4:-${VOXEIL_WAIT_TIMEOUT}}"
  local label_selector="${5:-}"  # Optional label selector for pods
  
  log_info "Waiting for ${resource_type} ${resource_name} rollout in namespace ${namespace} (timeout: ${timeout}s)..."
  
  # Show current status before waiting
  if run_kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" >/dev/null 2>&1; then
    local current_status
    current_status=$(run_kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status},{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "unknown")
    log_info "  Current status: ${current_status}"
  fi
  
  # Use a progress monitor in the background to show periodic updates
  local start_time
  start_time=$(date +%s)
  local check_interval=30
  local last_check=0
  
  # Start rollout status check in background and capture output
  local rollout_output
  rollout_output=$(mktemp) || rollout_output="/tmp/rollout-$$.log"
  
  if run_kubectl rollout status "${resource_type}/${resource_name}" -n "${namespace}" --timeout="${timeout}s" >"${rollout_output}" 2>&1; then
    log_ok "${resource_type} ${resource_name} rollout complete"
    rm -f "${rollout_output}"
    return 0
  else
    local elapsed
    elapsed=$(($(date +%s) - start_time))
    log_error "${resource_type} ${resource_name} rollout failed or timed out after ${elapsed}s (timeout: ${timeout}s)"
    
    # Dump comprehensive debug information
    dump_deployment_debug "${namespace}" "${resource_type}" "${resource_name}" "${label_selector}"
    
    # Additional debug for controller (PostgreSQL connection issues)
    if [ "${resource_name}" = "controller" ] && [ "${namespace}" = "platform" ]; then
      echo ""
      echo "--- PostgreSQL Service Debug (controller connection) ---"
      run_kubectl describe svc postgres -n infra-db 2>&1 | head -30 || true
      echo ""
      run_kubectl get endpoints postgres -n infra-db -o wide 2>&1 || true
    fi
    
    # Show rollout output if available
    if [ -f "${rollout_output}" ] && [ -s "${rollout_output}" ]; then
      log_info "Rollout status output:"
      cat "${rollout_output}" | head -20 || true
    fi
    rm -f "${rollout_output}"
    return 1
  fi
}

# Wait for namespace deletion
wait_ns_deleted() {
  local namespace="$1"
  local timeout="${2:-${VOXEIL_WAIT_TIMEOUT}}"
  local waited=0
  local dry_run="${DRY_RUN:-false}"
  
  if [ "${dry_run}" = "true" ]; then
    return 0
  fi
  
  log_info "Waiting for namespace ${namespace} to be deleted (timeout: ${timeout}s)..."
  
  while [ "${waited}" -lt "${timeout}" ]; do
    if ! run_kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      log_ok "Namespace ${namespace} deleted"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
    if [ $((waited % 10)) -eq 0 ]; then
      log_info "Still waiting for namespace ${namespace} to be deleted... (${waited}/${timeout}s)"
    fi
  done
  
  log_warn "Namespace ${namespace} still exists after ${timeout}s"
  return 1
}

# Generic wait helper
wait_for() {
  local desc="$1"
  local timeout="$2"
  shift 2
  local start
  start=$(date +%s)
  local elapsed=0
  
  log_info "Waiting for ${desc} (timeout: ${timeout}s)..."
  
  while (( elapsed < timeout )); do
    if "$@"; then
      log_ok "${desc} ready"
      return 0
    fi
    sleep 2
    elapsed=$(($(date +%s) - start))
  done
  
  log_error "Timeout waiting for ${desc} after ${timeout}s"
  return 1
}
