#!/usr/bin/env bash
set -Eeuo pipefail

# ========= error handling and logging =========
LAST_COMMAND=""
STEP_COUNTER=0

log_step() {
  STEP_COUNTER=$((STEP_COUNTER + 1))
  echo ""
  echo "=== [STEP] ${STEP_COUNTER}: $1 ==="
}

log_info() {
  echo "=== [INFO] $1 ==="
}

log_warn() {
  echo "=== [WARN] $1 ==="
}

log_ok() {
  echo "=== [OK]   $1 ==="
}

log_error() {
  echo "=== [ERROR] $1 ===" >&2
}

# ========= Initialize RENDER_DIR early (before any usage) =========
RENDER_DIR="${RENDER_DIR:-$(mktemp -d)}"
if [[ ! -d "${RENDER_DIR}" ]]; then
  log_error "Failed to create temporary directory"
  exit 1
fi
export RENDER_DIR
# Cleanup temp dir on exit
cleanup_render_dir() {
  if [[ -n "${RENDER_DIR:-}" && -d "${RENDER_DIR}" ]]; then
    rm -rf "${RENDER_DIR}" || true
  fi
}
trap cleanup_render_dir EXIT

# Trap to log failed commands
trap 'LAST_COMMAND="${BASH_COMMAND}"; LAST_LINE="${LINENO}"' DEBUG
trap 'if [ $? -ne 0 ]; then
  log_error "Command failed at line ${LAST_LINE}: ${LAST_COMMAND}"
  exit 1
fi' ERR

# Configurable timeouts (can be overridden via env)
K3S_NODE_READY_TIMEOUT="${K3S_NODE_READY_TIMEOUT:-600}"
CERT_MANAGER_TIMEOUT="${CERT_MANAGER_TIMEOUT:-300}"
KYVERNO_TIMEOUT="${KYVERNO_TIMEOUT:-600}"
FLUX_TIMEOUT="${FLUX_TIMEOUT:-600}"
DEPLOYMENT_ROLLOUT_TIMEOUT="${DEPLOYMENT_ROLLOUT_TIMEOUT:-600}"
IMAGE_VALIDATION_TIMEOUT="${IMAGE_VALIDATION_TIMEOUT:-120}"

# ========= state registry =========
STATE_FILE="/var/lib/voxeil/install.state"

# Ensure state directory exists
ensure_state_dir() {
  mkdir -p "$(dirname "${STATE_FILE}")"
}

# Initialize state registry
init_state_registry() {
  ensure_state_dir
  touch "${STATE_FILE}"
  chmod 644 "${STATE_FILE}"
}

# Set state key=value
state_set() {
  local key="$1"
  local value="$2"
  init_state_registry
  if ! grep -q "^${key}=" "${STATE_FILE}" 2>/dev/null; then
    echo "${key}=${value}" >> "${STATE_FILE}"
  else
    if command -v sed >/dev/null 2>&1; then
      sed -i "s/^${key}=.*/${key}=${value}/" "${STATE_FILE}"
    else
      # Fallback if sed -i not available
      local temp_file
      temp_file="$(mktemp)"
      grep -v "^${key}=" "${STATE_FILE}" > "${temp_file}" 2>/dev/null || true
      echo "${key}=${value}" >> "${temp_file}"
      mv "${temp_file}" "${STATE_FILE}"
    fi
  fi
}

# Get state key with default
state_get() {
  local key="$1"
  local default="${2:-0}"
  if [ -f "${STATE_FILE}" ]; then
    grep "^${key}=" "${STATE_FILE}" 2>/dev/null | cut -d'=' -f2- || echo "${default}"
  else
    echo "${default}"
  fi
}

# Load state file safely (source if exists)
state_load() {
  if [ -f "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    set +u
    source "${STATE_FILE}" 2>/dev/null || true
    set -u
  fi
}

# Write state flag (backward compatibility)
write_state_flag() {
  state_set "$1" "1"
}

# Read state flag (backward compatibility)
read_state_flag() {
  state_get "$1" "0"
}

# Check if component is installed
is_installed() {
  local flag="$1"
  [ "$(read_state_flag "${flag}")" = "1" ]
}

# Label namespace with app.kubernetes.io/part-of=voxeil
label_namespace() {
  local namespace="$1"
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY-RUN] kubectl label namespace \"${namespace}\" app.kubernetes.io/part-of=voxeil --overwrite"
  else
    kubectl label namespace "${namespace}" app.kubernetes.io/part-of=voxeil --overwrite >/dev/null 2>&1 || true
  fi
}

# ========= helpers =========
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 || true; }
# Escape special characters for sed replacement string (| delimiter used, so only & needs escaping)
sed_escape() {
  echo "$1" | sed 's/&/\\&/g'
}
backup_apply() {
  kubectl apply -f "$1" || {
    log_error "Backup manifests failed to apply; aborting (backup is required)."
    exit 1
  }
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
    # Try server-side apply first (bypasses some webhook issues)
    output="$(kubectl apply --server-side --force-conflicts -f "${file}" 2>&1)"
    if [ $? -eq 0 ]; then
      return 0
    fi
    
    # Check if server-side apply failed due to webhook timeout
    if echo "${output}" | grep -q "webhook.*timeout\|context deadline exceeded"; then
      if [ ${attempt} -lt ${max_attempts} ]; then
        echo "Webhook timeout detected (server-side), retrying in ${delay}s (attempt ${attempt}/${max_attempts})..."
        sleep ${delay}
        delay=$((delay * 2))  # Exponential backoff
        attempt=$((attempt + 1))
        continue
      fi
    fi
    
    # If server-side fails for other reasons, try regular apply
    output="$(kubectl apply -f "${file}" 2>&1)"
    if [ $? -eq 0 ]; then
      return 0
    fi
    
    # Check if regular apply also failed due to webhook timeout
    if echo "${output}" | grep -q "webhook.*timeout\|context deadline exceeded"; then
      if [ ${attempt} -lt ${max_attempts} ]; then
        echo "Webhook timeout detected, retrying in ${delay}s (attempt ${attempt}/${max_attempts})..."
        sleep ${delay}
        delay=$((delay * 2))  # Exponential backoff
        attempt=$((attempt + 1))
        continue
      fi
    fi
    
    # If not a webhook timeout or max attempts reached, fail
    log_error "Failed to apply ${desc} after ${attempt} attempts"
    echo "${output}" >&2
    return 1
  done
  
  return 1
}

# Fix Kyverno cleanup jobs if they have image pull errors
# This ensures CronJobs use correct images and cleans up any failed jobs
fix_kyverno_cleanup_jobs() {
  local namespace="kyverno"
  local kyverno_manifest="${1:-}"
  
  # Check if kyverno namespace exists
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    return 0  # Kyverno not installed yet, nothing to fix
  fi
  
  log_info "Ensuring Kyverno cleanup CronJobs are properly configured..."
  
  # First, ensure CronJobs are updated with correct image from manifest
  if [ -n "${kyverno_manifest}" ] && [ -f "${kyverno_manifest}" ]; then
    log_info "Updating CronJobs with correct image configuration..."
    kubectl apply --server-side --force-conflicts -f "${kyverno_manifest}" >/dev/null 2>&1 || true
  fi
  
  # Find all cleanup job pods (both failed and running) that use old bitnami/kubectl images
  local cleanup_pods
  cleanup_pods="$(kubectl get pods -n "${namespace}" -l app.kubernetes.io/part-of=kyverno \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null | \
    grep -E "cleanup.*reports" | grep -v "alpine/k8s" | cut -f1 || true)"
  
  # Also find pods with ImagePullBackOff or ErrImagePull errors
  local failed_pods
  failed_pods="$(kubectl get pods -n "${namespace}" -l app.kubernetes.io/part-of=kyverno \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | \
    grep -E "(ImagePullBackOff|ErrImagePull)" | cut -f1 || true)"
  
  # Combine both lists and get unique job names
  local all_problem_pods
  all_problem_pods="$(echo -e "${cleanup_pods}\n${failed_pods}" | sort -u || true)"
  
  local fixed_count=0
  
  # Delete all problematic jobs and pods
  if [ -n "${all_problem_pods}" ]; then
    for pod in ${all_problem_pods}; do
      local job_name
      job_name="$(kubectl get pod "${pod}" -n "${namespace}" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Job")].name}' 2>/dev/null || true)"
      if [ -n "${job_name}" ]; then
        echo "  Cleaning up job: ${job_name} (pod: ${pod})"
        # Delete job first (this will also delete the pod)
        kubectl delete job "${job_name}" -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
          fixed_count=$((fixed_count + 1)) || true
        # Also delete pod directly as fallback (in case job deletion doesn't work)
        kubectl delete pod "${pod}" -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
      else
        # If no job owner, delete pod directly
        echo "  Cleaning up pod directly: ${pod}"
        kubectl delete pod "${pod}" -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
          fixed_count=$((fixed_count + 1)) || true
      fi
    done
    
    if [ ${fixed_count} -gt 0 ]; then
      echo "Cleaned up ${fixed_count} cleanup job(s)/pod(s). New jobs will be created by CronJob with correct image."
      # Wait a moment for resources to be cleaned up
      sleep 2
    fi
  fi
  
  # Verify CronJobs are using correct image
  echo "Verifying CronJob image configuration..."
  local cronjobs_ok=true
  for cronjob in kyverno-cleanup-admission-reports kyverno-cleanup-cluster-admission-reports; do
    local current_image
    current_image="$(kubectl get cronjob "${cronjob}" -n "${namespace}" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    if [ -n "${current_image}" ] && echo "${current_image}" | grep -q "bitnami/kubectl"; then
      echo "  Warning: ${cronjob} still using old image: ${current_image}"
      cronjobs_ok=false
    fi
  done
  
  if [ "${cronjobs_ok}" = "true" ]; then
    log_ok "All CronJobs are using correct images."
  else
    if [ -n "${kyverno_manifest}" ] && [ -f "${kyverno_manifest}" ]; then
      log_info "Re-applying manifest to force CronJob update..."
      kubectl apply --server-side --force-conflicts -f "${kyverno_manifest}" >/dev/null 2>&1 || true
    fi
  fi
  
  if [ ${fixed_count} -eq 0 ] && [ -z "${all_problem_pods}" ]; then
    log_ok "No cleanup job issues found."
  fi
}

# ========= Admission Webhook Safety Functions =========
# These functions prevent admission webhook deadlocks during installation/uninstallation

# Safely bootstrap Kyverno webhooks: set ALL webhooks to fail-open (failurePolicy=Ignore)
# and set timeoutSeconds to a small value (3-5 seconds) to prevent API lock
# This must patch ALL webhooks entries, not just index 0 (Kyverno configs have multiple webhooks)
safe_bootstrap_kyverno_webhooks() {
  log_info "Safe bootstrap: Setting Kyverno webhooks to fail-open (failurePolicy=Ignore) to prevent API lock..."
  
  # Find all Kyverno webhook configurations
  local validating_webhooks
  validating_webhooks="$(kubectl get validatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE 'kyverno' || true)"
  local mutating_webhooks
  mutating_webhooks="$(kubectl get mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE 'kyverno' || true)"
  
  # Patch validating webhooks - patch ALL webhooks entries, not just index 0
  for wh in ${validating_webhooks}; do
    log_info "Patching validating webhook: ${wh}"
    # Use python3 or jq to properly patch ALL webhooks entries
    if command -v python3 >/dev/null 2>&1; then
      kubectl get validatingwebhookconfiguration "${wh}" -o json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'webhooks' in data:
    for webhook in data['webhooks']:
        webhook['failurePolicy'] = 'Ignore'
        webhook['timeoutSeconds'] = 5
print(json.dumps(data))
" 2>/dev/null | kubectl apply -f - >/dev/null 2>&1 || true
    elif command -v jq >/dev/null 2>&1; then
      kubectl get validatingwebhookconfiguration "${wh}" -o json 2>/dev/null | \
        jq '.webhooks[] |= . + {"failurePolicy": "Ignore", "timeoutSeconds": 5}' 2>/dev/null | \
        kubectl apply -f - >/dev/null 2>&1 || true
    else
      # Fallback: try patch with type=json (may only patch first webhook, but better than nothing)
      kubectl patch validatingwebhookconfiguration "${wh}" \
        -p '{"webhooks":[{"failurePolicy":"Ignore","timeoutSeconds":5}]}' \
        --type=json 2>/dev/null || \
      kubectl patch validatingwebhookconfiguration "${wh}" \
        -p '{"webhooks":[{"failurePolicy":"Ignore","timeoutSeconds":5}]}' \
        --type=merge 2>/dev/null || true
    fi
  done
  
  # Patch mutating webhooks - patch ALL webhooks entries, not just index 0
  for wh in ${mutating_webhooks}; do
    log_info "Patching mutating webhook: ${wh}"
    # Use python3 or jq to properly patch ALL webhooks entries
    if command -v python3 >/dev/null 2>&1; then
      kubectl get mutatingwebhookconfiguration "${wh}" -o json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'webhooks' in data:
    for webhook in data['webhooks']:
        webhook['failurePolicy'] = 'Ignore'
        webhook['timeoutSeconds'] = 5
print(json.dumps(data))
" 2>/dev/null | kubectl apply -f - >/dev/null 2>&1 || true
    elif command -v jq >/dev/null 2>&1; then
      kubectl get mutatingwebhookconfiguration "${wh}" -o json 2>/dev/null | \
        jq '.webhooks[] |= . + {"failurePolicy": "Ignore", "timeoutSeconds": 5}' 2>/dev/null | \
        kubectl apply -f - >/dev/null 2>&1 || true
    else
      # Fallback: try patch with type=json (may only patch first webhook, but better than nothing)
      kubectl patch mutatingwebhookconfiguration "${wh}" \
        -p '{"webhooks":[{"failurePolicy":"Ignore","timeoutSeconds":5}]}' \
        --type=json 2>/dev/null || \
      kubectl patch mutatingwebhookconfiguration "${wh}" \
        -p '{"webhooks":[{"failurePolicy":"Ignore","timeoutSeconds":5}]}' \
        --type=merge 2>/dev/null || true
    fi
  done
  
  log_ok "Kyverno webhooks set to fail-open"
}

# Check if Kyverno webhook service is reachable
# Returns 0 if service is reachable, 1 otherwise
check_kyverno_service_reachable() {
  local namespace="${1:-kyverno}"
  local service_name="${2:-kyverno-svc}"
  local timeout="${3:-10}"
  
  # Check if service exists
  if ! kubectl get svc "${service_name}" -n "${namespace}" --request-timeout="${timeout}s" >/dev/null 2>&1; then
    return 1
  fi
  
  # Check if service has endpoints with at least 1 ready address
  local endpoints
  endpoints="$(kubectl get endpoints "${service_name}" -n "${namespace}" -o jsonpath='{.subsets[*].addresses[*].ip}' --request-timeout="${timeout}s" 2>/dev/null || echo "")"
  
  if [ -z "${endpoints}" ]; then
    return 1
  fi
  
  # Check if at least one endpoint IP exists
  local endpoint_count
  endpoint_count="$(echo "${endpoints}" | tr ' ' '\n' | grep -v '^$' | wc -l || echo "0")"
  
  if [ "${endpoint_count}" -gt 0 ]; then
    return 0
  fi
  
  return 1
}

# Harden Kyverno webhooks: set failurePolicy=Fail after service is reachable
# This restores proper security posture once Kyverno is healthy
harden_kyverno_webhooks() {
  log_info "Hardening Kyverno webhooks: Setting failurePolicy=Fail (service is reachable)..."
  
  # Find all Kyverno webhook configurations
  local validating_webhooks
  validating_webhooks="$(kubectl get validatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE 'kyverno' || true)"
  local mutating_webhooks
  mutating_webhooks="$(kubectl get mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE 'kyverno' || true)"
  
  # Patch validating webhooks - patch ALL webhooks entries
  for wh in ${validating_webhooks}; do
    log_info "Hardening validating webhook: ${wh}"
    # Use python3 or jq to properly patch ALL webhooks entries
    if command -v python3 >/dev/null 2>&1; then
      kubectl get validatingwebhookconfiguration "${wh}" -o json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'webhooks' in data:
    for webhook in data['webhooks']:
        webhook['failurePolicy'] = 'Fail'
        # Keep timeoutSeconds reasonable (default is usually 10s)
        if 'timeoutSeconds' not in webhook or webhook.get('timeoutSeconds', 0) < 5:
            webhook['timeoutSeconds'] = 10
print(json.dumps(data))
" 2>/dev/null | kubectl apply -f - >/dev/null 2>&1 || true
    elif command -v jq >/dev/null 2>&1; then
      kubectl get validatingwebhookconfiguration "${wh}" -o json 2>/dev/null | \
        jq '.webhooks[] |= . + {"failurePolicy": "Fail", "timeoutSeconds": 10}' 2>/dev/null | \
        kubectl apply -f - >/dev/null 2>&1 || true
    else
      # Fallback: try patch with type=json
      kubectl patch validatingwebhookconfiguration "${wh}" \
        -p '{"webhooks":[{"failurePolicy":"Fail","timeoutSeconds":10}]}' \
        --type=json 2>/dev/null || \
      kubectl patch validatingwebhookconfiguration "${wh}" \
        -p '{"webhooks":[{"failurePolicy":"Fail","timeoutSeconds":10}]}' \
        --type=merge 2>/dev/null || true
    fi
  done
  
  # Patch mutating webhooks - patch ALL webhooks entries
  for wh in ${mutating_webhooks}; do
    log_info "Hardening mutating webhook: ${wh}"
    # Use python3 or jq to properly patch ALL webhooks entries
    if command -v python3 >/dev/null 2>&1; then
      kubectl get mutatingwebhookconfiguration "${wh}" -o json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'webhooks' in data:
    for webhook in data['webhooks']:
        webhook['failurePolicy'] = 'Fail'
        # Keep timeoutSeconds reasonable (default is usually 10s)
        if 'timeoutSeconds' not in webhook or webhook.get('timeoutSeconds', 0) < 5:
            webhook['timeoutSeconds'] = 10
print(json.dumps(data))
" 2>/dev/null | kubectl apply -f - >/dev/null 2>&1 || true
    elif command -v jq >/dev/null 2>&1; then
      kubectl get mutatingwebhookconfiguration "${wh}" -o json 2>/dev/null | \
        jq '.webhooks[] |= . + {"failurePolicy": "Fail", "timeoutSeconds": 10}' 2>/dev/null | \
        kubectl apply -f - >/dev/null 2>&1 || true
    else
      # Fallback: try patch with type=json
      kubectl patch mutatingwebhookconfiguration "${wh}" \
        -p '{"webhooks":[{"failurePolicy":"Fail","timeoutSeconds":10}]}' \
        --type=json 2>/dev/null || \
      kubectl patch mutatingwebhookconfiguration "${wh}" \
        -p '{"webhooks":[{"failurePolicy":"Fail","timeoutSeconds":10}]}' \
        --type=merge 2>/dev/null || true
    fi
  done
  
  log_ok "Kyverno webhooks hardened (failurePolicy=Fail)"
}

# Self-heal wrapper for kubectl operations that may be blocked by admission webhooks
# If a kubectl command fails with webhook timeout, automatically run safe bootstrap and retry
kubectl_with_webhook_heal() {
  local cmd="$*"
  local output
  local exit_code
  
  # Try the command first
  output="$(eval "${cmd}" 2>&1)"
  exit_code=$?
  
  # If command succeeded, return
  if [ ${exit_code} -eq 0 ]; then
    echo "${output}"
    return 0
  fi
  
  # Check if error is related to Kyverno webhook timeout
  if echo "${output}" | grep -qiE "failed calling webhook.*kyverno|context deadline exceeded.*kyverno"; then
    log_warn "Kyverno webhook timeout detected, running safe bootstrap and retrying..."
    safe_bootstrap_kyverno_webhooks
    
    # Optionally scale down Kyverno admission controller temporarily if required
    if kubectl get deployment kyverno-admission-controller -n kyverno >/dev/null 2>&1; then
      log_info "Temporarily scaling down Kyverno admission controller to unblock..."
      kubectl scale deployment kyverno-admission-controller -n kyverno --replicas=0 --request-timeout=10s >/dev/null 2>&1 || true
      sleep 2
    fi
    
    # Retry the command once
    output="$(eval "${cmd}" 2>&1)"
    exit_code=$?
    
    if [ ${exit_code} -eq 0 ]; then
      log_ok "Command succeeded after webhook heal"
      echo "${output}"
      return 0
    else
      log_warn "Command still failed after webhook heal, but continuing..."
      echo "${output}" >&2
      return ${exit_code}
    fi
  fi
  
  # If error is not webhook-related, return original error
  echo "${output}" >&2
  return ${exit_code}
}

# Check kubectl context
check_kubectl_context() {
  if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "kubectl cannot reach cluster. Check k3s installation."
    return 1
  fi
  local current_context
  current_context="$(kubectl config current-context 2>/dev/null || echo "default")"
  echo "Current kubectl context: ${current_context}"
  return 0
}

# Wait for k3s API to be ready
wait_for_k3s_api() {
  log_step "Waiting for k3s API to be ready"
  local max_attempts=60
  local attempt=0
  while [ ${attempt} -lt ${max_attempts} ]; do
    if kubectl get --raw=/healthz >/dev/null 2>&1; then
      echo "k3s API is ready"
      return 0
    fi
    attempt=$((attempt + 1))
    if [ $((attempt % 10)) -eq 0 ]; then
      echo "Still waiting for k3s API... (${attempt}/${max_attempts})"
    fi
    sleep 2
  done
  log_error "k3s API did not become ready after $((max_attempts * 2)) seconds"
  return 1
}

# Check if StorageClass exists and log its volumeBindingMode
check_storageclass() {
  local sc_name="${1:-local-path}"
  local max_attempts=30
  local attempt=0
  
  # Retry loop to wait for StorageClass to be available (k3s may need a moment to create it)
  while [ ${attempt} -lt ${max_attempts} ]; do
    if kubectl get storageclass "${sc_name}" >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    if [ $((attempt % 5)) -eq 0 ]; then
      echo "Waiting for StorageClass '${sc_name}' to be available... (${attempt}/${max_attempts})"
    fi
    sleep 1
  done
  
  if ! kubectl get storageclass "${sc_name}" >/dev/null 2>&1; then
    log_error "StorageClass '${sc_name}' not found after ${max_attempts} attempts. k3s should provide this by default."
    echo "Available StorageClasses:"
    kubectl get storageclass || true
    return 1
  fi
  
  local sc_mode
  sc_mode="$(kubectl get sc "${sc_name}" -o jsonpath='{.volumeBindingMode}' 2>/dev/null || echo "")"
  
  if [ "${sc_mode}" = "WaitForFirstConsumer" ]; then
    echo "StorageClass '${sc_name}' exists with volumeBindingMode=WaitForFirstConsumer (OK for k3s local-path)."
  elif [ "${sc_mode}" = "Immediate" ]; then
    echo "StorageClass '${sc_name}' exists with volumeBindingMode=Immediate (OK)."
  else
    echo "StorageClass '${sc_name}' exists with volumeBindingMode=${sc_mode} (OK)."
  fi
  return 0
}

# Check network connectivity to a host
check_network_connectivity() {
  local host="$1"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --max-time 5 --connect-timeout 5 "https://${host}" >/dev/null 2>&1 || \
       curl -fsSL --max-time 5 --connect-timeout 5 "http://${host}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 2 "${host}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# Validate container image exists (for public images, check if pull would work)
validate_image() {
  local image="$1"
  local timeout="${2:-${IMAGE_VALIDATION_TIMEOUT}}"
  local registry=""
  local image_name=""
  
  echo "Validating image: ${image}"
  
  # First, check if image exists locally (even for remote tags)
  if docker image inspect "${image}" >/dev/null 2>&1; then
    echo "✓ Image ${image} exists locally"
    return 0
  fi
  
  # For local images (with :local tag) or backup images, only check locally
  if [[ "${image}" == *":local" ]] || [[ "${image}" == "backup-"* ]]; then
    log_error "Local image ${image} not found"
    echo "Build the image locally or use a different image tag."
    return 1
  fi
  
  # Extract registry from image name for connectivity check
  if [[ "${image}" =~ ^([^/]+)/(.+)$ ]]; then
    registry="${BASH_REMATCH[1]}"
    image_name="${BASH_REMATCH[2]}"
  fi
  
  # Check network connectivity to registry
  if [[ -n "${registry}" ]] && [[ "${registry}" != "localhost" ]] && [[ "${registry}" != "127.0.0.1" ]]; then
    echo "Checking network connectivity to ${registry}..."
    if ! check_network_connectivity "${registry}"; then
      log_error "Cannot reach registry ${registry}"
      echo "Network connectivity test failed. This may indicate:"
      echo "  - No internet connection"
      echo "  - Firewall blocking access to ${registry}"
      echo "  - DNS resolution issues"
      echo ""
      echo "Attempting to pull anyway (may work if connectivity test is too strict)..."
    else
      echo "✓ Network connectivity to ${registry} OK"
    fi
  fi
  
  # For remote images, first try manifest inspect (lighter weight, just checks existence)
  # This is much faster than a full pull and doesn't download the image
  echo "Checking if image manifest exists..."
  local manifest_output=""
  if command -v timeout >/dev/null 2>&1; then
    manifest_output="$(timeout 10 docker manifest inspect "${image}" 2>&1)" && {
      echo "✓ Image ${image} validated (manifest exists)"
      return 0
    } || true
  else
    manifest_output="$(docker manifest inspect "${image}" 2>&1)" && {
      echo "✓ Image ${image} validated (manifest exists)"
      return 0
    } || true
  fi
  
  # If manifest inspect failed, try to pull (with timeout and retry)
  # This is more expensive but works for some registries that don't support manifest inspect
  local pull_success=false
  local pull_output=""
  local max_retries=2
  
  echo "Manifest check failed, attempting to pull image..."
  
  for attempt in $(seq 1 ${max_retries}); do
    if [ ${attempt} -gt 1 ]; then
      echo "Retry attempt ${attempt}/${max_retries}..."
      sleep 2
    fi
    
    if command -v timeout >/dev/null 2>&1; then
      # Capture stderr for better error messages
      pull_output="$(timeout "${timeout}" docker pull "${image}" 2>&1)" && pull_success=true || pull_success=false
    else
      # Fallback: just try docker pull without timeout
      pull_output="$(docker pull "${image}" 2>&1)" && pull_success=true || pull_success=false
    fi
    
    if [ "${pull_success}" = true ]; then
      echo "✓ Image ${image} validated (pull successful)"
      # Remove the pulled image to save space (k3s will pull it when needed)
      docker rmi "${image}" >/dev/null 2>&1 || true
      return 0
    fi
  done
  
  # If we get here, both manifest and pull failed
  log_error "Failed to validate image ${image} after ${max_retries} attempts"
  
  # Analyze the error output for common issues
  local combined_output="${manifest_output}${pull_output}"
  if echo "${combined_output}" | grep -qi "unauthorized\|authentication required\|401\|denied"; then
    echo "Authentication/access error detected. This image may be private or not exist."
    echo "  - If this is a first-time installation, images may need to be built first"
    echo "  - Set GHCR_USERNAME and GHCR_TOKEN if the image is private"
    echo "  - Or build images locally: ./scripts/build-images.sh --tag local"
  elif echo "${combined_output}" | grep -qi "not found\|404\|manifest unknown\|name unknown"; then
    echo "Image not found at ${image}"
    echo "  - The image may not exist at this registry/tag"
    echo "  - This is normal for first-time installations"
    echo "  - Build images: ./scripts/build-images.sh --tag local"
    echo "  - Or push to registry: ./scripts/build-images.sh --push --tag latest"
  elif echo "${combined_output}" | grep -qi "timeout\|connection.*refused\|no route to host"; then
    echo "Network/connection error detected"
    echo "  - Check internet connectivity"
    echo "  - Check firewall rules"
    echo "  - Check DNS resolution"
  else
    echo "Validation failed. Error details:"
    if [ -n "${pull_output}" ]; then
      echo "${pull_output}" | tail -5 | sed 's/^/  /'
    elif [ -n "${manifest_output}" ]; then
      echo "${manifest_output}" | tail -5 | sed 's/^/  /'
    fi
  fi
  
  echo ""
  echo "This may indicate:"
  echo "  - Image does not exist at ${image}"
  echo "  - Network connectivity issues"
  echo "  - Authentication required (set GHCR_USERNAME and GHCR_TOKEN)"
  echo ""
  echo "To build images locally, run:"
  echo "  ./scripts/build-images.sh --tag local"
  echo ""
  echo "Or build and push to GHCR:"
  echo "  ./scripts/build-images.sh --push --tag latest"
  echo ""
  echo "If using private registry, ensure:"
  echo "  - GHCR_USERNAME and GHCR_TOKEN are set"
  echo "  - Image pull secret will be created in platform namespace"
  echo ""
  echo "You can also skip validation by setting:"
  echo "  export SKIP_IMAGE_VALIDATION=true"
  
  return 1
}

# Check for image pull errors in a namespace/deployment
check_image_pull_errors() {
  local namespace="$1"
  local deployment="$2"
  local image_name="${3:-}"
  
  # Check for pods with image pull errors
  local image_pull_pods
  image_pull_pods="$(kubectl get pods -n "${namespace}" -l app="${deployment}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\t"}{.status.containerStatuses[0].state.waiting.message}{"\n"}{end}' 2>/dev/null | \
    grep -E "(ImagePullBackOff|ErrImagePull|ImagePullError)" || true)"
  
  if [ -n "${image_pull_pods}" ]; then
    echo ""
    echo "⚠️  IMAGE PULL ERROR DETECTED for ${namespace}/${deployment}"
    echo ""
    
    # Extract pod name and error message
    local pod_name error_reason error_message
    while IFS=$'\t' read -r pod_name error_reason error_message; do
      echo "Pod: ${pod_name}"
      echo "Error: ${error_reason}"
      if [ -n "${error_message}" ]; then
        echo "Message: ${error_message}"
      fi
      echo ""
    done <<< "${image_pull_pods}"
    
    # Get image from deployment if not provided
    if [ -z "${image_name}" ]; then
      image_name="$(kubectl get deployment "${deployment}" -n "${namespace}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")"
    fi
    
    if [ -n "${image_name}" ]; then
      echo "Failed image: ${image_name}"
      echo ""
      echo "SOLUTIONS:"
      echo ""
      
      # Check if image is from GHCR
      if [[ "${image_name}" == *"ghcr.io"* ]]; then
        echo "1. If image is private, set authentication:"
        echo "   export GHCR_USERNAME=your-username"
        echo "   export GHCR_TOKEN=your-token"
        echo "   Then re-run the installer"
        echo ""
        echo "2. If image doesn't exist, build and push it:"
        echo "   ./scripts/build-images.sh --push --tag latest"
        echo ""
        echo "3. Or build locally and use local images:"
        echo "   ./scripts/build-images.sh --tag local"
        echo "   export CONTROLLER_IMAGE=ghcr.io/${GHCR_OWNER}/voxeil-controller:local"
        echo "   export PANEL_IMAGE=ghcr.io/${GHCR_OWNER}/voxeil-panel:local"
        echo "   Then re-run the installer"
      else
        echo "1. Check if the image exists: docker pull ${image_name}"
        echo "2. Verify network connectivity to the registry"
        echo "3. Check if authentication is required"
      fi
      
      echo ""
      echo "4. Skip image validation (not recommended):"
      echo "   export SKIP_IMAGE_VALIDATION=true"
      echo "   Then re-run the installer"
      echo ""
    fi
    
    # Show recent events related to image pull
    echo "--- Recent image pull events ---"
    kubectl get events -n "${namespace}" --sort-by='.lastTimestamp' | \
      grep -iE "image|pull|backoff|error" | tail -10 || true
    echo ""
    
    return 1
  fi
  
  return 0
}

# Diagnostic function for deployment failures
diagnose_deployment() {
  local namespace="$1"
  local deployment="$2"
  
  echo ""
  echo "=========================================="
  echo "DIAGNOSTIC REPORT: ${namespace}/${deployment}"
  echo "=========================================="
  echo ""
  
  # Check for image pull errors first
  local image_name
  image_name="$(kubectl get deployment "${deployment}" -n "${namespace}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")"
  check_image_pull_errors "${namespace}" "${deployment}" "${image_name}" || true
  
  echo "--- All pods in namespace ${namespace} ---"
  kubectl get pods -n "${namespace}" -o wide || true
  echo ""
  
  echo "--- Deployment status ---"
  kubectl get deployment "${deployment}" -n "${namespace}" || true
  echo ""
  
  echo "--- Deployment describe (full) ---"
  kubectl describe deployment "${deployment}" -n "${namespace}" || true
  echo ""
  
  echo "--- Deployment YAML (for inspection) ---"
  kubectl get deployment "${deployment}" -n "${namespace}" -o yaml || true
  echo ""
  
  echo "--- Pod details ---"
  local pods
  pods="$(kubectl get pods -n "${namespace}" -l app="${deployment}" -o name 2>/dev/null || true)"
  if [ -n "${pods}" ]; then
    for pod in ${pods}; do
      echo "--- Pod: ${pod} ---"
      kubectl describe "${pod}" -n "${namespace}" || true
      echo ""
      echo "--- Pod logs (last 200 lines) ---"
      kubectl logs "${pod}" -n "${namespace}" --tail=200 || true
      echo ""
    done
  else
    echo "No pods found with label app=${deployment}"
    echo "All pods in namespace:"
    kubectl get pods -n "${namespace}" || true
  fi
  echo ""
  
  echo "--- PVC status ---"
  kubectl get pvc -n "${namespace}" || true
  echo ""
  
  echo "--- StorageClass check ---"
  kubectl get storageclass || true
  echo ""
  
  echo "--- Recent events in namespace (last 50) ---"
  kubectl get events -n "${namespace}" --sort-by='.lastTimestamp' | tail -50 || true
  echo ""
  
  echo "--- Image pull errors ---"
  kubectl get events -n "${namespace}" --field-selector reason=Failed --sort-by='.lastTimestamp' | tail -20 || true
  echo ""
  
  echo "--- Kyverno admission denials ---"
  kubectl get events -n "${namespace}" --sort-by='.lastTimestamp' | grep -iE "kyverno|admission|deny|forbidden" | tail -20 || true
  echo ""
  
  echo "--- ServiceAccount and RBAC check ---"
  kubectl get serviceaccount -n "${namespace}" || true
  echo ""
  
  echo "--- Secrets check (platform-secrets must exist) ---"
  kubectl get secrets -n "${namespace}" || true
  echo ""
  
  echo "=========================================="
  echo "END DIAGNOSTIC REPORT"
  echo "=========================================="
  echo ""
}

ensure_docker() {
  log_step "Ensuring Docker is installed and running"
  
  # Check if docker command exists and daemon is reachable
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "Docker already installed and running."
    return 0
  fi

  # If --build-images is not set, Docker is optional - just warn and return
  if [ "${BUILD_IMAGES}" != "true" ]; then
    log_warn "Docker is not available, but image build is optional. Skipping Docker setup."
    log_info "Use --build-images flag if you need to build backup images."
    return 0
  fi

  # Docker missing or daemon not running - but --build-images is set, so we need it
  if ! command -v apt-get >/dev/null 2>&1; then
    log_error "Docker is required for backup image build, but automatic install is only supported on apt-get systems (Ubuntu/Debian)."
    exit 1
  fi

  # If Docker is partially installed but not working, completely remove it first
  if command -v docker >/dev/null 2>&1 || systemctl list-unit-files | grep -q docker.service 2>/dev/null; then
    echo "Docker partially installed but not working, removing completely..."
    
    # Stop Docker service
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop docker 2>/dev/null || true
      systemctl stop docker.socket 2>/dev/null || true
      systemctl stop containerd 2>/dev/null || true
      systemctl disable docker 2>/dev/null || true
      systemctl disable docker.socket 2>/dev/null || true
    else
      service docker stop 2>/dev/null || true
    fi
    
    # Remove Docker packages
    apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc 2>/dev/null || true
    apt-get purge -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc 2>/dev/null || true
    
    # Remove Docker data directories
    rm -rf /var/lib/docker 2>/dev/null || true
    rm -rf /var/lib/containerd 2>/dev/null || true
    rm -rf /etc/docker 2>/dev/null || true
    
    # Remove Docker socket
    rm -f /var/run/docker.sock 2>/dev/null || true
    rm -f /run/docker.sock 2>/dev/null || true
    
    # Clean up apt
    apt-get autoremove -y 2>/dev/null || true
    apt-get autoclean 2>/dev/null || true
    
    echo "Docker completely removed, will install fresh..."
  fi

  echo "Installing Docker..."
  apt-get update -y
  
  # Install required dependencies first
  apt-get install -y ca-certificates curl gnupg lsb-release || true
  
  # Install Docker
  apt-get install -y docker.io

  # Verify Docker binaries exist (common issue on Ubuntu where package installs but binaries are missing)
  echo "Verifying Docker installation..."
  DOCKERD_PATH=""
  if [ -f /usr/bin/dockerd ]; then
    DOCKERD_PATH="/usr/bin/dockerd"
  elif [ -f /usr/libexec/docker/dockerd ]; then
    DOCKERD_PATH="/usr/libexec/docker/dockerd"
  elif command -v dockerd >/dev/null 2>&1; then
    DOCKERD_PATH="$(command -v dockerd)"
  else
    echo "⚠️  Warning: dockerd binary not found after installation"
    echo "   This is a known issue with docker.io package on some Ubuntu systems"
    echo "   Attempting to fix by reinstalling Docker..."
    
    # Try to fix by reinstalling
    apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 2>/dev/null || true
    apt-get purge -y docker.io docker-doc docker-compose docker-compose-v2 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    
    # Try installing from official Docker repository instead
    echo "   Installing Docker from official Docker repository..."
    
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings 2>/dev/null || mkdir -p /etc/apt/keyrings
    if curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
      chmod a+r /etc/apt/keyrings/docker.asc
      
      # Detect distribution
      if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_CODENAME="${VERSION_CODENAME:-}"
      fi
      if [ -z "${DISTRO_CODENAME}" ] && command -v lsb_release >/dev/null 2>&1; then
        DISTRO_CODENAME="$(lsb_release -cs 2>/dev/null || echo "focal")"
      fi
      DISTRO_CODENAME="${DISTRO_CODENAME:-focal}"
      
      ARCH="$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
      echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${DISTRO_CODENAME} stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
      
      if apt-get update -y >/dev/null 2>&1; then
        if apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
          echo "   ✓ Successfully installed Docker from official repository"
        else
          echo "   Official Docker repository installation failed, falling back to docker.io..."
          apt-get install -y docker.io
        fi
      else
        echo "   Failed to update package lists, trying docker.io package again..."
        apt-get install -y docker.io
      fi
    else
      echo "   Failed to download Docker GPG key, trying docker.io package again..."
      apt-get install -y docker.io
    fi
    
    # Verify again after reinstall
    if [ -f /usr/bin/dockerd ]; then
      DOCKERD_PATH="/usr/bin/dockerd"
    elif command -v dockerd >/dev/null 2>&1; then
      DOCKERD_PATH="$(command -v dockerd)"
    else
      log_error "dockerd binary still not found after reinstallation attempts"
      echo "   Please check:"
      echo "   - dpkg -L docker.io | grep dockerd"
      echo "   - which dockerd"
      echo "   - ls -la /usr/bin/dockerd"
      exit 1
    fi
  fi
  
  echo "✓ Found dockerd at: ${DOCKERD_PATH}"
  
  # Verify docker client also exists
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker client binary not found"
    exit 1
  fi
  echo "✓ Found docker client: $(command -v docker)"

  # Ensure Docker daemon configuration directory exists
  mkdir -p /etc/docker

  # Check for required kernel modules
  echo "Checking for required kernel modules..."
  if ! lsmod | grep -q overlay; then
    echo "⚠️  Warning: overlay kernel module not loaded"
    echo "   Attempting to load overlay module..."
    modprobe overlay 2>/dev/null || echo "   Could not load overlay module (may need reboot)"
  fi
  if ! lsmod | grep -q br_netfilter; then
    echo "⚠️  Warning: br_netfilter kernel module not loaded"
    modprobe br_netfilter 2>/dev/null || true
  fi

  # Configure Docker daemon with basic settings (helps avoid common startup issues)
  # Use existing daemon.json if present, otherwise create a new one
  if [ ! -f /etc/docker/daemon.json ]; then
    echo "Creating Docker daemon configuration..."
    cat > /etc/docker/daemon.json <<EOF
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF
  else
    echo "Docker daemon.json already exists, preserving existing configuration"
  fi

  # Reload systemd to pick up any changes
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
  fi

  # Start and enable docker
  if command -v systemctl >/dev/null 2>&1; then
    # Enable docker socket first (required for docker.service)
    systemctl enable docker.socket 2>/dev/null || true
    systemctl start docker.socket 2>/dev/null || true
    sleep 2
    
    # Then enable and start docker service
    systemctl enable docker || {
      log_error "Failed to enable Docker service"
      exit 1
    }
    
    # Start docker service (don't exit on failure, we'll check status below)
    systemctl start docker || {
      echo "Docker service start command failed, checking status..."
    }
    sleep 5
    
    # Check if service started successfully
    if ! systemctl is-active --quiet docker; then
      echo ""
      echo "=========================================="
      echo "Docker service failed to start"
      echo "=========================================="
      echo ""
      
      echo "--- Docker service status ---"
      systemctl status docker --no-pager -l || true
      echo ""
      
      echo "--- Docker service logs (last 50 lines) ---"
      journalctl -u docker.service --no-pager -n 50 || true
      echo ""
      
      echo "--- Checking for common issues ---"
      
      # Check if dockerd binary exists (common issue)
      echo "Docker binary check:"
      if [ -f /usr/bin/dockerd ]; then
        echo "  ✓ /usr/bin/dockerd exists"
        ls -la /usr/bin/dockerd || true
      elif command -v dockerd >/dev/null 2>&1; then
        echo "  ✓ dockerd found at: $(command -v dockerd)"
        ls -la "$(command -v dockerd)" || true
      else
        echo "  ✗ dockerd binary NOT FOUND - this is the problem!"
        echo "     Docker package may be installed but binaries are missing"
        echo "     Checking installed Docker packages:"
        dpkg -l | grep -i docker || echo "     No Docker packages found"
        echo ""
        echo "     SOLUTION: Reinstall Docker:"
        echo "       apt-get remove -y docker.io"
        echo "       apt-get install -y docker.io"
        echo "       OR install from official Docker repository"
      fi
      echo ""
      
      # Check for AppArmor issues
      if command -v aa-status >/dev/null 2>&1; then
        echo "AppArmor status:"
        aa-status 2>/dev/null | head -10 || true
        echo ""
      fi
      
      # Check for storage driver issues
      echo "Docker data directory:"
      ls -la /var/lib/docker/ 2>/dev/null || echo "  Docker data directory missing or inaccessible"
      echo ""
      
      # Check for containerd conflicts (k3s uses containerd)
      if systemctl is-active --quiet containerd 2>/dev/null; then
        echo "⚠️  Warning: containerd service is running (k3s uses containerd)"
        echo "   This is normal - Docker and k3s can coexist, but may share containerd"
        echo ""
      fi
      
      # Check for socket issues
      echo "Docker socket status:"
      ls -la /var/run/docker.sock /run/docker.sock 2>/dev/null || echo "  Docker socket not found"
      echo ""
      
      # Check kernel modules
      echo "Required kernel modules:"
      echo "  overlay: $(lsmod | grep -q overlay && echo 'loaded' || echo 'NOT LOADED')"
      echo "  br_netfilter: $(lsmod | grep -q br_netfilter && echo 'loaded' || echo 'NOT LOADED')"
      echo "  ip_tables: $(lsmod | grep -q ip_tables && echo 'loaded' || echo 'NOT LOADED')"
      echo ""
      
      # Check systemd dependencies
      echo "Docker service dependencies:"
      systemctl list-dependencies docker.service --no-pager 2>/dev/null | head -20 || true
      echo ""
      
      # Check for failed dependencies
      echo "Failed systemd units:"
      systemctl --failed --no-pager 2>/dev/null || true
      echo ""
      
      # Try to get more detailed error from journalctl
      echo "--- Recent Docker-related systemd errors ---"
      journalctl -u docker.service --no-pager -n 100 | grep -iE "error|fail|denied|permission" | tail -20 || true
      echo ""
      
      # Check disk space
      echo "Disk space:"
      df -h /var/lib/docker 2>/dev/null || df -h / 2>/dev/null | head -2
      echo ""
      
      # Try to manually start docker daemon to see error (non-blocking)
      echo "--- Attempting to diagnose with dockerd --debug (5 seconds) ---"
      timeout 5 dockerd --debug 2>&1 | head -30 || {
        echo "  (dockerd debug output unavailable or timed out)"
      }
      echo ""
      
      echo "=========================================="
      echo "TROUBLESHOOTING STEPS:"
      echo "=========================================="
      echo ""
      
      # Check for missing dockerd binary
      if ! command -v dockerd >/dev/null 2>&1 && [ ! -f /usr/bin/dockerd ]; then
        echo "⚠️  CRITICAL: dockerd binary is missing!"
        echo ""
        echo "This is a known issue where docker.io package installs but binaries are missing."
        echo ""
        echo "SOLUTION 1 - Reinstall docker.io:"
        echo "  apt-get remove -y docker.io"
        echo "  apt-get install -y docker.io"
        echo "  systemctl start docker"
        echo ""
        echo "SOLUTION 2 - Install from official Docker repository:"
        echo "  apt-get remove -y docker.io"
        echo "  curl -fsSL https://get.docker.com -o get-docker.sh"
        echo "  sh get-docker.sh"
        echo "  systemctl start docker"
        echo ""
      else
        echo "1. Check the logs above for specific error messages"
        echo "2. Ensure you have sufficient disk space"
        echo "3. Check if AppArmor/SELinux is blocking Docker"
        echo "4. Verify Docker socket permissions: ls -la /var/run/docker.sock"
        echo "5. Try manually starting Docker: systemctl start docker"
        echo "6. Check for conflicting container runtimes"
        echo "7. Review systemd journal: journalctl -u docker.service -n 100"
        echo ""
        echo "If the issue persists, you may need to:"
        echo "  - Check system logs: journalctl -xe"
        echo "  - Verify kernel modules: lsmod | grep overlay"
        echo "  - Check for hardware/VM compatibility issues"
      fi
      echo ""
      
      log_error "Docker service failed to start. Please review the diagnostics above."
      exit 1
    fi
  else
    service docker start
    sleep 5
  fi

  # Check if Docker is working
  local retries=0
  local max_retries=10
  while [ $retries -lt $max_retries ]; do
    if docker info >/dev/null 2>&1; then
      echo "Docker installed and running successfully."
      return 0
    fi
    retries=$((retries + 1))
    echo "Waiting for Docker daemon to be ready... (attempt $retries/$max_retries)"
    sleep 2
  done

  log_error "Docker installation failed or daemon is not running."
  echo "Attempting to check docker status:"
  systemctl status docker --no-pager -l || service docker status || true
  echo ""
  echo "Docker service logs:"
  journalctl -u docker.service --no-pager -n 50 || true
  exit 1
}

PROMPT_IN="/dev/stdin"
if [[ ! -t 0 && -r /dev/tty ]]; then
  PROMPT_IN="/dev/tty"
fi

# ===== VOXEIL logo (wider spacing + cleaner layout) =====
ORANGE="\033[38;5;208m"
GRAY="\033[38;5;252m"
NC="\033[0m"

INNER=72  # biraz genişlettim (daha ferah)
strip_ansi() { echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g'; }

box_line_center() {
  local line="$1"
  local plain len pad_left pad_right
  plain="$(strip_ansi "$line")"
  len=${#plain}
  if (( len > INNER )); then
    plain="${plain:0:INNER}"
    line="$plain"
    len=$INNER
  fi
  pad_left=$(( (INNER - len) / 2 ))
  pad_right=$(( INNER - len - pad_left ))
  printf "║%*s%b%*s║\n" "$pad_left" "" "$line" "$pad_right" ""
}

echo
echo "╔════════════════════════════════════════════════════════════════════════╗"
printf "║%*s║\n" "$INNER" ""
printf "║%*s║\n" "$INNER" ""

# V (turuncu) + OXEIL (gri) — harf arası açık, daha geniş görünür
box_line_center "${ORANGE}██╗   ██╗${GRAY}  ██████╗   ██╗  ██╗  ███████╗  ██╗  ██╗${NC}"
box_line_center "${ORANGE}██║   ██║${GRAY} ██╔═══██╗  ╚██╗██╔╝  ██╔════╝  ██║  ██║${NC}"
box_line_center "${ORANGE}██║   ██║${GRAY} ██║   ██║   ╚███╔╝   █████╗    ██║  ██║${NC}"
box_line_center "${ORANGE}╚██╗ ██╔╝${GRAY} ██║   ██║   ██╔██╗   ██╔══╝    ██║  ██║${NC}"
box_line_center "${ORANGE} ╚████╔╝ ${GRAY} ╚██████╔╝  ██╔╝ ██╗  ███████╗  ██║   ███████╗${NC}"
box_line_center "${ORANGE}  ╚═══╝  ${GRAY}  ╚═════╝   ╚═╝  ╚═╝  ╚══════╝  ╚═╝   ╚══════╝${NC}"

printf "║%*s║\n" "$INNER" ""
box_line_center "${GRAY}VOXEIL PANEL${NC}"
box_line_center "${GRAY}Kubernetes Hosting Control Panel${NC}"
printf "║%*s║\n" "$INNER" ""
box_line_center "${GRAY}Secure • Isolated • Production-Grade Infrastructure${NC}"
printf "║%*s║\n" "$INNER" ""
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo
echo "== Voxeil Panel Installer =="
echo ""

# ========= Command-line arguments =========
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
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --doctor)
      DOCTOR=true
      shift
      ;;
    --skip-k3s)
      SKIP_K3S=true
      shift
      ;;
    --install-k3s)
      INSTALL_K3S=true
      shift
      ;;
    --kubeconfig)
      KUBECONFIG="$2"
      export KUBECONFIG
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      if [[ "${PROFILE}" != "minimal" && "${PROFILE}" != "full" ]]; then
        log_error "Invalid profile: ${PROFILE}. Must be 'minimal' or 'full'"
        exit 1
      fi
      shift 2
      ;;
    --with-mail)
      WITH_MAIL=true
      shift
      ;;
    --with-dns)
      WITH_DNS=true
      shift
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --channel)
      CHANNEL="$2"
      if [[ "${CHANNEL}" != "stable" && "${CHANNEL}" != "main" ]]; then
        log_error "Invalid channel: ${CHANNEL}. Must be 'stable' or 'main'"
        exit 1
      fi
      shift 2
      ;;
    --build-images)
      BUILD_IMAGES=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--doctor] [--dry-run] [--force] [--skip-k3s] [--install-k3s] [--kubeconfig <path>] [--profile minimal|full] [--with-mail] [--with-dns] [--version <tag|branch|commit>] [--channel stable|main] [--build-images]"
      exit 1
      ;;
  esac
done

# ========= Repository configuration =========
REPO="${REPO:-ARK322/voxeil-panel}"
if [ -n "${VERSION}" ]; then
  REF="${VERSION}"
elif [ "${CHANNEL}" = "stable" ]; then
  # Try to get latest tag, fallback to main
  REF="main"
else
  REF="${CHANNEL}"
fi

GITHUB_RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"

# ========= Remote file fetch helpers =========
# Ensure curl is available
ensure_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    log_info "curl not found, attempting to install..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y curl >/dev/null 2>&1 || {
        log_error "Failed to install curl. Please install curl manually: apt-get install -y curl"
        exit 1
      }
    else
      log_error "curl is required but not installed. Please install curl manually."
      exit 1
    fi
  fi
}

# Fetch a file from GitHub raw URL
fetch_file() {
  local repo_path="$1"
  local output_path="$2"
  local max_retries="${3:-5}"
  local retry_delay="${4:-1}"
  local attempt=1
  
  ensure_curl
  
  local url="${GITHUB_RAW_BASE}/${repo_path}"
  
  while [ ${attempt} -le ${max_retries} ]; do
    if curl -fL --retry 2 --retry-delay ${retry_delay} --max-time 30 -o "${output_path}" "${url}" 2>/dev/null; then
      # Validate file is non-empty
      if [ -s "${output_path}" ]; then
        return 0
      else
        log_warn "Downloaded file is empty: ${url} (attempt ${attempt}/${max_retries})"
      fi
    else
      log_warn "Failed to fetch ${url} (attempt ${attempt}/${max_retries})"
    fi
    
    if [ ${attempt} -lt ${max_retries} ]; then
      sleep ${retry_delay}
      retry_delay=$((retry_delay * 2))  # Exponential backoff
    fi
    attempt=$((attempt + 1))
  done
  
  log_error "Failed to fetch ${url} after ${max_retries} attempts"
  return 1
}

# Fetch and apply a YAML file
apply_remote_yaml() {
  local repo_path="$1"
  local desc="${2:-${repo_path}}"
  local tmp_file
  tmp_file="$(mktemp)"
  
  if ! fetch_file "${repo_path}" "${tmp_file}"; then
    rm -f "${tmp_file}"
    return 1
  fi
  
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY-RUN] kubectl apply -f ${tmp_file} (from ${repo_path})"
    rm -f "${tmp_file}"
    return 0
  fi
  
  if kubectl apply -f "${tmp_file}" >/dev/null 2>&1; then
    rm -f "${tmp_file}"
    return 0
  else
    log_error "Failed to apply ${desc}"
    rm -f "${tmp_file}"
    return 1
  fi
}

# Fetch a directory structure (recursively fetch all YAML files)
fetch_dir() {
  local repo_dir="$1"
  local local_dir="$2"
  local file_list
  
  ensure_curl
  
  # Create local directory
  mkdir -p "${local_dir}"
  
  # Try to get directory listing from GitHub API (limited, but works for known structure)
  # For now, we'll fetch known files explicitly
  # This is a simplified approach - in production, you might want to use GitHub API
  log_info "Fetching directory structure: ${repo_dir}"
  
  # Return success - actual files will be fetched individually
  return 0
}

# Run wrapper for dry-run support
run() {
  local cmd="$1"
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY-RUN] ${cmd}"
  else
    eval "${cmd}"
  fi
}

# Doctor mode - check for existing installation
if [ "${DOCTOR}" = "true" ]; then
  echo "=== Voxeil Panel Installer - Doctor Mode ==="
  echo ""
  echo "Scanning for installed components and leftover resources..."
  echo ""
  
  EXIT_CODE=0
  
  # Check state file
  echo "=== State Registry ==="
  if [ -f "${STATE_FILE}" ]; then
    echo "State file found at ${STATE_FILE}:"
    cat "${STATE_FILE}" | sed 's/^/  /'
    echo ""
  else
    echo "  ⚠ No state file found"
    EXIT_CODE=1
    echo ""
  fi
  
  # Check kubectl availability
  if ! command -v kubectl >/dev/null 2>&1 || ! kubectl cluster-info >/dev/null 2>&1; then
    echo "⚠ kubectl not available or cluster not accessible"
    echo "  Skipping Kubernetes resource checks"
    echo ""
    exit ${EXIT_CODE}
  fi
  
  # Check labeled resources
  echo "=== Resources with app.kubernetes.io/part-of=voxeil ==="
  
  echo "Namespaces:"
  VOXEIL_NS="$(kubectl get namespaces -l app.kubernetes.io/part-of=voxeil -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' || true)"
  if [ -n "${VOXEIL_NS}" ]; then
    echo "${VOXEIL_NS}" | while read -r ns; do
      echo "  - ${ns}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "All resources (pods, services, etc.):"
  VOXEIL_ALL="$(kubectl get all -A -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_ALL}" -gt 0 ]; then
    kubectl get all -A -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "ConfigMaps, Secrets, ServiceAccounts, Roles, RoleBindings, Ingresses, NetworkPolicies:"
  VOXEIL_OTHER="$(kubectl get cm,secret,sa,role,rolebinding,ingress,networkpolicy -A -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_OTHER}" -gt 0 ]; then
    kubectl get cm,secret,sa,role,rolebinding,ingress,networkpolicy -A -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "ClusterRoles and ClusterRoleBindings:"
  VOXEIL_CLUSTER="$(kubectl get clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_CLUSTER}" -gt 0 ]; then
    kubectl get clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "Webhooks:"
  VOXEIL_WEBHOOKS="$(kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_WEBHOOKS}" -gt 0 ]; then
    kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "CRDs:"
  VOXEIL_CRDS="$(kubectl get crd -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_CRDS}" -gt 0 ]; then
    kubectl get crd -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "PVCs:"
  VOXEIL_PVCS="$(kubectl get pvc -A -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_PVCS}" -gt 0 ]; then
    kubectl get pvc -A -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  # Check for unlabeled namespaces that might be voxeil-related
  echo ""
  echo "=== Unlabeled Namespaces (potential leftovers) ==="
  UNLABELED_NS="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^(platform|infra-db|dns-zone|mail-zone|backup-system|kyverno|flux-system|cert-manager|user-|tenant-)' || true)"
  if [ -n "${UNLABELED_NS}" ]; then
    echo "${UNLABELED_NS}" | while read -r ns; do
      if ! kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -q voxeil; then
        echo "  ⚠ ${ns} (not labeled)"
        EXIT_CODE=1
      fi
    done
  else
    echo "  ✓ None found"
  fi
  
  # Check PVs tied to voxeil namespaces
  echo ""
  echo "=== PersistentVolumes (checking claimRef) ==="
  VOXEIL_PVS=0
  for ns in platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      PVS="$(kubectl get pv -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); [print(pv['metadata']['name']) for pv in data.get('items', []) if pv.get('spec', {}).get('claimRef', {}).get('namespace') == '${ns}']" 2>/dev/null || true)"
      if [ -n "${PVS}" ]; then
        echo "  ⚠ PVs for namespace ${ns}:"
        echo "${PVS}" | while read -r pv; do
          echo "    - ${pv}"
        done
        VOXEIL_PVS=1
        EXIT_CODE=1
      fi
    fi
  done
  if [ ${VOXEIL_PVS} -eq 0 ]; then
    echo "  ✓ None found"
  fi
  
  echo ""
  if [ ${EXIT_CODE} -eq 0 ]; then
    echo "✓ System appears clean - no Voxeil resources detected"
  else
    echo "⚠ System has Voxeil resources or potential leftovers"
  fi
  
  exit ${EXIT_CODE}
fi

# Dry run mode
if [ "${DRY_RUN}" = "true" ]; then
  echo "=== DRY RUN MODE - No changes will be made ==="
  echo ""
fi

need_cmd curl
need_cmd sed
need_cmd mktemp
if ! command -v openssl >/dev/null 2>&1; then
  echo "Missing required command: openssl"
  exit 1
fi

GHCR_USERNAME="${GHCR_USERNAME:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
GHCR_EMAIL="${GHCR_EMAIL:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-ark322/voxeil-panel}"
# Extract owner from GITHUB_REPOSITORY and convert to lowercase (matches GitHub Actions workflow)
GHCR_OWNER_RAW="${GITHUB_REPOSITORY%%/*}"
GHCR_OWNER="${GHCR_OWNER:-$(echo "${GHCR_OWNER_RAW}" | tr '[:upper:]' '[:lower:]')}"
GHCR_REPO="${GHCR_REPO:-${GITHUB_REPOSITORY##*/}}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
PANEL_ADMIN_USERNAME="${PANEL_ADMIN_USERNAME:-}"
PANEL_ADMIN_PASSWORD="${PANEL_ADMIN_PASSWORD:-}"
PANEL_ADMIN_EMAIL="${PANEL_ADMIN_EMAIL:-}"
PGADMIN_EMAIL="${PGADMIN_EMAIL:-}"
PGADMIN_PASSWORD="${PGADMIN_PASSWORD:-}"
PGADMIN_AUTH_USER="${PGADMIN_AUTH_USER:-admin}"
PGADMIN_AUTH_PASS="${PGADMIN_AUTH_PASS:-}"
PANEL_AUTH_USER="${PANEL_AUTH_USER:-admin}"
PANEL_AUTH_PASS="${PANEL_AUTH_PASS:-}"
PGADMIN_DOMAIN="${PGADMIN_DOMAIN:-}"
MAILCOW_DOMAIN="${MAILCOW_DOMAIN:-}"
TSIG_SECRET="${TSIG_SECRET:-$(openssl rand -base64 32)}"
MAILCOW_AUTH_USER="${MAILCOW_AUTH_USER:-admin}"
MAILCOW_AUTH_PASS="${MAILCOW_AUTH_PASS:-}"

# ========= inputs (interactive, with defaults) =========
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PANEL_TLS_ISSUER="${PANEL_TLS_ISSUER:-letsencrypt-prod}"
SITE_PORT_START="${SITE_PORT_START:-31000}"
SITE_PORT_END="${SITE_PORT_END:-31999}"
# Use GHCR_OWNER (lowercase) to match GitHub Actions workflow
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-ghcr.io/${GHCR_OWNER}/voxeil-controller:${IMAGE_TAG}}"
PANEL_IMAGE="${PANEL_IMAGE:-ghcr.io/${GHCR_OWNER}/voxeil-panel:${IMAGE_TAG}}"

# Admin credentials (canonical names)
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_USERNAME="${ADMIN_USERNAME:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

# Helper to extract root domain (e.g., panel.voxeil.com -> voxeil.com)
extract_root_domain() {
  local domain="$1"
  if [[ "${domain}" =~ \. ]]; then
    # Remove leftmost label if 2+ labels exist
    echo "${domain#*.}"
  else
    # Single label, return as-is
    echo "${domain}"
  fi
}

prompt_with_default() {
  local label="$1"
  local current="$2"
  local input=""
  read -r -p "${label} [${current}]: " input < "${PROMPT_IN}"
  if [[ -n "${input}" ]]; then
    printf "%s" "${input}"
  else
    printf "%s" "${current}"
  fi
}

prompt_required() {
  local label="$1"
  local current="$2"
  local input=""
  while true; do
    if [[ -n "${current}" ]]; then
      read -r -p "${label} [${current}]: " input < "${PROMPT_IN}"
      if [[ -z "${input}" ]]; then
        printf "%s" "${current}"
        return
      fi
      printf "%s" "${input}"
      return
    else
      read -r -p "${label}: " input < "${PROMPT_IN}"
      if [[ -n "${input}" ]]; then
        printf "%s" "${input}"
        return
      fi
    fi
  done
}

prompt_password() {
  local label="$1"
  local input=""
  while true; do
    read -r -s -p "${label}: " input < "${PROMPT_IN}"
    echo "" >&2
    if [[ -n "${input}" ]]; then
      printf "%s" "${input}"
      return
    fi
    echo "Password cannot be empty. Please try again." >&2
  done
}

prompt_password_with_confirmation() {
  local label="$1"
  local password=""
  local confirm=""
  while true; do
    # First password
    while true; do
      read -r -s -p "${label}: " password < "${PROMPT_IN}"
      echo "" >&2
      if [[ -n "${password}" ]]; then
        break
      fi
      echo "Password cannot be empty. Please try again." >&2
    done
    
    # Confirm password
    while true; do
      read -r -s -p "Confirm ${label}: " confirm < "${PROMPT_IN}"
      echo "" >&2
      if [[ -n "${confirm}" ]]; then
        break
      fi
      echo "Password cannot be empty. Please try again." >&2
    done
    
    if [[ "${password}" == "${confirm}" ]]; then
      printf "%s" "${password}"
      return
    fi
    echo "Passwords do not match. Please try again." >&2
  done
}

echo ""
echo "== Config prompts =="

# Check if we have all required env vars (non-interactive mode)
# Support both new (ADMIN_*) and old (PANEL_ADMIN_*) variable names
HAS_ADMIN_EMAIL="${ADMIN_EMAIL:-${PANEL_ADMIN_EMAIL:-}}"
HAS_ADMIN_USERNAME="${ADMIN_USERNAME:-${PANEL_ADMIN_USERNAME:-}}"
HAS_ADMIN_PASSWORD="${ADMIN_PASSWORD:-${PANEL_ADMIN_PASSWORD:-}}"

if [[ -n "${PANEL_DOMAIN}" && -n "${HAS_ADMIN_EMAIL}" && -n "${HAS_ADMIN_USERNAME}" && -n "${HAS_ADMIN_PASSWORD}" ]]; then
  # All required vars provided, skip prompts
  echo "Using provided environment variables (non-interactive mode)"
else
  # Check if we have a TTY for interactive prompts
  if [[ ! -t 0 && ! -r /dev/tty ]]; then
    echo "ERROR: Non-interactive mode requires the following environment variables:"
    echo "  PANEL_DOMAIN (required)"
    echo "  ADMIN_EMAIL or PANEL_ADMIN_EMAIL (required)"
    echo "  ADMIN_USERNAME or PANEL_ADMIN_USERNAME (required, default: admin)"
    echo "  ADMIN_PASSWORD or PANEL_ADMIN_PASSWORD (required)"
    exit 1
  fi
fi

# Prompt for Panel domain (required)
if [[ -z "${PANEL_DOMAIN}" ]]; then
  PANEL_DOMAIN="$(prompt_required "Panel domain (e.g. panel.example.com)" "")"
fi

# Prompt for Admin email (required)
if [[ -z "${ADMIN_EMAIL}" ]]; then
  # Backwards compatibility: if PANEL_ADMIN_EMAIL is set, use it
  if [[ -n "${PANEL_ADMIN_EMAIL}" ]]; then
    ADMIN_EMAIL="${PANEL_ADMIN_EMAIL}"
  else
    ADMIN_EMAIL="$(prompt_required "Admin email" "")"
  fi
fi

# Validate email format (simple: must contain @ and . after @)
if [[ ! "${ADMIN_EMAIL}" =~ @ ]] || [[ ! "${ADMIN_EMAIL}" =~ @.*[.] ]]; then
  echo "ERROR: Invalid email format: ${ADMIN_EMAIL}"
  exit 1
fi

# Prompt for Admin username (default: admin)
if [[ -z "${ADMIN_USERNAME}" ]]; then
  # Backwards compatibility: if PANEL_ADMIN_USERNAME is set, use it
  if [[ -n "${PANEL_ADMIN_USERNAME}" ]]; then
    ADMIN_USERNAME="${PANEL_ADMIN_USERNAME}"
  else
    ADMIN_USERNAME="$(prompt_with_default "Admin username" "admin")"
  fi
fi

# Prompt for Admin password (required)
if [[ -z "${ADMIN_PASSWORD}" ]]; then
  # Backwards compatibility: if PANEL_ADMIN_PASSWORD is set, use it
  if [[ -n "${PANEL_ADMIN_PASSWORD}" ]]; then
    ADMIN_PASSWORD="${PANEL_ADMIN_PASSWORD}"
  else
    ADMIN_PASSWORD="$(prompt_password_with_confirmation "Admin password")"
  fi
fi

# Validate password is not empty
if [[ -z "${ADMIN_PASSWORD}" ]]; then
  echo "ERROR: Admin password cannot be empty"
  exit 1
fi

# Derive all credentials from single admin credentials
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-${ADMIN_EMAIL}}"
PANEL_ADMIN_EMAIL="${PANEL_ADMIN_EMAIL:-${ADMIN_EMAIL}}"
PANEL_ADMIN_USERNAME="${PANEL_ADMIN_USERNAME:-${ADMIN_USERNAME}}"
PANEL_ADMIN_PASSWORD="${PANEL_ADMIN_PASSWORD:-${ADMIN_PASSWORD}}"
PANEL_AUTH_USER="${PANEL_AUTH_USER:-${ADMIN_USERNAME}}"
PANEL_AUTH_PASS="${PANEL_AUTH_PASS:-${ADMIN_PASSWORD}}"
PGADMIN_EMAIL="${PGADMIN_EMAIL:-${ADMIN_EMAIL}}"
PGADMIN_PASSWORD="${PGADMIN_PASSWORD:-${ADMIN_PASSWORD}}"
PGADMIN_AUTH_USER="${PGADMIN_AUTH_USER:-${ADMIN_USERNAME}}"
PGADMIN_AUTH_PASS="${PGADMIN_AUTH_PASS:-${ADMIN_PASSWORD}}"
MAILCOW_AUTH_USER="${MAILCOW_AUTH_USER:-${ADMIN_USERNAME}}"
MAILCOW_AUTH_PASS="${MAILCOW_AUTH_PASS:-${ADMIN_PASSWORD}}"

# Derive domains from root domain
ROOT_DOMAIN="$(extract_root_domain "${PANEL_DOMAIN}")"
if [[ -z "${PGADMIN_DOMAIN}" ]]; then
  if [[ "${ROOT_DOMAIN}" != "${PANEL_DOMAIN}" ]]; then
    PGADMIN_DOMAIN="db.${ROOT_DOMAIN}"
  else
    PGADMIN_DOMAIN="pgadmin.${PANEL_DOMAIN}"
  fi
fi
if [[ -z "${MAILCOW_DOMAIN}" ]]; then
  if [[ "${ROOT_DOMAIN}" != "${PANEL_DOMAIN}" ]]; then
    MAILCOW_DOMAIN="mail.${ROOT_DOMAIN}"
  else
    MAILCOW_DOMAIN="mail.${PANEL_DOMAIN}"
  fi
fi

CONTROLLER_API_KEY="$(rand)"
# PANEL_ADMIN_PASSWORD already set from user input above (line 461-468)
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-$(rand)}}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${POSTGRES_ADMIN_PASSWORD}}"

# Generate JWT_SECRET for controller authentication
JWT_SECRET="${JWT_SECRET:-$(rand)}"
POSTGRES_HOST="${POSTGRES_HOST:-postgres.infra-db.svc.cluster.local}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
MAILCOW_API_URL="${MAILCOW_API_URL:-http://mailcow-api.mail-zone.svc.cluster.local}"
MAILCOW_API_KEY="${MAILCOW_API_KEY:-$(rand)}"
MAILCOW_TLS_ISSUER="${MAILCOW_TLS_ISSUER:-${PANEL_TLS_ISSUER}}"
MAILCOW_DB_NAME="${MAILCOW_DB_NAME:-mailcow}"
MAILCOW_DB_USER="${MAILCOW_DB_USER:-mailcow}"
MAILCOW_DB_PASSWORD="${MAILCOW_DB_PASSWORD:-$(rand)}"
MAILCOW_DB_ROOT_PASSWORD="${MAILCOW_DB_ROOT_PASSWORD:-$(rand)}"
BACKUP_TOKEN="${BACKUP_TOKEN:-$(rand)}"

echo ""
echo "Config:"
echo "  Panel domain: ${PANEL_DOMAIN}"
echo "  Panel TLS issuer: ${PANEL_TLS_ISSUER}"
echo "  Admin email: ${ADMIN_EMAIL}"
echo "  Admin username: ${ADMIN_USERNAME}"
echo "  pgAdmin domain: ${PGADMIN_DOMAIN}"
echo "  Mailcow UI domain: ${MAILCOW_DOMAIN}"
echo "  Site NodePort range: ${SITE_PORT_START}-${SITE_PORT_END}"
if [[ -n "${GHCR_USERNAME}" && -n "${GHCR_TOKEN}" ]]; then
  echo "  GHCR Username: ${GHCR_USERNAME}"
  echo "  GHCR Email: ${GHCR_EMAIL:-<none>}"
else
  echo "  GHCR: public images (no credentials)"
fi
echo "  Mailcow API URL: ${MAILCOW_API_URL}"
echo "  Let's Encrypt Email: ${LETSENCRYPT_EMAIL}"
echo "  TLS: enabled via cert-manager (site-based; opt-in)"
echo ""

# ========= Store installation metadata in state =========
INSTALL_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$(date +%s)")"
state_set "INSTALL_TIMESTAMP" "${INSTALL_TIMESTAMP}"
state_set "PANEL_DOMAIN" "${PANEL_DOMAIN}"
state_set "ADMIN_EMAIL" "${ADMIN_EMAIL}"
if [ -n "${VERSION}" ]; then
  state_set "VERSION" "${VERSION}"
elif [ -n "${REF}" ]; then
  state_set "VERSION" "${REF}"
fi

# ========= ensure docker is installed FIRST (before k3s) =========
ensure_docker

# ========= build backup images BEFORE k3s (optional, only if --build-images is set) =========
SKIP_BACKUP_BUILD=true
if [ "${BUILD_IMAGES}" = "true" ]; then
  log_step "Building backup images (before k3s)"
  
  # Check if Docker is actually available before attempting build
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    log_error "Docker is required for --build-images but is not available."
    log_error "Please install Docker first or remove --build-images flag."
    exit 1
  fi

  # Fetch backup-runner Dockerfile and build context
  BACKUP_RUNNER_BUILD_DIR="${RENDER_DIR}/backup-runner"
  mkdir -p "${BACKUP_RUNNER_BUILD_DIR}"

  log_info "Fetching backup-runner build context..."
  if ! fetch_file "infra/docker/images/backup-runner/Dockerfile" "${BACKUP_RUNNER_BUILD_DIR}/Dockerfile" "backup-runner Dockerfile"; then
    log_error "Failed to fetch backup-runner Dockerfile. Cannot build backup images."
    exit 1
  fi

  # Fetch backup-service Dockerfile and build context
  BACKUP_SERVICE_BUILD_DIR="${RENDER_DIR}/backup-service"
  mkdir -p "${BACKUP_SERVICE_BUILD_DIR}"

  log_info "Fetching backup-service build context..."
  if ! fetch_file "infra/docker/images/backup-service/Dockerfile" "${BACKUP_SERVICE_BUILD_DIR}/Dockerfile" "backup-service Dockerfile"; then
    log_error "Failed to fetch backup-service Dockerfile. Cannot build backup images."
    exit 1
  fi
  if ! fetch_file "infra/docker/images/backup-service/server.js" "${BACKUP_SERVICE_BUILD_DIR}/server.js" "backup-service server.js"; then
    log_error "Failed to fetch backup-service server.js. Cannot build backup images."
    exit 1
  fi

  # Use buildx if available, fallback to legacy builder
  BUILD_CMD="docker build"
  if docker buildx version >/dev/null 2>&1; then
    log_info "Using docker buildx"
    BUILD_CMD="docker buildx build --load"
  else
    log_info "Using legacy docker build (buildx not available)"
  fi

  # Build backup-runner image
  log_info "Building backup-runner:local..."
  if ${BUILD_CMD} -t backup-runner:local "${BACKUP_RUNNER_BUILD_DIR}" >/dev/null 2>&1; then
    # Verify image exists after build
    if docker image inspect backup-runner:local >/dev/null 2>&1; then
      log_ok "backup-runner:local built successfully"
    else
      log_error "backup-runner:local image not found after build"
      exit 1
    fi
  else
    log_error "Failed to build backup-runner image."
    exit 1
  fi

  # Build backup-service image
  log_info "Building backup-service:local..."
  if ${BUILD_CMD} -t backup-service:local "${BACKUP_SERVICE_BUILD_DIR}" >/dev/null 2>&1; then
    # Verify image exists after build
    if docker image inspect backup-service:local >/dev/null 2>&1; then
      log_ok "backup-service:local built successfully"
      SKIP_BACKUP_BUILD=false
    else
      log_error "backup-service:local image not found after build"
      exit 1
    fi
  else
    log_error "Failed to build backup-service image."
    exit 1
  fi
else
  log_info "Skipping backup image build (optional). Use --build-images to enable."
fi

# ========= install k3s if needed =========
log_step "Installing k3s (if needed)"

# Handle k3s installation based on flags
if [ "${SKIP_K3S}" = "true" ]; then
  if ! command -v kubectl >/dev/null 2>&1; then
    log_error "kubectl not found and --skip-k3s specified. Cannot proceed."
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "kubectl cannot reach cluster and --skip-k3s specified. Cannot proceed."
    exit 1
  fi
  log_info "Skipping k3s installation (--skip-k3s)"
elif [ "${INSTALL_K3S}" = "true" ]; then
  if ! command -v kubectl >/dev/null 2>&1; then
    log_info "Installing k3s..."
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
    write_state_flag "K3S_INSTALLED"
  else
    log_info "k3s already present (kubectl found), not reinstalling"
    if ! is_installed "K3S_INSTALLED"; then
      write_state_flag "K3S_INSTALLED"
    fi
  fi
else
  # Default behavior: install if kubectl not found, otherwise use existing
  if ! command -v kubectl >/dev/null 2>&1; then
    log_info "kubectl not found, installing k3s..."
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
    write_state_flag "K3S_INSTALLED"
  else
    log_info "kubectl found, using existing cluster"
    if ! is_installed "K3S_INSTALLED"; then
      write_state_flag "K3S_INSTALLED"
    fi
  fi
fi

need_cmd kubectl

# Set KUBECONFIG if provided
if [ -n "${KUBECONFIG}" ]; then
  export KUBECONFIG
  log_info "Using kubeconfig: ${KUBECONFIG}"
fi

# Wait for k3s API
wait_for_k3s_api

# Check kubectl context
check_kubectl_context

log_step "Waiting for node to be registered and ready"
log_info "Waiting for node to be registered..."
NODE_REGISTERED=false
for i in {1..60}; do
  if kubectl get nodes >/dev/null 2>&1 && [[ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -gt 0 ]]; then
    NODE_REGISTERED=true
    break
  fi
  sleep 2
done

if [[ "${NODE_REGISTERED}" != "true" ]]; then
  log_error "Node was not registered after 120 seconds"
  kubectl get nodes -o wide || true
  exit 1
fi

log_info "Node registered, waiting for Ready condition..."
# Poll first to ensure node resource exists before wait
for i in {1..30}; do
  if kubectl get nodes --no-headers 2>/dev/null | grep -q .; then
    break
  fi
  sleep 1
done

kubectl wait --for=condition=Ready node --all --timeout="${K3S_NODE_READY_TIMEOUT}s" || {
  log_error "Node did not become ready within ${K3S_NODE_READY_TIMEOUT}s"
  echo "Node status:"
  kubectl get nodes -o wide
  echo "Node describe:"
  kubectl describe nodes || true
  exit 1
}

# Verify StorageClass exists and log its configuration
log_step "Ensuring StorageClass is configured correctly"
if ! check_storageclass "local-path"; then
  log_error "local-path StorageClass missing. This will cause PVC issues."
  exit 1
fi
write_state_flag "STORAGE_INSTALLED"

# ========= Clean up any leftover resources from previous installations =========
log_step "Cleaning up leftover resources from previous installations"
echo "Checking for and cleaning up orphaned resources..."

# Preflight: Patch admission webhooks to prevent API lock during cleanup
# This is critical for Terminating namespaces that may be blocked by unreachable webhooks
log_info "Preflight: Patching admission webhooks to prevent API lock..."

# Find webhook configs by pattern (kyverno, cert-manager, flux)
webhook_patterns="kyverno cert-manager flux toolkit"
for pattern in ${webhook_patterns}; do
  # ValidatingWebhookConfigurations
  validating_webhooks="$(kubectl get validatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE "${pattern}" || true)"
  if [ -n "${validating_webhooks}" ]; then
    for wh in ${validating_webhooks}; do
      # Patch failurePolicy to Ignore to prevent API lock
      kubectl patch validatingwebhookconfiguration "${wh}" -p '{"webhooks":[{"failurePolicy":"Ignore"}]}' --type=json 2>/dev/null || \
      kubectl patch validatingwebhookconfiguration "${wh}" -p '{"webhooks":[{"failurePolicy":"Ignore"}]}' --type=merge 2>/dev/null || true
    done
  fi
  
  # MutatingWebhookConfigurations
  mutating_webhooks="$(kubectl get mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE "${pattern}" || true)"
  if [ -n "${mutating_webhooks}" ]; then
    for wh in ${mutating_webhooks}; do
      # Patch failurePolicy to Ignore to prevent API lock
      kubectl patch mutatingwebhookconfiguration "${wh}" -p '{"webhooks":[{"failurePolicy":"Ignore"}]}' --type=json 2>/dev/null || \
      kubectl patch mutatingwebhookconfiguration "${wh}" -p '{"webhooks":[{"failurePolicy":"Ignore"}]}' --type=merge 2>/dev/null || true
    done
  fi
done

# Clean up orphaned webhooks (if namespace deleted but webhooks remain)
orphaned_webhooks="$(kubectl get validatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE '(kyverno|cert-manager|flux)' || true)"
orphaned_mutating="$(kubectl get mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE '(kyverno|cert-manager|flux)' || true)"

if [ -n "${orphaned_webhooks}" ] || [ -n "${orphaned_mutating}" ]; then
  echo "  Found orphaned webhooks, attempting to delete..."
  for webhook in ${orphaned_webhooks}; do
    kubectl delete validatingwebhookconfiguration "${webhook}" --ignore-not-found=true >/dev/null 2>&1 || true
  done
  for webhook in ${orphaned_mutating}; do
    kubectl delete mutatingwebhookconfiguration "${webhook}" --ignore-not-found=true >/dev/null 2>&1 || true
  done
  echo "  ✓ Orphaned webhooks cleaned up"
fi

# Clean up stuck PVCs in Voxeil Panel namespaces (if they exist but namespace is being recreated)
# Also clean up PVCs stuck in Terminating state
for ns in platform infra-db dns-zone mail-zone backup-system; do
  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    # Namespace doesn't exist, but check for finalizers on PVCs (if any were left behind)
    pvcs="$(kubectl get pvc -A -o jsonpath="{range .items[?(@.metadata.namespace==\"${ns}\")]}{.metadata.name}{'\n'}{end}" 2>/dev/null || true)"
    if [ -n "${pvcs}" ]; then
      echo "  Found leftover PVCs for namespace ${ns}, cleaning up..."
      for pvc in ${pvcs}; do
        kubectl delete pvc "${pvc}" -n "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
      done
    fi
  else
    # Namespace exists, check for PVCs stuck in Terminating state
    terminating_pvcs="$(kubectl get pvc -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null | grep -v "^$" | cut -f1 || true)"
    if [ -n "${terminating_pvcs}" ]; then
      echo "  Found PVCs stuck in Terminating state in namespace ${ns}, attempting to fix..."
      for pvc in ${terminating_pvcs}; do
        echo "    Fixing PVC: ${pvc}"
        # Remove finalizers to allow PVC to be deleted
        kubectl patch pvc "${pvc}" -n "${ns}" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
        # Wait a moment for PVC to be deleted
        sleep 2
        # If still exists, try force delete
        if kubectl get pvc "${pvc}" -n "${ns}" >/dev/null 2>&1; then
          kubectl delete pvc "${pvc}" -n "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
        fi
      done
      # Wait a bit more for PVCs to be fully deleted
      sleep 3
    fi
  fi
done

# Clean up any stuck pods/jobs with image pull errors
echo "  Checking for stuck pods with image pull errors..."
cleaned_pods=0
for ns in platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager; do
  if kubectl get namespace "${ns}" >/dev/null 2>&1; then
    failed_pods="$(kubectl get pods -n "${ns}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | \
      grep -E "(ImagePullBackOff|ErrImagePull)" | cut -f1 || true)"
    
    if [ -n "${failed_pods}" ]; then
      for pod in ${failed_pods}; do
        job_name="$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Job")].name}' 2>/dev/null || true)"
        if [ -n "${job_name}" ]; then
          kubectl delete job "${job_name}" -n "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
            cleaned_pods=$((cleaned_pods + 1)) || true
        else
          kubectl delete pod "${pod}" -n "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
            cleaned_pods=$((cleaned_pods + 1)) || true
        fi
      done
    fi
  fi
done

if [ ${cleaned_pods} -gt 0 ]; then
  echo "  ✓ Cleaned up ${cleaned_pods} stuck pod(s)/job(s)"
else
  echo "  ✓ No stuck pods found"
fi

# Clean up any finalizers on namespaces that are stuck
echo "  Checking for namespaces stuck in Terminating state..."
for ns in platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager; do
  ns_phase="$(kubectl get namespace "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  if [ "${ns_phase}" = "Terminating" ]; then
    echo "  Found namespace ${ns} stuck in Terminating, attempting to fix..."
    # First try patch
    kubectl patch namespace "${ns}" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
    
    # Wait up to 60 seconds for namespace to be deleted
    waited=0
    while [ ${waited} -lt 60 ]; do
      if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
        echo "    ✓ Namespace ${ns} deleted"
        break
      fi
      sleep 2
      waited=$((waited + 2))
    done
    
    # If still exists, use /finalize endpoint
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      echo "    Attempting finalize endpoint cleanup for ${ns}..."
      if command -v python3 >/dev/null 2>&1; then
        kubectl get namespace "${ns}" -o json | python3 -c "import sys, json; data=json.load(sys.stdin); data['spec']['finalizers']=[]; print(json.dumps(data))" | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
      elif command -v jq >/dev/null 2>&1; then
        kubectl get namespace "${ns}" -o json | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
      else
        # Fallback: try patch again
        kubectl patch namespace "${ns}" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      fi
    fi
  fi
done

log_ok "Cleanup completed. Proceeding with installation..."

# ========= render manifests to temp dir =========
# RENDER_DIR is already initialized earlier, just ensure subdirectories exist
BACKUP_SYSTEM_NAME="backup-system"
SERVICES_DIR="${RENDER_DIR}/services"
TEMPLATES_DIR="${RENDER_DIR}/templates"
PLATFORM_DIR="${SERVICES_DIR}/platform"
BACKUP_SYSTEM_DIR="${SERVICES_DIR}/${BACKUP_SYSTEM_NAME}"

# Create directory structure
mkdir -p "${SERVICES_DIR}/platform"
mkdir -p "${SERVICES_DIR}/infra-db"
mkdir -p "${SERVICES_DIR}/dns-zone"
mkdir -p "${SERVICES_DIR}/mail-zone"
mkdir -p "${SERVICES_DIR}/backup-system"
mkdir -p "${SERVICES_DIR}/cert-manager"
mkdir -p "${SERVICES_DIR}/traefik"
mkdir -p "${SERVICES_DIR}/kyverno"
mkdir -p "${SERVICES_DIR}/flux-system"
mkdir -p "${TEMPLATES_DIR}"

# ========= Fetch manifests from GitHub =========
log_step "Fetching manifests from repository"

# Function to fetch a manifest file
fetch_manifest() {
  local repo_path="$1"
  local local_path="$2"
  local desc="${3:-${repo_path}}"
  
  # Create parent directory
  mkdir -p "$(dirname "${local_path}")"
  
  if ! fetch_file "${repo_path}" "${local_path}"; then
    log_error "Failed to fetch ${desc}"
    return 1
  fi
  return 0
}

# Fetch all required manifest files
log_info "Fetching platform manifests..."
fetch_manifest "infra/k8s/services/platform/namespace.yaml" "${PLATFORM_DIR}/namespace.yaml" "platform namespace"
fetch_manifest "infra/k8s/services/platform/rbac.yaml" "${PLATFORM_DIR}/rbac.yaml" "platform RBAC"
fetch_manifest "infra/k8s/services/platform/pvc.yaml" "${PLATFORM_DIR}/pvc.yaml" "platform PVC"
fetch_manifest "infra/k8s/services/platform/controller-deploy.yaml" "${PLATFORM_DIR}/controller-deploy.yaml" "controller deployment"
fetch_manifest "infra/k8s/services/platform/controller-svc.yaml" "${PLATFORM_DIR}/controller-svc.yaml" "controller service"
fetch_manifest "infra/k8s/services/platform/panel-deploy.yaml" "${PLATFORM_DIR}/panel-deploy.yaml" "panel deployment"
fetch_manifest "infra/k8s/services/platform/panel-svc.yaml" "${PLATFORM_DIR}/panel-svc.yaml" "panel service"
fetch_manifest "infra/k8s/services/platform/panel-ingress.yaml" "${PLATFORM_DIR}/panel-ingress.yaml" "panel ingress"
fetch_manifest "infra/k8s/services/platform/panel-auth.yaml" "${PLATFORM_DIR}/panel-auth.yaml" "panel auth"
fetch_manifest "infra/k8s/services/platform/panel-redirect.yaml" "${PLATFORM_DIR}/panel-redirect.yaml" "panel redirect"

log_info "Fetching infra-db manifests..."
fetch_manifest "infra/k8s/services/infra-db/namespace.yaml" "${SERVICES_DIR}/infra-db/namespace.yaml" "infra-db namespace"
fetch_manifest "infra/k8s/services/infra-db/postgres-secret.yaml" "${SERVICES_DIR}/infra-db/postgres-secret.yaml" "postgres secret"
fetch_manifest "infra/k8s/services/infra-db/pvc.yaml" "${SERVICES_DIR}/infra-db/pvc.yaml" "postgres PVC"
fetch_manifest "infra/k8s/services/infra-db/postgres-service.yaml" "${SERVICES_DIR}/infra-db/postgres-service.yaml" "postgres service"
fetch_manifest "infra/k8s/services/infra-db/postgres-statefulset.yaml" "${SERVICES_DIR}/infra-db/postgres-statefulset.yaml" "postgres statefulset"
fetch_manifest "infra/k8s/services/infra-db/networkpolicy.yaml" "${SERVICES_DIR}/infra-db/networkpolicy.yaml" "infra-db networkpolicy"
fetch_manifest "infra/k8s/services/infra-db/pgadmin-secret.yaml" "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml" "pgadmin secret"
fetch_manifest "infra/k8s/services/infra-db/pgadmin-auth.yaml" "${SERVICES_DIR}/infra-db/pgadmin-auth.yaml" "pgadmin auth"
fetch_manifest "infra/k8s/services/infra-db/pgadmin-svc.yaml" "${SERVICES_DIR}/infra-db/pgadmin-svc.yaml" "pgadmin service"
fetch_manifest "infra/k8s/services/infra-db/pgadmin-deploy.yaml" "${SERVICES_DIR}/infra-db/pgadmin-deploy.yaml" "pgadmin deployment"
fetch_manifest "infra/k8s/services/infra-db/pgadmin-ingress.yaml" "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml" "pgadmin ingress"

if [ "${WITH_DNS}" = "true" ]; then
  log_info "Fetching DNS manifests..."
  fetch_manifest "infra/k8s/services/dns-zone/namespace.yaml" "${SERVICES_DIR}/dns-zone/namespace.yaml" "dns-zone namespace"
  fetch_manifest "infra/k8s/services/dns-zone/tsig-secret.yaml" "${SERVICES_DIR}/dns-zone/tsig-secret.yaml" "dns tsig secret"
  fetch_manifest "infra/k8s/services/dns-zone/pvc.yaml" "${SERVICES_DIR}/dns-zone/pvc.yaml" "dns PVC"
  fetch_manifest "infra/k8s/services/dns-zone/bind9.yaml" "${SERVICES_DIR}/dns-zone/bind9.yaml" "bind9 deployment"
  # Fetch traefik-tcp directory files
  fetch_manifest "infra/k8s/services/dns-zone/traefik-tcp/dns-routes.yaml" "${SERVICES_DIR}/dns-zone/traefik-tcp/dns-routes.yaml" "dns traefik routes" || true
fi

if [ "${WITH_MAIL}" = "true" ]; then
  log_info "Fetching mail manifests..."
  fetch_manifest "infra/k8s/services/mail-zone/namespace.yaml" "${SERVICES_DIR}/mail-zone/namespace.yaml" "mail-zone namespace"
  fetch_manifest "infra/k8s/services/mail-zone/mailcow-auth.yaml" "${SERVICES_DIR}/mail-zone/mailcow-auth.yaml" "mailcow auth"
  fetch_manifest "infra/k8s/services/mail-zone/mailcow-core.yaml" "${SERVICES_DIR}/mail-zone/mailcow-core.yaml" "mailcow core"
  fetch_manifest "infra/k8s/services/mail-zone/networkpolicy.yaml" "${SERVICES_DIR}/mail-zone/networkpolicy.yaml" "mail networkpolicy"
  fetch_manifest "infra/k8s/services/mail-zone/mailcow-ingress.yaml" "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml" "mailcow ingress"
  # Fetch traefik-tcp directory files
  fetch_manifest "infra/k8s/services/mail-zone/traefik-tcp/ingressroutetcp.yaml" "${SERVICES_DIR}/mail-zone/traefik-tcp/ingressroutetcp.yaml" "mail traefik routes" || true
fi

log_info "Fetching backup-system manifests..."
fetch_manifest "infra/k8s/services/backup-system/namespace.yaml" "${BACKUP_SYSTEM_DIR}/namespace.yaml" "backup-system namespace"
fetch_manifest "infra/k8s/services/backup-system/backup-scripts-configmap.yaml" "${BACKUP_SYSTEM_DIR}/backup-scripts-configmap.yaml" "backup scripts"
fetch_manifest "infra/k8s/services/backup-system/backup-service-secret.yaml" "${BACKUP_SYSTEM_DIR}/backup-service-secret.yaml" "backup service secret"
fetch_manifest "infra/k8s/services/backup-system/backup-service-deploy.yaml" "${BACKUP_SYSTEM_DIR}/backup-service-deploy.yaml" "backup service deployment"
fetch_manifest "infra/k8s/services/backup-system/backup-service-svc.yaml" "${BACKUP_SYSTEM_DIR}/backup-service-svc.yaml" "backup service"
fetch_manifest "infra/k8s/services/backup-system/backup-job-templates-configmap.yaml" "${BACKUP_SYSTEM_DIR}/backup-job-templates-configmap.yaml" "backup job templates"
fetch_manifest "infra/k8s/services/backup-system/rbac.yaml" "${BACKUP_SYSTEM_DIR}/rbac.yaml" "backup RBAC"
fetch_manifest "infra/k8s/services/backup-system/serviceaccount.yaml" "${BACKUP_SYSTEM_DIR}/serviceaccount.yaml" "backup serviceaccount"

if [ "${PROFILE}" = "full" ]; then
  log_info "Fetching cert-manager manifests..."
  fetch_manifest "infra/k8s/services/cert-manager/cert-manager.yaml" "${SERVICES_DIR}/cert-manager/cert-manager.yaml" "cert-manager"
  fetch_manifest "infra/k8s/services/cert-manager/cluster-issuers.yaml" "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml" "cert-manager cluster issuers"
  
  log_info "Fetching Kyverno manifests..."
  fetch_manifest "infra/k8s/services/kyverno/namespace.yaml" "${SERVICES_DIR}/kyverno/namespace.yaml" "kyverno namespace"
  fetch_manifest "infra/k8s/services/kyverno/install.yaml" "${SERVICES_DIR}/kyverno/install.yaml" "kyverno install"
  fetch_manifest "infra/k8s/services/kyverno/policies.yaml" "${SERVICES_DIR}/kyverno/policies.yaml" "kyverno policies"
  
  log_info "Fetching Flux manifests..."
  fetch_manifest "infra/k8s/services/flux-system/namespace.yaml" "${SERVICES_DIR}/flux-system/namespace.yaml" "flux-system namespace"
  # Flux install.yaml is downloaded dynamically later
fi

log_info "Fetching Traefik manifests..."
fetch_manifest "infra/k8s/services/traefik/helmchartconfig-traefik.yaml" "${SERVICES_DIR}/traefik/helmchartconfig-traefik.yaml" "traefik config"

log_ok "All manifests fetched successfully"

if command -v htpasswd >/dev/null 2>&1; then
  bcrypt_line() {
    htpasswd -nbB "$1" "$2"
  }
elif command -v python3 >/dev/null 2>&1; then
  bcrypt_line() {
    local user="$1"
    local pass="$2"
    local salt=""
    salt="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 22 || true)"
    if [[ -z "${salt}" ]]; then
      salt="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22 || true)"
    fi
    python3 - "${user}" "${pass}" "${salt}" <<'PY'
import crypt
import sys

user, password, salt = sys.argv[1], sys.argv[2], sys.argv[3]
hashed = crypt.crypt(password, f"$2b$12${salt}")
print(f"{user}:{hashed}")
PY
  }
else
  echo "Missing required command: htpasswd (apache2-utils) or python3 for bcrypt generation"
  exit 1
fi
PGADMIN_BASICAUTH="$(bcrypt_line "${PGADMIN_AUTH_USER}" "${PGADMIN_AUTH_PASS}")"
MAILCOW_BASICAUTH="$(bcrypt_line "${MAILCOW_AUTH_USER}" "${MAILCOW_AUTH_PASS}")"
PANEL_BASICAUTH="$(bcrypt_line "${PANEL_AUTH_USER}" "${PANEL_AUTH_PASS}")"
PANEL_BASICAUTH_B64="$(printf "%s" "${PANEL_BASICAUTH}" | base64 | tr -d '\n')"

cat > "${PLATFORM_DIR}/platform-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: platform-secrets
  namespace: platform
type: Opaque
stringData:
  ADMIN_API_KEY: "${CONTROLLER_API_KEY}"
  JWT_SECRET: "${JWT_SECRET}"
  PANEL_ADMIN_USERNAME: "${PANEL_ADMIN_USERNAME}"
  PANEL_ADMIN_EMAIL: "${PANEL_ADMIN_EMAIL}"
  PANEL_ADMIN_PASSWORD: "${PANEL_ADMIN_PASSWORD}"
  SITE_NODEPORT_START: "${SITE_PORT_START}"
  SITE_NODEPORT_END: "${SITE_PORT_END}"
  MAILCOW_API_URL: "${MAILCOW_API_URL}"
  MAILCOW_API_KEY: "${MAILCOW_API_KEY}"
  POSTGRES_HOST: "${POSTGRES_HOST}"
  POSTGRES_PORT: "${POSTGRES_PORT}"
  POSTGRES_ADMIN_USER: "${POSTGRES_ADMIN_USER}"
  POSTGRES_ADMIN_PASSWORD: "${POSTGRES_ADMIN_PASSWORD}"
  POSTGRES_DB: "${POSTGRES_DB}"
EOF

cat > "${SERVICES_DIR}/mail-zone/mailcow-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mailcow-secrets
  namespace: mail-zone
type: Opaque
stringData:
  MYSQL_DATABASE: "${MAILCOW_DB_NAME}"
  MYSQL_USER: "${MAILCOW_DB_USER}"
  MYSQL_PASSWORD: "${MAILCOW_DB_PASSWORD}"
  MYSQL_ROOT_PASSWORD: "${MAILCOW_DB_ROOT_PASSWORD}"
EOF

log_step "Templating manifests"

# Check critical manifest files exist before templating
REQUIRED_MANIFESTS=(
  "${PLATFORM_DIR}/controller-deploy.yaml"
  "${PLATFORM_DIR}/panel-deploy.yaml"
  "${PLATFORM_DIR}/panel-ingress.yaml"
  "${PLATFORM_DIR}/panel-auth.yaml"
  "${SERVICES_DIR}/infra-db/postgres-secret.yaml"
  "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml"
  "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml"
  "${SERVICES_DIR}/infra-db/pgadmin-auth.yaml"
)

if [ "${PROFILE}" = "full" ]; then
  REQUIRED_MANIFESTS+=("${SERVICES_DIR}/cert-manager/cluster-issuers.yaml")
fi

if [ "${WITH_MAIL}" = "true" ]; then
  REQUIRED_MANIFESTS+=(
    "${SERVICES_DIR}/mail-zone/mailcow-core.yaml"
    "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml"
    "${SERVICES_DIR}/mail-zone/mailcow-auth.yaml"
  )
fi

if [ "${WITH_DNS}" = "true" ]; then
  REQUIRED_MANIFESTS+=("${SERVICES_DIR}/dns-zone/tsig-secret.yaml")
fi

for manifest in "${REQUIRED_MANIFESTS[@]}"; do
  if [[ ! -f "${manifest}" ]]; then
    log_error "Required manifest file missing: ${manifest}"
    exit 1
  fi
done

IMAGE_BASE="ghcr.io/${GHCR_OWNER}/${GHCR_REPO}"
# Escape values for sed (only & needs escaping with | delimiter)
IMAGE_BASE_ESC="$(sed_escape "${IMAGE_BASE}")"
CONTROLLER_IMAGE_ESC="$(sed_escape "${CONTROLLER_IMAGE}")"
PANEL_IMAGE_ESC="$(sed_escape "${PANEL_IMAGE}")"
PANEL_DOMAIN_ESC="$(sed_escape "${PANEL_DOMAIN}")"
PANEL_TLS_ISSUER_ESC="$(sed_escape "${PANEL_TLS_ISSUER}")"
PANEL_BASICAUTH_B64_ESC="$(sed_escape "${PANEL_BASICAUTH_B64}")"
LETSENCRYPT_EMAIL_ESC="$(sed_escape "${LETSENCRYPT_EMAIL}")"
POSTGRES_PASSWORD_ESC="$(sed_escape "${POSTGRES_PASSWORD}")"
PGADMIN_EMAIL_ESC="$(sed_escape "${PGADMIN_EMAIL}")"
PGADMIN_PASSWORD_ESC="$(sed_escape "${PGADMIN_PASSWORD}")"
PGADMIN_DOMAIN_ESC="$(sed_escape "${PGADMIN_DOMAIN}")"
PGADMIN_BASICAUTH_ESC="$(sed_escape "${PGADMIN_BASICAUTH}")"
MAILCOW_DOMAIN_ESC="$(sed_escape "${MAILCOW_DOMAIN}")"
MAILCOW_TLS_ISSUER_ESC="$(sed_escape "${MAILCOW_TLS_ISSUER}")"
MAILCOW_BASICAUTH_ESC="$(sed_escape "${MAILCOW_BASICAUTH}")"
TSIG_SECRET_ESC="$(sed_escape "${TSIG_SECRET}")"
BACKUP_TOKEN_ESC="$(sed_escape "${BACKUP_TOKEN}")"

# Use find + xargs with proper handling for empty results (compatible with both GNU and BSD xargs)
FILES_WITH_PLACEHOLDER="$(find "${BACKUP_SYSTEM_DIR}" -type f -exec grep -l "REPLACE_IMAGE_BASE" {} + 2>/dev/null || true)"
if [[ -n "${FILES_WITH_PLACEHOLDER}" ]]; then
  echo "${FILES_WITH_PLACEHOLDER}" | xargs sed -i "s|REPLACE_IMAGE_BASE|${IMAGE_BASE_ESC}|g"
fi

# Template manifests (only if files exist)
[ -f "${PLATFORM_DIR}/controller-deploy.yaml" ] && sed -i "s|REPLACE_CONTROLLER_IMAGE|${CONTROLLER_IMAGE_ESC}|g" "${PLATFORM_DIR}/controller-deploy.yaml"
[ -f "${PLATFORM_DIR}/panel-deploy.yaml" ] && sed -i "s|REPLACE_PANEL_IMAGE|${PANEL_IMAGE_ESC}|g" "${PLATFORM_DIR}/panel-deploy.yaml"
[ -f "${PLATFORM_DIR}/panel-ingress.yaml" ] && sed -i "s|REPLACE_PANEL_DOMAIN|${PANEL_DOMAIN_ESC}|g" "${PLATFORM_DIR}/panel-ingress.yaml"
[ -f "${PLATFORM_DIR}/panel-ingress.yaml" ] && sed -i "s|REPLACE_PANEL_TLS_ISSUER|${PANEL_TLS_ISSUER_ESC}|g" "${PLATFORM_DIR}/panel-ingress.yaml"
[ -f "${PLATFORM_DIR}/panel-auth.yaml" ] && sed -i "s|REPLACE_PANEL_BASICAUTH|${PANEL_BASICAUTH_B64_ESC}|g" "${PLATFORM_DIR}/panel-auth.yaml"

if [ "${PROFILE}" = "full" ] && [ -f "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml" ]; then
  sed -i "s|REPLACE_LETSENCRYPT_EMAIL|${LETSENCRYPT_EMAIL_ESC}|g" "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml"
fi

[ -f "${SERVICES_DIR}/infra-db/postgres-secret.yaml" ] && sed -i "s|REPLACE_POSTGRES_PASSWORD|${POSTGRES_PASSWORD_ESC}|g" "${SERVICES_DIR}/infra-db/postgres-secret.yaml"
[ -f "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml" ] && sed -i "s|REPLACE_PGADMIN_EMAIL|${PGADMIN_EMAIL_ESC}|g" "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml"
[ -f "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml" ] && sed -i "s|REPLACE_PGADMIN_PASSWORD|${PGADMIN_PASSWORD_ESC}|g" "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml"
[ -f "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml" ] && sed -i "s|REPLACE_PGADMIN_DOMAIN|${PGADMIN_DOMAIN_ESC}|g" "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml"
[ -f "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml" ] && sed -i "s|REPLACE_PANEL_TLS_ISSUER|${PANEL_TLS_ISSUER_ESC}|g" "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml"
[ -f "${SERVICES_DIR}/infra-db/pgadmin-auth.yaml" ] && sed -i "s|REPLACE_PGADMIN_BASICAUTH|${PGADMIN_BASICAUTH_ESC}|g" "${SERVICES_DIR}/infra-db/pgadmin-auth.yaml"

if [ "${WITH_MAIL}" = "true" ]; then
  [ -f "${SERVICES_DIR}/mail-zone/mailcow-core.yaml" ] && sed -i "s|REPLACE_MAILCOW_HOSTNAME|${MAILCOW_DOMAIN_ESC}|g" "${SERVICES_DIR}/mail-zone/mailcow-core.yaml"
  [ -f "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml" ] && sed -i "s|REPLACE_MAILCOW_DOMAIN|${MAILCOW_DOMAIN_ESC}|g" "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml"
  [ -f "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml" ] && sed -i "s|REPLACE_MAILCOW_TLS_ISSUER|${MAILCOW_TLS_ISSUER_ESC}|g" "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml"
  [ -f "${SERVICES_DIR}/mail-zone/mailcow-auth.yaml" ] && sed -i "s|REPLACE_MAILCOW_BASICAUTH|${MAILCOW_BASICAUTH_ESC}|g" "${SERVICES_DIR}/mail-zone/mailcow-auth.yaml"
fi

if [ "${WITH_DNS}" = "true" ] && [ -f "${SERVICES_DIR}/dns-zone/tsig-secret.yaml" ]; then
  sed -i "s|REPLACE_ME_BASE64LIKE|${TSIG_SECRET_ESC}|g" "${SERVICES_DIR}/dns-zone/tsig-secret.yaml"
fi

[ -f "${BACKUP_SYSTEM_DIR}/backup-service-secret.yaml" ] && sed -i "s|REPLACE_BACKUP_TOKEN|${BACKUP_TOKEN_ESC}|g" "${BACKUP_SYSTEM_DIR}/backup-service-secret.yaml"
if [ -d "${BACKUP_SYSTEM_DIR}" ] && grep -rl "REPLACE_IMAGE_BASE" "${BACKUP_SYSTEM_DIR}" >/dev/null 2>&1; then
  log_error "REPLACE_IMAGE_BASE placeholder not fully replaced in backup-system manifests."
  exit 1
fi
if [ -f "${PLATFORM_DIR}/panel-auth.yaml" ] && grep -q "REPLACE_PANEL_BASICAUTH" "${PLATFORM_DIR}/panel-auth.yaml"; then
  log_error "REPLACE_PANEL_BASICAUTH placeholder not fully replaced in panel-auth.yaml."
  exit 1
fi

# Validate that all REPLACE_* placeholders are replaced
log_step "Validating all REPLACE_* placeholders are replaced"
REMAINING_PLACEHOLDERS=$(find "${SERVICES_DIR}" "${PLATFORM_DIR}" -type f \( -name "*.yaml" -o -name "*.yml" \) -exec grep -l "REPLACE_" {} + 2>/dev/null | xargs grep -h "REPLACE_" 2>/dev/null | grep -v "REPLACE_SITE_SLUG\|REPLACE_TENANT_NAMESPACE\|REPLACE_DB_" | sort -u || true)
if [[ -n "${REMAINING_PLACEHOLDERS}" ]]; then
  echo "ERROR: The following REPLACE_* placeholders were not replaced:"
  echo "${REMAINING_PLACEHOLDERS}"
  exit 1
fi

# ========= apply =========
log_step "Applying Traefik entrypoints config"
if [ -f "${SERVICES_DIR}/traefik/helmchartconfig-traefik.yaml" ]; then
  kubectl apply -f "${SERVICES_DIR}/traefik/helmchartconfig-traefik.yaml"
  write_state_flag "TRAEFIK_INSTALLED"
else
  log_warn "Traefik config not found, skipping"
fi

# Install cert-manager only if profile is full (minimal profile skips it unless already used)
if [ "${PROFILE}" = "full" ]; then
  log_step "Installing cert-manager (cluster-wide)"
  if [[ ! -f "${SERVICES_DIR}/cert-manager/cert-manager.yaml" ]]; then
    log_error "cert-manager.yaml missing: ${SERVICES_DIR}/cert-manager/cert-manager.yaml"
    exit 1
  fi

  # Check for orphaned Kyverno webhooks (namespace deleted but webhooks remain)
  # This is a safety check - Kyverno will be installed later, after cert-manager and Flux
  log_info "Checking for orphaned Kyverno webhooks (pre-install safety check)..."
  orphaned_webhooks="$(kubectl get validatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i kyverno || true)"
  orphaned_mutating="$(kubectl get mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i kyverno || true)"
  
  if [ -n "${orphaned_webhooks}" ] || [ -n "${orphaned_mutating}" ]; then
    log_warn "Found orphaned Kyverno webhooks (namespace deleted but webhooks remain)"
    log_info "Cleaning up orphaned webhooks to prevent cert-manager installation issues..."
    
    for webhook in ${orphaned_webhooks}; do
      echo "  Deleting validating webhook: ${webhook}"
      kubectl delete validatingwebhookconfiguration "${webhook}" --ignore-not-found=true >/dev/null 2>&1 || true
    done
    
    for webhook in ${orphaned_mutating}; do
      echo "  Deleting mutating webhook: ${webhook}"
      kubectl delete mutatingwebhookconfiguration "${webhook}" --ignore-not-found=true >/dev/null 2>&1 || true
    done
    
    log_ok "Orphaned webhooks cleaned up"
    sleep 2
  else
    echo "  No orphaned webhooks found"
  fi

  # Use retry_apply to handle webhook timeouts
  retry_apply "${SERVICES_DIR}/cert-manager/cert-manager.yaml" "cert-manager manifests" 5 || {
    log_error "Failed to apply cert-manager manifests after retries"
    echo "This may be due to Kyverno webhook timeouts. You can try:"
    echo "  1. Wait for Kyverno to be fully ready: kubectl wait --for=condition=Available deployment -n kyverno --all"
    echo "  2. Or temporarily scale down Kyverno: kubectl scale deployment -n kyverno --replicas=0 --all"
    exit 1
  }

  # Wait for CRDs with polling
  log_info "Waiting for cert-manager CRDs..."
  for i in {1..30}; do
    if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  kubectl wait --for=condition=Established crd/certificates.cert-manager.io --timeout="${CERT_MANAGER_TIMEOUT}s" || {
    log_error "cert-manager CRDs did not become established"
    kubectl get crd | grep cert-manager || true
    exit 1
  }
  kubectl wait --for=condition=Established crd/certificaterequests.cert-manager.io --timeout="${CERT_MANAGER_TIMEOUT}s"
  kubectl wait --for=condition=Established crd/challenges.acme.cert-manager.io --timeout="${CERT_MANAGER_TIMEOUT}s"
  kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout="${CERT_MANAGER_TIMEOUT}s"
  kubectl wait --for=condition=Established crd/issuers.cert-manager.io --timeout="${CERT_MANAGER_TIMEOUT}s"
  kubectl wait --for=condition=Established crd/orders.acme.cert-manager.io --timeout="${CERT_MANAGER_TIMEOUT}s"

  # Wait for deployments with polling
  log_info "Waiting for cert-manager deployments..."
  for i in {1..30}; do
    if kubectl get deployment cert-manager -n cert-manager >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout="${CERT_MANAGER_TIMEOUT}s" || {
    log_error "cert-manager deployment did not become available"
    kubectl get pods -n cert-manager
    exit 1
  }
  kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout="${CERT_MANAGER_TIMEOUT}s" || {
    log_error "cert-manager-webhook deployment did not become available"
    kubectl get pods -n cert-manager
    exit 1
  }
  kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout="${CERT_MANAGER_TIMEOUT}s" || {
    log_error "cert-manager-cainjector deployment did not become available"
    kubectl get pods -n cert-manager
    exit 1
  }
  write_state_flag "CERT_MANAGER_INSTALLED"
  # Label cert-manager namespace
  label_namespace "cert-manager"
  echo "Applying ClusterIssuers."
  if [[ -f "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml" ]]; then
    retry_apply "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml" "ClusterIssuers" 3 || {
      log_error "Failed to apply ClusterIssuers after retries"
      echo "Continuing anyway - ClusterIssuers can be applied later"
    }
  fi
else
  log_info "Skipping cert-manager installation (profile: ${PROFILE})"
  if kubectl get namespace cert-manager >/dev/null 2>&1; then
    label_namespace "cert-manager"
  fi
fi

# Install Flux only if profile is full
if [ "${PROFILE}" = "full" ]; then
  log_step "Installing Flux controllers"
  # Check if namespace exists before creating
  if kubectl get namespace flux-system >/dev/null 2>&1; then
    echo "  Namespace flux-system already exists, skipping creation"
  else
    retry_apply "${SERVICES_DIR}/flux-system/namespace.yaml" "flux-system namespace" 5
  fi
  FLUX_INSTALL_URL="https://github.com/fluxcd/flux2/releases/download/v2.3.0/install.yaml"
  if ! curl -sfL "${FLUX_INSTALL_URL}" -o "${SERVICES_DIR}/flux-system/install.yaml"; then
    log_error "Failed to download Flux install.yaml from ${FLUX_INSTALL_URL}"
    exit 1
  fi
  if [[ ! -f "${SERVICES_DIR}/flux-system/install.yaml" ]] || [[ ! -s "${SERVICES_DIR}/flux-system/install.yaml" ]]; then
    log_error "Flux install.yaml is missing or empty after download"
    exit 1
  fi
  kubectl apply -f "${SERVICES_DIR}/flux-system/install.yaml" || {
    log_error "Failed to apply Flux manifests"
    exit 1
  }

  # Poll for deployments before wait
  log_info "Waiting for Flux deployments..."
  for i in {1..30}; do
    if kubectl get deployments -n flux-system --no-headers 2>/dev/null | grep -q .; then
      break
    fi
    sleep 1
  done

  kubectl wait --for=condition=Available deployment -n flux-system --all --timeout="${FLUX_TIMEOUT}s" || {
    log_error "Flux deployments did not become available within ${FLUX_TIMEOUT}s"
    kubectl get pods -n flux-system -o wide
    kubectl get events -n flux-system --sort-by='.lastTimestamp' | tail -20
    exit 1
  }
  write_state_flag "FLUX_INSTALLED"
  # Label flux-system namespace
  label_namespace "flux-system"
else
  log_info "Skipping Flux installation (profile: ${PROFILE})"
  if kubectl get namespace flux-system >/dev/null 2>&1; then
    label_namespace "flux-system"
  fi
fi

# Install Kyverno only if profile is full
# IMPORTANT: Kyverno is installed AFTER Traefik, cert-manager, and Flux to prevent admission webhook deadlocks
# Even if Kyverno is sick later, cluster has ingress and is easier to recover
if [ "${PROFILE}" = "full" ]; then
  log_step "Installing Kyverno (idempotent, after core services)"
  
  # Idempotent namespace creation
  # Check if namespace exists before creating
  if kubectl get namespace kyverno >/dev/null 2>&1; then
    echo "  Namespace kyverno already exists, skipping creation"
  else
    retry_apply "${SERVICES_DIR}/kyverno/namespace.yaml" "kyverno namespace" 5
  fi

  # Idempotent Kyverno installation: use server-side apply with force-conflicts
  KYVERNO_MANIFEST="${SERVICES_DIR}/kyverno/install.yaml"
  echo "Applying Kyverno manifests (server-side, idempotent)..."
  kubectl apply --server-side --force-conflicts -f "${KYVERNO_MANIFEST}" || {
    log_error "Failed to apply Kyverno manifests"
    exit 1
  }
  log_ok "Kyverno resources applied successfully"

  # CRITICAL: Immediately set webhooks to fail-open to prevent API lock
  # This must happen BEFORE deployments become available, as webhooks are created during apply
  log_info "Safe bootstrap: Setting Kyverno webhooks to fail-open (preventing API lock)..."
  safe_bootstrap_kyverno_webhooks

  # Immediately fix cleanup jobs to ensure they use correct images
  # This prevents old bitnami/kubectl images from being used
  fix_kyverno_cleanup_jobs "${KYVERNO_MANIFEST}"

  # Wait for Kyverno deployments with proper polling
  log_info "Waiting for Kyverno deployments to be available..."
  # Poll first to ensure deployments exist
  for i in {1..30}; do
    if kubectl get deployments -n kyverno --no-headers 2>/dev/null | grep -q .; then
      break
    fi
    sleep 1
  done

  kubectl wait --for=condition=Available deployment -n kyverno --all --timeout="${KYVERNO_TIMEOUT}s" || {
    log_error "Kyverno deployments did not become available within ${KYVERNO_TIMEOUT}s"
    echo "=== Kyverno Diagnostic ==="
    kubectl get pods -n kyverno -o wide
    echo ""
    kubectl get deployments -n kyverno
    echo ""
    kubectl get events -n kyverno --sort-by='.lastTimestamp' | tail -30
    log_warn "Kyverno deployments not ready, but webhooks are fail-open - continuing installation"
    # Don't exit - webhooks are fail-open, so cluster won't be bricked
  }
  
  write_state_flag "KYVERNO_INSTALLED"
  # Label kyverno namespace
  label_namespace "kyverno"

  # CRITICAL: Wait for Kyverno webhook service to be reachable BEFORE hardening webhooks
  # This prevents bricking the cluster if service is not ready
  log_info "Waiting for Kyverno webhook service to be reachable (before hardening webhooks)..."
  service_ready=false
  max_wait=120  # 2 minutes max wait
  waited=0
  
  while [ ${waited} -lt ${max_wait} ]; do
    if check_kyverno_service_reachable "kyverno" "kyverno-svc" 5; then
      log_ok "Kyverno webhook service is reachable"
      service_ready=true
      break
    fi
    sleep 2
    waited=$((waited + 2))
    if [ $((waited % 20)) -eq 0 ]; then
      log_info "Still waiting for Kyverno service... (${waited}/${max_wait}s)"
    fi
  done
  
  if [ "${service_ready}" = "true" ]; then
    # Service is reachable, harden webhooks back to fail-closed
    log_info "Hardening Kyverno webhooks: Setting failurePolicy=Fail (service is reachable)..."
    harden_kyverno_webhooks
  else
    # Service not reachable within timeout - keep webhooks fail-open to avoid bricking cluster
    log_warn "Kyverno webhook service not reachable within ${max_wait}s"
    log_warn "Keeping webhooks in fail-open mode (failurePolicy=Ignore) to prevent API lock"
    log_warn "This is safe - Kyverno policies will not be enforced until service is healthy"
    log_warn "You can manually harden webhooks later when Kyverno is healthy:"
    log_warn "  kubectl get validatingwebhookconfigurations -o name | grep kyverno | xargs -I {} kubectl patch {} --type=json -p '[{\"op\":\"replace\",\"path\":\"/webhooks/0/failurePolicy\",\"value\":\"Fail\"}]'"
  fi

  # Apply policies (idempotent) - wait a bit for Kyverno to be fully ready
  log_info "Waiting for Kyverno to be fully operational..."
  sleep 5
  echo "Applying Kyverno policies..."
  retry_apply "${SERVICES_DIR}/kyverno/policies.yaml" "Kyverno policies" 3

  # Wait a moment for policies to be active
  log_info "Waiting for policies to be active..."
  sleep 5  # Increased wait time for policies to be fully active

  # Fix any failed cleanup jobs (e.g., ImagePullBackOff from old bitnami/kubectl images)
  # Note: SERVICES_DIR may not be set yet during cleanup, so pass empty string
  fix_kyverno_cleanup_jobs ""
else
  log_info "Skipping Kyverno installation (profile: ${PROFILE})"
  if kubectl get namespace kyverno >/dev/null 2>&1; then
    label_namespace "kyverno"
  fi
fi

log_step "Applying platform base manifests"
# Check if namespace exists before creating
if kubectl get namespace platform >/dev/null 2>&1; then
  echo "  Namespace platform already exists, skipping creation"
else
  # Use retry_apply for namespace creation (handles webhook timeouts)
  retry_apply "${PLATFORM_DIR}/namespace.yaml" "platform namespace" 5
fi
label_namespace "platform"
kubectl apply -f "${PLATFORM_DIR}/rbac.yaml"
# Ensure serviceAccount exists before applying deployment (required for Kyverno policies)
if ! kubectl get serviceaccount controller-sa -n platform >/dev/null 2>&1; then
  echo "Creating controller-sa serviceAccount..."
  kubectl apply -f "${PLATFORM_DIR}/rbac.yaml"
fi
kubectl apply -f "${PLATFORM_DIR}/pvc.yaml"
kubectl apply -f "${PLATFORM_DIR}/platform-secrets.yaml"
kubectl apply -f "${PLATFORM_DIR}/panel-auth.yaml"
kubectl apply -f "${PLATFORM_DIR}/panel-redirect.yaml"
if [[ -n "${GHCR_USERNAME}" && -n "${GHCR_TOKEN}" ]]; then
  kubectl create secret docker-registry ghcr-pull-secret \
    -n platform \
    --docker-server=ghcr.io \
    --docker-username="${GHCR_USERNAME}" \
    --docker-password="${GHCR_TOKEN}" \
    ${GHCR_EMAIL:+--docker-email="${GHCR_EMAIL}"} \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "Skipping GHCR pull secret (public images)."
fi

# Note: Platform PVCs will be bound automatically when controller/panel pods are scheduled
# (WaitForFirstConsumer: PVC binds when pod is scheduled, not before)

# Function to auto-build images if validation fails
auto_build_images() {
  local image_type="$1"  # "controller" or "panel"
  local image_name="$2"
  
  # Check if Docker is available, if not try to install it
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    log_warn "Docker is required to build images but is not available."
    log_info "Attempting to install Docker automatically..."
    
    # Temporarily set BUILD_IMAGES to true to force Docker installation
    local old_build_images="${BUILD_IMAGES:-false}"
    BUILD_IMAGES=true
    
    # Try to install Docker
    if ensure_docker; then
      log_ok "Docker installed successfully"
      # Wait a moment for Docker daemon to be ready
      sleep 3
      # Verify Docker is working
      if ! docker info >/dev/null 2>&1; then
        log_warn "Docker installed but daemon not ready, waiting..."
        local wait_count=0
        while [ ${wait_count} -lt 30 ] && ! docker info >/dev/null 2>&1; do
          sleep 1
          wait_count=$((wait_count + 1))
        done
        if ! docker info >/dev/null 2>&1; then
          log_error "Docker daemon not ready after installation"
          log_error "Please start Docker manually: systemctl start docker"
          BUILD_IMAGES="${old_build_images}"
          return 1
        fi
      fi
      log_ok "Docker is ready"
      BUILD_IMAGES="${old_build_images}"
    else
      log_error "Failed to install Docker automatically"
      BUILD_IMAGES="${old_build_images}"
      log_error ""
      log_error "Options:"
      log_error "  1. Wait for GitHub Actions workflow to build images:"
      log_error "     https://github.com/${GHCR_OWNER}/${GHCR_REPO}/actions/workflows/images.yml"
      log_error "  2. Manually trigger workflow:"
      log_error "     Go to Actions > Build and Publish Docker Images > Run workflow"
      log_error "  3. Install Docker manually and re-run installer"
      return 1
    fi
  fi
  
  log_info "Image not found in GHCR. Checking if GitHub Actions workflow has built it..."
  log_info "Workflow URL: https://github.com/${GHCR_OWNER}/${GHCR_REPO}/actions/workflows/images.yml"
  log_info "If workflow hasn't run yet, attempting to build locally..."
  
  log_info "Attempting to auto-build ${image_type} image locally..."
  
  # Check if git is available, if not try to install it
  if ! command -v git >/dev/null 2>&1; then
    log_warn "git is required to build images but is not installed."
    log_info "Attempting to install git..."
    
    if command -v apt-get >/dev/null 2>&1; then
      if apt-get update -y >/dev/null 2>&1 && apt-get install -y git >/dev/null 2>&1; then
        log_ok "git installed successfully"
      else
        log_error "Failed to install git automatically"
        log_error "Please install git manually: apt-get install -y git"
        log_error "Or wait for GitHub Actions workflow to build images"
        return 1
      fi
    else
      log_error "git is required but automatic install is only supported on apt-get systems (Ubuntu/Debian)."
      log_error "Please install git manually or wait for GitHub Actions workflow to build images"
      return 1
    fi
  fi
  
  # Determine tag suffix
  local tag_suffix=""
  if [ "${image_type}" = "controller" ]; then
    tag_suffix="controller"
  elif [ "${image_type}" = "panel" ]; then
    tag_suffix="panel"
  else
    log_error "Unknown image type: ${image_type}"
    return 1
  fi
  
  # Check if git is available
  if ! command -v git >/dev/null 2>&1; then
    log_error "git is required to build images but is not installed."
    log_error "Please install git: apt-get install -y git"
    log_error "Or wait for GitHub Actions workflow to build images"
    return 1
  fi
  
  # Clone repository to temp directory
  local repo_dir
  repo_dir="$(mktemp -d)"
  
  local repo_url="https://github.com/${GHCR_OWNER}/${GHCR_REPO}.git"
  local ref="${VERSION:-${REF:-main}}"
  local image_tag="${IMAGE_TAG:-latest}"
  
  log_info "Cloning ${repo_url} (ref: ${ref})..."
  if ! git clone --depth 1 --branch "${ref}" "${repo_url}" "${repo_dir}" 2>/dev/null; then
    # Try main branch if specified branch doesn't exist
    if [ "${ref}" != "main" ]; then
      log_warn "Branch ${ref} not found, trying main..."
      if ! git clone --depth 1 --branch main "${repo_url}" "${repo_dir}" 2>/dev/null; then
        log_error "Failed to clone repository for building images"
        log_error "Please ensure GitHub Actions workflow builds images, or check network connectivity"
        rm -rf "${repo_dir}"
        return 1
      fi
    else
      log_error "Failed to clone repository for building images"
      log_error "Please ensure GitHub Actions workflow builds images, or check network connectivity"
      rm -rf "${repo_dir}"
      return 1
    fi
  fi
  
  # Build image
  log_info "Building ${image_type} image..."
  local build_image="ghcr.io/${GHCR_OWNER}/voxeil-${tag_suffix}:${image_tag}"
  local build_context=""
  
  if [ "${image_type}" = "controller" ]; then
    build_context="${repo_dir}/apps/controller"
  elif [ "${image_type}" = "panel" ]; then
    build_context="${repo_dir}/apps/panel"
  fi
  
  cd "${build_context}"
  if docker build -t "${build_image}" . >/dev/null 2>&1; then
    log_ok "${image_type} image built successfully: ${build_image}"
    log_info "Note: This is a local build. For production, use images from GitHub Actions workflow."
    # Clean up
    cd /
    rm -rf "${repo_dir}"
    return 0
  else
    log_error "Failed to build ${image_type} image"
    log_error ""
    log_error "Please ensure GitHub Actions workflow builds images:"
    log_error "  https://github.com/${GHCR_OWNER}/${GHCR_REPO}/actions/workflows/images.yml"
    cd /
    rm -rf "${repo_dir}"
    return 1
  fi
}

# Validate controller image before applying deployment
if [[ "${SKIP_IMAGE_VALIDATION:-false}" != "true" ]]; then
  log_step "Validating controller image"
  if ! validate_image "${CONTROLLER_IMAGE}"; then
    echo ""
    log_warn "Controller image validation failed: ${CONTROLLER_IMAGE}"
    log_info "Attempting to auto-build image..."
    
    log_warn "Controller image not found in GHCR."
    log_info "GitHub Actions workflow should build images automatically on push to main."
    log_info "If images are not available, installer will attempt to build locally..."
    
    if auto_build_images "controller" "${CONTROLLER_IMAGE}"; then
      log_ok "Controller image built successfully"
      # Update CONTROLLER_IMAGE to use the built image
      CONTROLLER_IMAGE="ghcr.io/${GHCR_OWNER}/voxeil-controller:${IMAGE_TAG:-latest}"
      log_info "Using built image: ${CONTROLLER_IMAGE}"
    else
      log_error "Failed to auto-build controller image"
      log_error "Installation cannot continue without controller image."
      log_error ""
      log_error "Solutions:"
      log_error "  1. Trigger GitHub Actions workflow to build images:"
      log_error "     https://github.com/${GHCR_OWNER}/${GHCR_REPO}/actions/workflows/images.yml"
      log_error "  2. Wait for workflow to complete, then re-run installer"
      log_error "  3. Or build manually: git clone https://github.com/${GHCR_OWNER}/${GHCR_REPO} && cd ${GHCR_REPO}/apps/controller && docker build -t ${CONTROLLER_IMAGE} ."
      exit 1
    fi
  fi
else
  echo "Skipping controller image validation (SKIP_IMAGE_VALIDATION=true)"
fi

# Validate panel image before applying deployment
if [[ "${SKIP_IMAGE_VALIDATION:-false}" != "true" ]]; then
  log_step "Validating panel image"
  if ! validate_image "${PANEL_IMAGE}"; then
    echo ""
    log_warn "Panel image validation failed: ${PANEL_IMAGE}"
    log_info "Attempting to auto-build image..."
    
    log_warn "Panel image not found in GHCR."
    log_info "GitHub Actions workflow should build images automatically on push to main."
    log_info "If images are not available, installer will attempt to build locally..."
    
    if auto_build_images "panel" "${PANEL_IMAGE}"; then
      log_ok "Panel image built successfully"
      # Update PANEL_IMAGE to use the built image
      PANEL_IMAGE="ghcr.io/${GHCR_OWNER}/voxeil-panel:${IMAGE_TAG:-latest}"
      log_info "Using built image: ${PANEL_IMAGE}"
    else
      log_error "Failed to auto-build panel image"
      log_error "Installation cannot continue without panel image."
      log_error ""
      log_error "Solutions:"
      log_error "  1. Trigger GitHub Actions workflow to build images:"
      log_error "     https://github.com/${GHCR_OWNER}/${GHCR_REPO}/actions/workflows/images.yml"
      log_error "  2. Wait for workflow to complete, then re-run installer"
      log_error "  3. Or build manually: git clone https://github.com/${GHCR_OWNER}/${GHCR_REPO} && cd ${GHCR_REPO}/apps/panel && docker build -t ${PANEL_IMAGE} ."
      exit 1
    fi
  fi
else
  echo "Skipping panel image validation (SKIP_IMAGE_VALIDATION=true)"
fi

log_step "Applying infra DB manifests"
# Check if namespace exists before creating
if kubectl get namespace infra-db >/dev/null 2>&1; then
  echo "  Namespace infra-db already exists, skipping creation"
else
  # Use retry_apply for namespace creation (handles webhook timeouts)
  retry_apply "${SERVICES_DIR}/infra-db/namespace.yaml" "infra-db namespace" 5
fi
label_namespace "infra-db"
kubectl apply -f "${SERVICES_DIR}/infra-db/postgres-secret.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pvc.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/postgres-service.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/postgres-statefulset.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/networkpolicy.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pgadmin-auth.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pgadmin-svc.yaml"

# Ensure pgadmin PVC is ready before deploying pgadmin
log_info "Ensuring pgadmin PVC is ready..."
# Wait for any terminating PVCs to be cleaned up
for i in {1..30}; do
  terminating_pvc="$(kubectl get pvc pgadmin-pvc -n infra-db -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")"
  if [ -z "${terminating_pvc}" ]; then
    break
  fi
  echo "  Waiting for pgadmin-pvc to finish terminating... (${i}/30)"
  sleep 2
done

# Validate pgadmin deployment manifest before applying
log_info "Validating pgadmin deployment manifest..."
if ! kubectl apply --dry-run=server -f "${SERVICES_DIR}/infra-db/pgadmin-deploy.yaml" >/dev/null 2>&1; then
  log_error "pgadmin deployment manifest validation failed"
  echo "=== kubectl dry-run error ==="
  kubectl apply --dry-run=server -f "${SERVICES_DIR}/infra-db/pgadmin-deploy.yaml" 2>&1 || true
  exit 1
fi

# Apply pgadmin deployment
kubectl apply -f "${SERVICES_DIR}/infra-db/pgadmin-deploy.yaml"

# Wait for postgres StatefulSet to be ready (PVC will bind when pod is scheduled)
# This is critical because controller depends on postgres
log_info "Waiting for postgres StatefulSet to be ready..."
# Poll first to ensure StatefulSet exists
for i in {1..30}; do
  if kubectl get statefulset postgres -n infra-db >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! kubectl wait --for=condition=Ready pod -l app=postgres -n infra-db --timeout="${DEPLOYMENT_ROLLOUT_TIMEOUT}s"; then
  log_error "postgres StatefulSet did not become ready within ${DEPLOYMENT_ROLLOUT_TIMEOUT}s"
  echo "=== Postgres Pod Status ==="
  kubectl get pods -n infra-db -l app=postgres || true
  echo ""
  kubectl describe pod -l app=postgres -n infra-db || true
  echo ""
  echo "=== Postgres Pod Logs (last 100 lines) ==="
  postgres_pod="$(kubectl get pod -n infra-db -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
  if [ -n "${postgres_pod}" ]; then
    kubectl logs "${postgres_pod}" -n infra-db --tail=100 || true
    echo ""
    echo "=== Init Container Logs (if any) ==="
    kubectl logs "${postgres_pod}" -n infra-db -c init-permissions --tail=100 2>/dev/null || true
  fi
  echo ""
  echo "=== PVC Status ==="
  kubectl get pvc -n infra-db || true
  exit 1
fi
echo "postgres StatefulSet is ready"

# Wait for pgadmin Deployment to be ready
log_info "Waiting for pgadmin Deployment to be ready..."
# Poll first to ensure Deployment exists
for i in {1..30}; do
  if kubectl get deployment pgadmin -n infra-db >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Clean up any failed/crashed pgadmin pods before waiting
echo "Cleaning up any failed pgadmin pods..."
failed_pgadmin_pods="$(kubectl get pods -n infra-db -l app=pgadmin -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | grep -E "(Failed|CrashLoopBackOff|Error)" | cut -f1 || true)"
if [ -n "${failed_pgadmin_pods}" ]; then
  for pod in ${failed_pgadmin_pods}; do
    echo "  Deleting failed pod: ${pod}"
    kubectl delete pod "${pod}" -n infra-db --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
  done
  sleep 2
fi

if ! kubectl wait --for=condition=Available deployment/pgadmin -n infra-db --timeout="${DEPLOYMENT_ROLLOUT_TIMEOUT}s"; then
  log_error "pgadmin Deployment did not become available within ${DEPLOYMENT_ROLLOUT_TIMEOUT}s"
  echo "=== pgadmin Pod Status ==="
  kubectl get pods -n infra-db -l app=pgadmin || true
  echo ""
  kubectl describe deployment pgadmin -n infra-db || true
  echo ""
  echo "=== pgadmin Pod Logs (last 100 lines) ==="
  pgadmin_pod="$(kubectl get pod -n infra-db -l app=pgadmin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
  if [ -n "${pgadmin_pod}" ]; then
    kubectl logs "${pgadmin_pod}" -n infra-db --tail=100 || true
    echo ""
    echo "=== Init Container Logs (if any) ==="
    kubectl logs "${pgadmin_pod}" -n infra-db -c init-permissions --tail=100 2>/dev/null || true
    echo ""
    echo "=== Pod Describe (full) ==="
    kubectl describe pod "${pgadmin_pod}" -n infra-db || true
  fi
  echo ""
  echo "=== PVC Status ==="
  kubectl get pvc -n infra-db || true
  echo ""
  echo "=== Checking for PVC issues ==="
  pgadmin_pvc_status="$(kubectl get pvc pgadmin-pvc -n infra-db -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")"
  if [ "${pgadmin_pvc_status}" = "Terminating" ]; then
    echo "ERROR: pgadmin-pvc is stuck in Terminating state"
    echo "Attempting to fix by removing finalizers..."
    kubectl patch pvc pgadmin-pvc -n infra-db -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
    echo "Waiting for PVC to be deleted..."
    sleep 5
    echo "Re-applying pgadmin PVC..."
    kubectl apply -f "${SERVICES_DIR}/infra-db/pvc.yaml" || true
  elif [ "${pgadmin_pvc_status}" != "Bound" ] && [ "${pgadmin_pvc_status}" != "Pending" ]; then
    echo "WARNING: pgadmin-pvc status is ${pgadmin_pvc_status} (expected Bound or Pending)"
  fi
  echo ""
  echo "=== Events (last 20) ==="
  kubectl get events -n infra-db --sort-by='.lastTimestamp' | tail -20 || true
  exit 1
fi
log_ok "pgadmin Deployment is ready"
write_state_flag "INFRA_DB_INSTALLED"

# Now apply platform workloads after postgres is ready
log_step "Applying platform workloads"
kubectl apply -f "${PLATFORM_DIR}/controller-deploy.yaml"
kubectl apply -f "${PLATFORM_DIR}/controller-svc.yaml"
kubectl apply -f "${PLATFORM_DIR}/panel-deploy.yaml"
kubectl apply -f "${PLATFORM_DIR}/panel-svc.yaml"
write_state_flag "PLATFORM_INSTALLED"

# Install DNS only if --with-dns flag is set
if [ "${WITH_DNS}" = "true" ]; then
  log_step "Applying DNS (bind9) manifests"
  # Check if namespace exists before creating
  if kubectl get namespace dns-zone >/dev/null 2>&1; then
    echo "  Namespace dns-zone already exists, skipping creation"
  else
    retry_apply "${SERVICES_DIR}/dns-zone/namespace.yaml" "dns-zone namespace" 5
  fi
  label_namespace "dns-zone"
  kubectl apply -f "${SERVICES_DIR}/dns-zone/tsig-secret.yaml"
  kubectl apply -f "${SERVICES_DIR}/dns-zone/pvc.yaml"
  kubectl apply -f "${SERVICES_DIR}/dns-zone/bind9.yaml"

# Wait for bind9 Deployment to be ready (PVC will bind when pod is scheduled)
log_info "Waiting for bind9 Deployment to be ready..."
# Poll first to ensure Deployment exists
for i in {1..30}; do
  if kubectl get deployment bind9 -n dns-zone >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! kubectl wait --for=condition=Available deployment/bind9 -n dns-zone --timeout="${DEPLOYMENT_ROLLOUT_TIMEOUT}s"; then
  log_error "bind9 Deployment did not become available within ${DEPLOYMENT_ROLLOUT_TIMEOUT}s"
  echo "=== bind9 Pod Status ==="
  kubectl get pods -n dns-zone -l app=bind9 || true
  echo ""
  kubectl describe deployment bind9 -n dns-zone || true
  echo ""
  echo "=== PVC Status ==="
  kubectl get pvc -n dns-zone || true
  exit 1
fi
  log_ok "bind9 Deployment is ready"
  write_state_flag "DNS_INSTALLED"
else
  log_info "Skipping DNS installation (use --with-dns to enable)"
  if kubectl get namespace dns-zone >/dev/null 2>&1; then
    label_namespace "dns-zone"
  fi
fi

# Install mail only if --with-mail flag is set
if [ "${WITH_MAIL}" = "true" ]; then
    # Check if namespace exists before creating
    if kubectl get namespace mail-zone >/dev/null 2>&1; then
      echo "  Namespace mail-zone already exists, skipping creation"
    else
      retry_apply "${SERVICES_DIR}/mail-zone/namespace.yaml" "mail-zone namespace" 5
    fi
  label_namespace "mail-zone"
  kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-secrets.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-auth.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-core.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/networkpolicy.yaml"

# Wait for mailcow-mysql StatefulSet to be ready (PVC will bind when pod is scheduled)
# This is critical because other mailcow components (php-fpm, postfix, dovecot) depend on mysql
log_info "Waiting for mailcow-mysql StatefulSet to be ready..."
# Poll first to ensure StatefulSet exists
for i in {1..30}; do
  if kubectl get statefulset mailcow-mysql -n mail-zone >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! kubectl wait --for=condition=Ready pod -l app=mailcow,component=mysql -n mail-zone --timeout="${DEPLOYMENT_ROLLOUT_TIMEOUT}s"; then
  log_error "mailcow-mysql StatefulSet did not become ready within ${DEPLOYMENT_ROLLOUT_TIMEOUT}s"
  echo "=== mailcow-mysql Pod Status ==="
  kubectl get pods -n mail-zone -l app=mailcow,component=mysql || true
  echo ""
  kubectl describe pod -l app=mailcow,component=mysql -n mail-zone || true
  echo ""
  echo "=== PVC Status ==="
  kubectl get pvc -n mail-zone || true
  exit 1
fi
  log_ok "mailcow-mysql StatefulSet is ready"
  write_state_flag "MAIL_INSTALLED"
else
  log_info "Skipping mail installation (use --with-mail to enable)"
  if kubectl get namespace mail-zone >/dev/null 2>&1; then
    label_namespace "mail-zone"
  fi
fi

log_step "Importing backup images to k3s"
# Images were already built before k3s installation (if build succeeded)
# Verify images exist before import
BACKUP_IMAGES_IMPORTED=0
if docker image inspect backup-runner:local >/dev/null 2>&1 || docker image inspect backup-service:local >/dev/null 2>&1; then
  # Check k3s command exists
  if ! command -v k3s >/dev/null 2>&1; then
    log_warn "k3s command not found. Cannot import images. Backup images will be pulled when needed."
  else
    # Import backup-runner:local
    if docker image inspect backup-runner:local >/dev/null 2>&1; then
      if k3s ctr images list 2>/dev/null | grep -q "backup-runner:local"; then
        log_info "backup-runner:local already imported, skipping..."
      else
        log_info "Importing backup-runner:local to k3s..."
        if docker save backup-runner:local | k3s ctr images import - >/dev/null 2>&1; then
          log_ok "backup-runner:local imported successfully"
          BACKUP_IMAGES_IMPORTED=$((BACKUP_IMAGES_IMPORTED + 1))
        else
          log_warn "Failed to import backup-runner:local to k3s. Image will be pulled when needed."
        fi
      fi
    fi
    
    # Import backup-service:local
    if docker image inspect backup-service:local >/dev/null 2>&1; then
      if k3s ctr images list 2>/dev/null | grep -q "backup-service:local"; then
        log_info "backup-service:local already imported, skipping..."
      else
        log_info "Importing backup-service:local to k3s..."
        if docker save backup-service:local | k3s ctr images import - >/dev/null 2>&1; then
          log_ok "backup-service:local imported successfully"
          BACKUP_IMAGES_IMPORTED=$((BACKUP_IMAGES_IMPORTED + 1))
        else
          log_warn "Failed to import backup-service:local to k3s. Image will be pulled when needed."
        fi
      fi
    fi
    
    # Verify images in k3s
    if k3s ctr images list 2>/dev/null | grep -E "backup-(runner|service)" >/dev/null 2>&1; then
      log_ok "Backup images verified in k3s"
    else
      log_warn "Backup images not found in k3s. Will be pulled when needed."
    fi
  fi
else
  log_warn "backup-runner:local or backup-service:local images not found. Backup functionality may be limited."
  log_info "Backup images will need to be built or pulled separately."
fi

log_step "Applying backup-system manifests"
backup_apply "${BACKUP_SYSTEM_DIR}/namespace.yaml"
label_namespace "backup-system"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-scripts-configmap.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-service-secret.yaml"
# Apply remaining backup-system manifests if they exist
if [ -f "${BACKUP_SYSTEM_DIR}/backup-service-deploy.yaml" ]; then
  backup_apply "${BACKUP_SYSTEM_DIR}/backup-service-deploy.yaml"
fi
if [ -f "${BACKUP_SYSTEM_DIR}/backup-service-svc.yaml" ]; then
  backup_apply "${BACKUP_SYSTEM_DIR}/backup-service-svc.yaml"
fi
if [ -f "${BACKUP_SYSTEM_DIR}/rbac.yaml" ]; then
  backup_apply "${BACKUP_SYSTEM_DIR}/rbac.yaml"
fi
if [ -f "${BACKUP_SYSTEM_DIR}/serviceaccount.yaml" ]; then
  backup_apply "${BACKUP_SYSTEM_DIR}/serviceaccount.yaml"
fi
write_state_flag "BACKUP_SYSTEM_INSTALLED"

log_step "Applying ingresses"
kubectl apply -f "${PLATFORM_DIR}/panel-ingress.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml"

if [ "${WITH_DNS}" = "true" ] && [ -f "${SERVICES_DIR}/dns-zone/traefik-tcp/dns-routes.yaml" ]; then
  kubectl apply -f "${SERVICES_DIR}/dns-zone/traefik-tcp/dns-routes.yaml"
fi

if [ "${WITH_MAIL}" = "true" ]; then
  if [ -f "${SERVICES_DIR}/mail-zone/traefik-tcp/ingressroutetcp.yaml" ]; then
    kubectl apply -f "${SERVICES_DIR}/mail-zone/traefik-tcp/ingressroutetcp.yaml"
  fi
  kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml"
fi

echo "Controller stays internal (no NodePort)."

# ========= optional: UFW allowlist =========
mkdir -p /etc/voxeil
cat > /etc/voxeil/installer.env <<EOF
EXPOSE_CONTROLLER="N"
EOF
touch /etc/voxeil/allowlist.txt

cat > /usr/local/bin/voxeil-ufw-apply <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ALLOWLIST_FILE="/etc/voxeil/allowlist.txt"
CONF="/etc/voxeil/installer.env"
EXPOSE_CONTROLLER="N"
if [[ -f "${CONF}" ]]; then
  # shellcheck disable=SC1090
  source "${CONF}"
fi

if ! command -v ufw >/dev/null 2>&1; then
  echo "UFW missing; skipping firewall config."
  exit 0
fi

# Retry function for UFW operations (handles xtables lock)
ufw_retry() {
  local cmd="$1"
  local max_retries=3
  local retry_delay=2
  local attempt=1
  
  while [ ${attempt} -le ${max_retries} ]; do
    # Use ufw -w (wait mode) if available to handle xtables lock
    # Check if ufw supports -w flag (available in newer versions)
    if ufw --help 2>&1 | grep -qE "\-w|--wait"; then
      if ufw -w ${cmd} 2>/dev/null; then
        return 0
      fi
    fi
    
    # Fallback: try without wait flag
    if ufw ${cmd} 2>/dev/null; then
      return 0
    fi
    
    if [ ${attempt} -lt ${max_retries} ]; then
      echo "UFW operation failed (attempt ${attempt}/${max_retries}), retrying in ${retry_delay}s..."
      sleep ${retry_delay}
      retry_delay=$((retry_delay * 2))  # Exponential backoff
    fi
    attempt=$((attempt + 1))
  done
  
  echo "Warning: UFW operation failed after ${max_retries} attempts: ${cmd}"
  echo "  This may be due to xtables lock. Continuing anyway..."
  return 1
}

ports_tcp=(22 80 443 25 465 587 143 993 110 995 53)
ports_udp=(53)

# Use retry for reset
ufw_retry "--force reset" || true
ufw_retry "default deny incoming" || true
ufw_retry "default allow outgoing" || true

allow_all=true
if [[ -s "${ALLOWLIST_FILE}" ]]; then
  allow_all=false
fi

if [[ "${allow_all}" == "true" ]]; then
  for port in "${ports_tcp[@]}"; do
    ufw_retry "allow ${port}/tcp" || true
  done
  for port in "${ports_udp[@]}"; do
    ufw_retry "allow ${port}/udp" || true
  done
else
  while IFS= read -r line; do
    entry="$(echo "${line}" | xargs)"
    [[ -z "${entry}" ]] && continue
    [[ "${entry}" == \#* ]] && continue
    for port in "${ports_tcp[@]}"; do
      ufw_retry "allow from ${entry} to any port ${port} proto tcp" || true
    done
    for port in "${ports_udp[@]}"; do
      ufw_retry "allow from ${entry} to any port ${port} proto udp" || true
    done
  done < "${ALLOWLIST_FILE}"
fi

if [[ "${EXPOSE_CONTROLLER}" =~ ^[Yy]$ ]]; then
  echo "Controller exposure is disabled by default."
fi

# Use retry for enable
ufw_retry "--force enable" || true
EOF
chmod +x /usr/local/bin/voxeil-ufw-apply
/usr/local/bin/voxeil-ufw-apply || true

if command -v systemctl >/dev/null 2>&1; then
  cat > /etc/systemd/system/voxeil-ufw-apply.service <<'EOF'
[Unit]
Description=Apply Voxeil UFW rules

[Service]
Type=oneshot
ExecStart=/usr/local/bin/voxeil-ufw-apply
EOF

  cat > /etc/systemd/system/voxeil-ufw-apply.path <<'EOF'
[Unit]
Description=Watch allowlist changes for UFW

[Path]
PathChanged=/etc/voxeil/allowlist.txt
PathChanged=/etc/voxeil/installer.env

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable voxeil-ufw-apply.path || true
  systemctl restart voxeil-ufw-apply.path || true
fi

if command -v apt-get >/dev/null 2>&1; then
  if ! command -v clamscan >/dev/null 2>&1; then
    echo "Installing ClamAV..."
    apt-get update -y && apt-get install -y clamav clamav-daemon
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable clamav-freshclam || true
    systemctl enable clamav-daemon || true
    systemctl restart clamav-freshclam || true
    systemctl restart clamav-daemon || true
  fi
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    echo "Installing fail2ban..."
    apt-get update -y && apt-get install -y fail2ban
  fi
  if command -v systemctl >/dev/null 2>&1; then
    mkdir -p /etc/fail2ban/jail.d
    mkdir -p /var/log/traefik
    mkdir -p /var/log/mailcow
    mkdir -p /var/log/bind9
    
    cat > /etc/fail2ban/jail.d/voxeil.conf <<'EOF'
[sshd]
enabled = true
bantime = 1h
findtime = 10m
maxretry = 5

[traefik-http]
enabled = true
port = http,https
filter = traefik-http
logpath = /var/log/traefik/access.log
bantime = 2h
findtime = 10m
maxretry = 20

[traefik-auth]
enabled = true
port = http,https
filter = traefik-auth
logpath = /var/log/traefik/access.log
bantime = 6h
findtime = 10m
maxretry = 5

[mailcow-auth]
enabled = true
port = 25,465,587,143,993,110,995
filter = mailcow-auth
logpath = /var/log/mailcow/auth.log
bantime = 2h
findtime = 10m
maxretry = 5

[bind9]
enabled = true
port = 53
filter = bind9
logpath = /var/log/bind9/query.log
bantime = 1h
findtime = 10m
maxretry = 10
EOF

    # Create fail2ban filters
    mkdir -p /etc/fail2ban/filter.d
    
    cat > /etc/fail2ban/filter.d/traefik-http.conf <<'EOF'
[Definition]
# JSON format: {"ClientAddr":"<HOST>","StatusCode":4xx/5xx}
failregex = ^.*"ClientAddr":"<HOST>".*"StatusCode":(4\d{2}|5\d{2}).*$
            ^.*"RemoteAddr":"<HOST>".*"Status":(4\d{2}|5\d{2}).*$
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/traefik-auth.conf <<'EOF'
[Definition]
# JSON format for auth failures
failregex = ^.*"ClientAddr":"<HOST>".*"StatusCode":(401|403).*$
            ^.*"RemoteAddr":"<HOST>".*"Status":(401|403).*$
            ^.*"ClientAddr":"<HOST>".*"RequestMethod":"POST".*"RequestPath":"/.*login.*".*"StatusCode":(401|403).*$
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/mailcow-auth.conf <<'EOF'
[Definition]
failregex = ^.*authentication failed.*from <HOST>.*$
            ^.*login failed.*<HOST>.*$
            ^.*invalid.*credentials.*<HOST>.*$
ignoreregex =
EOF

    cat > /etc/fail2ban/filter.d/bind9.conf <<'EOF'
[Definition]
failregex = ^.*client <HOST>#.*query.*denied.*$
            ^.*client <HOST>#.*query.*refused.*$
ignoreregex =
EOF

    systemctl enable fail2ban || true
    systemctl restart fail2ban || true
  fi
fi

# ========= wait for readiness =========
log_step "Waiting for controller and panel to become available"

# Wait for controller with proper polling and diagnostic on failure
log_info "Waiting for controller deployment..."
# Poll first to ensure deployment exists
for i in {1..30}; do
  if kubectl get deployment controller -n platform >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for controller deployment to appear... (${i}/30)"
  sleep 1
done

# Wait for deployment with periodic image pull error checks
log_info "Waiting for controller to become available (checking for image pull errors every 30s)..."
CONTROLLER_WAIT_START=$(date +%s)
CONTROLLER_LAST_CHECK=${CONTROLLER_WAIT_START}
CONTROLLER_CHECK_INTERVAL=30

while ! kubectl wait --for=condition=Available deployment/controller -n platform --timeout=30s 2>/dev/null; do
  CONTROLLER_CURRENT_TIME=$(date +%s)
  CONTROLLER_ELAPSED=$((CONTROLLER_CURRENT_TIME - CONTROLLER_WAIT_START))
  
  # Check for image pull errors every check_interval seconds
  if [ $((CONTROLLER_CURRENT_TIME - CONTROLLER_LAST_CHECK)) -ge ${CONTROLLER_CHECK_INTERVAL} ]; then
    CONTROLLER_LAST_CHECK=${CONTROLLER_CURRENT_TIME}
    if ! check_image_pull_errors "platform" "controller" "${CONTROLLER_IMAGE}"; then
      echo ""
      echo "⚠️  Image pull error detected. Deployment may fail."
      echo "   Continuing to wait, but you may need to fix the image issue..."
      echo ""
    fi
  fi
  
  # Check if we've exceeded the timeout
  if [ ${CONTROLLER_ELAPSED} -ge ${DEPLOYMENT_ROLLOUT_TIMEOUT} ]; then
    log_error "Controller deployment did not become available within ${DEPLOYMENT_ROLLOUT_TIMEOUT}s"
    check_image_pull_errors "platform" "controller" "${CONTROLLER_IMAGE}" || true
    diagnose_deployment "platform" "controller"
    exit 1
  fi
  
  # Show progress every 60 seconds
  if [ $((CONTROLLER_ELAPSED % 60)) -eq 0 ] && [ ${CONTROLLER_ELAPSED} -gt 0 ]; then
    echo "Still waiting... (${CONTROLLER_ELAPSED}s / ${DEPLOYMENT_ROLLOUT_TIMEOUT}s elapsed)"
  fi
done

log_ok "Controller deployment is available"

# Additional pod-level readiness check
log_info "Verifying controller pods are ready..."
CONTROLLER_PODS="$(kubectl get pods -n platform -l app=controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [ -z "${CONTROLLER_PODS}" ]; then
  log_error "No controller pods found"
  kubectl get pods -n platform -l app=controller || true
  exit 1
fi

for pod in ${CONTROLLER_PODS}; do
  echo "Waiting for pod ${pod} to be ready..."
  if ! kubectl wait --for=condition=Ready pod/"${pod}" -n platform --timeout="${DEPLOYMENT_ROLLOUT_TIMEOUT}s"; then
    log_error "Controller pod ${pod} did not become ready"
    echo "=== Pod Status ==="
    kubectl get pod "${pod}" -n platform -o yaml || true
    echo ""
    echo "=== Pod Events ==="
    kubectl describe pod "${pod}" -n platform || true
    echo ""
    echo "=== Pod Logs (last 100 lines) ==="
    kubectl logs "${pod}" -n platform --tail=100 || true
    exit 1
  fi
done
log_ok "All controller pods are ready"

# Wait for panel with proper polling
log_info "Waiting for panel deployment..."
for i in {1..30}; do
  if kubectl get deployment panel -n platform >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for panel deployment to appear... (${i}/30)"
  sleep 1
done

# Wait for deployment with periodic image pull error checks
log_info "Waiting for panel to become available (checking for image pull errors every 30s)..."
PANEL_WAIT_START=$(date +%s)
PANEL_LAST_CHECK=${PANEL_WAIT_START}
PANEL_CHECK_INTERVAL=30

while ! kubectl wait --for=condition=Available deployment/panel -n platform --timeout=30s 2>/dev/null; do
  PANEL_CURRENT_TIME=$(date +%s)
  PANEL_ELAPSED=$((PANEL_CURRENT_TIME - PANEL_WAIT_START))
  
  # Check for image pull errors every check_interval seconds
  if [ $((PANEL_CURRENT_TIME - PANEL_LAST_CHECK)) -ge ${PANEL_CHECK_INTERVAL} ]; then
    PANEL_LAST_CHECK=${PANEL_CURRENT_TIME}
    if ! check_image_pull_errors "platform" "panel" "${PANEL_IMAGE}"; then
      echo ""
      echo "⚠️  Image pull error detected. Deployment may fail."
      echo "   Continuing to wait, but you may need to fix the image issue..."
      echo ""
    fi
  fi
  
  # Check if we've exceeded the timeout
  if [ ${PANEL_ELAPSED} -ge ${DEPLOYMENT_ROLLOUT_TIMEOUT} ]; then
    log_error "Panel deployment did not become available within ${DEPLOYMENT_ROLLOUT_TIMEOUT}s"
    check_image_pull_errors "platform" "panel" "${PANEL_IMAGE}" || true
    diagnose_deployment "platform" "panel"
    exit 1
  fi
  
  # Show progress every 60 seconds
  if [ $((PANEL_ELAPSED % 60)) -eq 0 ] && [ ${PANEL_ELAPSED} -gt 0 ]; then
    echo "Still waiting... (${PANEL_ELAPSED}s / ${DEPLOYMENT_ROLLOUT_TIMEOUT}s elapsed)"
  fi
done

log_ok "Panel deployment is available"

# Additional pod-level readiness check for panel
log_info "Verifying panel pods are ready..."
PANEL_PODS="$(kubectl get pods -n platform -l app=panel -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [ -z "${PANEL_PODS}" ]; then
  log_error "No panel pods found"
  kubectl get pods -n platform -l app=panel || true
  exit 1
fi

for pod in ${PANEL_PODS}; do
  echo "Waiting for pod ${pod} to be ready..."
  if ! kubectl wait --for=condition=Ready pod/"${pod}" -n platform --timeout="${DEPLOYMENT_ROLLOUT_TIMEOUT}s"; then
    log_error "Panel pod ${pod} did not become ready"
    echo "=== Pod Status ==="
    kubectl get pod "${pod}" -n platform -o yaml || true
    echo ""
    echo "=== Pod Events ==="
    kubectl describe pod "${pod}" -n platform || true
    echo ""
    echo "=== Pod Logs (last 100 lines) ==="
    kubectl logs "${pod}" -n platform --tail=100 || true
    exit 1
  fi
done
log_ok "All panel pods are ready"

# Health check verification
log_step "Verifying health endpoints"
log_info "Checking controller health endpoint..."
CONTROLLER_POD="$(kubectl get pod -n platform -l app=controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "${CONTROLLER_POD}" ]; then
  # Try wget first, fallback to curl if wget not available
  if kubectl exec -n platform "${CONTROLLER_POD}" -- sh -c "command -v wget >/dev/null 2>&1 && wget -q -O- http://localhost:8080/health || (command -v curl >/dev/null 2>&1 && curl -sf http://localhost:8080/health || exit 1)" >/dev/null 2>&1; then
    log_ok "Controller health endpoint is responding"
  else
    log_warn "Controller health endpoint check failed (may be starting up or wget/curl not available)"
  fi
fi

# Final status check
log_step "Final status check"
echo "All pods in platform namespace:"
kubectl get pods -n platform -o wide
echo ""
echo "All pods in backup-system namespace:"
kubectl get pods -n backup-system -o wide 2>/dev/null || echo "backup-system namespace not found or no pods"
echo ""
echo "PVC status in platform namespace:"
kubectl get pvc -n platform

echo ""
# ========= Post-install sanity checks =========
log_step "Post-install sanity checks"

# Check Traefik pods are running
log_info "Checking Traefik installation..."
TRAEFIK_PODS="$(kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | grep -c Running || echo "0")"
TRAEFIK_PODS="${TRAEFIK_PODS//[^0-9]/}"  # Remove non-numeric characters
TRAEFIK_PODS="${TRAEFIK_PODS:-0}"  # Default to 0 if empty
if [ "${TRAEFIK_PODS}" -eq 0 ]; then
  log_warn "Traefik pods not found or not running in kube-system"
  echo "  Checking Traefik pods status:"
  kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik 2>/dev/null || true
  echo ""
  echo "  Checking Traefik deployment status:"
  kubectl get deployments -n kube-system -l app.kubernetes.io/name=traefik 2>/dev/null || true
  echo ""
  log_warn "Traefik may not be installed or may be in CrashLoopBackOff"
  log_warn "This may cause ingress issues. Check logs: kubectl logs -n kube-system -l app.kubernetes.io/name=traefik"
else
  log_ok "Traefik pods are running (${TRAEFIK_PODS} pod(s))"
fi

# Check if ports 80 and 443 are listening (Traefik should bind these)
log_info "Checking if Traefik is listening on ports 80 and 443..."
if command -v ss >/dev/null 2>&1; then
  PORT_80="$(ss -lntp 2>/dev/null | grep -c ':80 ' || echo "0")"
  PORT_443="$(ss -lntp 2>/dev/null | grep -c ':443 ' || echo "0")"
  PORT_80="${PORT_80//[^0-9]/}"  # Remove non-numeric characters
  PORT_443="${PORT_443//[^0-9]/}"  # Remove non-numeric characters
  PORT_80="${PORT_80:-0}"  # Default to 0 if empty
  PORT_443="${PORT_443:-0}"  # Default to 0 if empty
  if [ "${PORT_80}" -eq 0 ] && [ "${PORT_443}" -eq 0 ]; then
    log_warn "Ports 80 and 443 are not listening"
    log_warn "Traefik may not be properly configured or may not have started"
    log_warn "Check Traefik service: kubectl get svc -n kube-system -l app.kubernetes.io/name=traefik"
    log_warn "Check Traefik logs: kubectl logs -n kube-system -l app.kubernetes.io/name=traefik"
  elif [ "${PORT_80}" -eq 0 ]; then
    log_warn "Port 80 is not listening (port 443 is OK)"
  elif [ "${PORT_443}" -eq 0 ]; then
    log_warn "Port 443 is not listening (port 80 is OK)"
  else
    log_ok "Traefik is listening on ports 80 and 443"
  fi
elif command -v netstat >/dev/null 2>&1; then
  PORT_80="$(netstat -lntp 2>/dev/null | grep -c ':80 ' || echo "0")"
  PORT_443="$(netstat -lntp 2>/dev/null | grep -c ':443 ' || echo "0")"
  PORT_80="${PORT_80//[^0-9]/}"  # Remove non-numeric characters
  PORT_443="${PORT_443//[^0-9]/}"  # Remove non-numeric characters
  PORT_80="${PORT_80:-0}"  # Default to 0 if empty
  PORT_443="${PORT_443:-0}"  # Default to 0 if empty
  if [ "${PORT_80}" -eq 0 ] && [ "${PORT_443}" -eq 0 ]; then
    log_warn "Ports 80 and 443 are not listening"
    log_warn "Traefik may not be properly configured or may not have started"
  elif [ "${PORT_80}" -eq 0 ]; then
    log_warn "Port 80 is not listening (port 443 is OK)"
  elif [ "${PORT_443}" -eq 0 ]; then
    log_warn "Port 443 is not listening (port 80 is OK)"
  else
    log_ok "Traefik is listening on ports 80 and 443"
  fi
else
  log_info "Cannot check port bindings (ss/netstat not available)"
  log_info "Verify Traefik service manually: kubectl get svc -n kube-system -l app.kubernetes.io/name=traefik"
fi

log_ok "Installation complete"
echo "Panel: https://${PANEL_DOMAIN}"
echo "Panel admin username: ${PANEL_ADMIN_USERNAME}"
echo "Panel admin password: ${PANEL_ADMIN_PASSWORD}"
echo "pgAdmin: https://${PGADMIN_DOMAIN}"
echo "pgAdmin email: ${PGADMIN_EMAIL}"
echo "pgAdmin password: ${PGADMIN_PASSWORD}"
echo "Mailcow UI: https://${MAILCOW_DOMAIN}"
echo "Controller API key: ${CONTROLLER_API_KEY}"
echo "Postgres: ${POSTGRES_HOST}:${POSTGRES_PORT} (admin user: ${POSTGRES_ADMIN_USER})"
echo "Controller DB creds stored in platform-secrets (POSTGRES_ADMIN_PASSWORD)."
echo ""
echo "Next steps:"
echo "- Log in to the panel and create your first site."
echo "- Deploy a site image via POST /sites/:slug/deploy."
echo "- Point DNS to this server and enable TLS per site via PATCH /sites/:slug/tls."
echo "- Configure Mailcow DNS (MX/SPF/DKIM) before enabling mail."
echo "- Verify backups in user namespace PVCs (pvc-user-backup)."
echo ""
echo ""
echo ""
echo ""