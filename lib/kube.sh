#!/usr/bin/env bash
# Kubernetes utilities for Voxeil scripts
# Source this file: source "$(dirname "$0")/../lib/kube.sh"

# Source common first
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# kubectl wrapper with k3s fallback
kubectl() {
  local kubectl_type
  kubectl_type="$(type -t kubectl 2>/dev/null || echo "")"
  if [[ "${kubectl_type}" == "file" ]]; then
    command kubectl "$@"
  elif [[ -f /usr/local/bin/k3s ]]; then
    /usr/local/bin/k3s kubectl "$@"
  else
    log_error "kubectl not found and k3s not available"
    return 1
  fi
}

# Ensure kubectl is available
ensure_kubectl() {
  if ! command_exists kubectl && [[ ! -f /usr/local/bin/k3s ]]; then
    log_error "kubectl not found and k3s not available"
    return 1
  fi
  return 0
}

# Check kubectl context
check_kubectl_context() {
  if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "kubectl cannot reach cluster. Check k3s installation."
    return 1
  fi
  local current_context
  current_context="$(kubectl config current-context 2>/dev/null || echo "default")"
  log_info "Current kubectl context: ${current_context}"
  return 0
}

# Wait for k3s API to be ready
wait_for_k3s_api() {
  log_info "Waiting for k3s API to be ready"
  local max_attempts=60
  local attempt=0
  
  while [ ${attempt} -lt ${max_attempts} ]; do
    if kubectl get --raw=/healthz >/dev/null 2>&1; then
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
  run_with_timeout "${timeout_s}" "kubectl $*"
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
      if [ ${elapsed} -ge ${timeout} ]; then
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
  if ! kubectl apply -f "${file}" 2>&1; then
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
  
  while [ ${attempt} -le ${max_attempts} ]; do
    output="$(kubectl apply --server-side --force-conflicts -f "${file}" 2>&1)"
    if [ $? -eq 0 ]; then
      return 0
    fi
    
    if echo "${output}" | grep -q "webhook.*timeout\|context deadline exceeded"; then
      if [ ${attempt} -lt ${max_attempts} ]; then
        log_warn "Webhook timeout detected (server-side), retrying in ${delay}s (attempt ${attempt}/${max_attempts})..."
        sleep ${delay}
        delay=$((delay * 2))
        attempt=$((attempt + 1))
        continue
      fi
    fi
    
    output="$(kubectl apply -f "${file}" 2>&1)"
    if [ $? -eq 0 ]; then
      return 0
    fi
    
    if echo "${output}" | grep -q "webhook.*timeout\|context deadline exceeded"; then
      if [ ${attempt} -lt ${max_attempts} ]; then
        log_warn "Webhook timeout detected, retrying in ${delay}s (attempt ${attempt}/${max_attempts})..."
        sleep ${delay}
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
  
  while [ ${waited} -lt ${timeout} ]; do
    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
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
  local timeout="${3:-300}"
  local waited=0
  
  while [ ${waited} -lt ${timeout} ]; do
    if kubectl get deployment "${deployment}" -n "${namespace}" >/dev/null 2>&1; then
      local ready=$(kubectl get deployment "${deployment}" -n "${namespace}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      local desired=$(kubectl get deployment "${deployment}" -n "${namespace}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
      if [ "${ready}" = "${desired}" ] && [ "${desired}" -gt 0 ]; then
        log_ok "Deployment ${deployment} ready (${ready}/${desired})"
        return 0
      fi
    fi
    if [ $((waited % 10)) -eq 0 ] && [ ${waited} -gt 0 ]; then
      log_info "Waiting for deployment ${deployment}... (${waited}/${timeout}s)"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  
  log_error "Deployment ${deployment} not ready after ${timeout}s"
  return 1
}

# Wait for namespace deletion
wait_ns_deleted() {
  local namespace="$1"
  local timeout="${2:-90}"
  local waited=0
  local dry_run="${DRY_RUN:-false}"
  
  if [ "${dry_run}" = "true" ]; then
    return 0
  fi
  
  while [ ${waited} -lt ${timeout} ]; do
    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      log_ok "Namespace ${namespace} deleted"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
    if [ $((waited % 10)) -eq 0 ]; then
      log_info "Waiting for namespace ${namespace} to be deleted... (${waited}/${timeout}s)"
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
