#!/usr/bin/env bash
set -euo pipefail

# ========= error handling and logging =========
LAST_COMMAND=""
STEP_COUNTER=0

log_step() {
  STEP_COUNTER=$((STEP_COUNTER + 1))
  echo ""
  echo "=== [STEP] ${STEP_COUNTER}: $1 ==="
}

log_error() {
  echo "=== [ERROR] $1 ===" >&2
}

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
IMAGE_VALIDATION_TIMEOUT="${IMAGE_VALIDATION_TIMEOUT:-60}"

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
  
  # Check if kyverno namespace exists
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    return 0  # Kyverno not installed yet, nothing to fix
  fi
  
  echo "Ensuring Kyverno cleanup CronJobs are properly configured..."
  
  # First, ensure CronJobs are updated with correct image from manifest
  if [ -f "${SERVICES_DIR}/kyverno/install.yaml" ]; then
    echo "Updating CronJobs with correct image configuration..."
    kubectl apply --server-side --force-conflicts -f "${SERVICES_DIR}/kyverno/install.yaml" >/dev/null 2>&1 || true
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
    echo "✓ All CronJobs are using correct images."
  else
    echo "Re-applying manifest to force CronJob update..."
    kubectl apply --server-side --force-conflicts -f "${SERVICES_DIR}/kyverno/install.yaml" >/dev/null 2>&1 || true
  fi
  
  if [ ${fixed_count} -eq 0 ] && [ -z "${all_problem_pods}" ]; then
    echo "✓ No cleanup job issues found."
  fi
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

# Validate container image exists (for public images, check if pull would work)
validate_image() {
  local image="$1"
  local timeout="${2:-${IMAGE_VALIDATION_TIMEOUT}}"
  
  echo "Validating image: ${image}"
  
  # For local images, check if they exist in docker
  if [[ "${image}" == *":local" ]] || [[ "${image}" == "backup-"* ]]; then
    if docker image inspect "${image}" >/dev/null 2>&1; then
      echo "Image ${image} exists locally"
      return 0
    else
      log_error "Local image ${image} not found"
      return 1
    fi
  fi
  
  # For remote images, try to pull (with timeout)
  # Use docker pull with timeout to validate image exists
  # Note: This validates the image can be pulled, but we'll let k3s handle the actual pull
  if command -v timeout >/dev/null 2>&1; then
    if timeout "${timeout}" docker pull "${image}" >/dev/null 2>&1; then
      echo "Image ${image} validated (pull successful)"
      # Remove the pulled image to save space (k3s will pull it when needed)
      docker rmi "${image}" >/dev/null 2>&1 || true
      return 0
    else
      log_error "Failed to pull image ${image} within ${timeout}s"
      echo "This may indicate:"
      echo "  - Image does not exist at ${image}"
      echo "  - Network connectivity issues"
      echo "  - Authentication required (set GHCR_USERNAME and GHCR_TOKEN)"
      echo ""
      echo "If using private registry, ensure:"
      echo "  - GHCR_USERNAME and GHCR_TOKEN are set"
      echo "  - Image pull secret will be created in platform namespace"
      return 1
    fi
  else
    # Fallback: just try docker pull without timeout
    if docker pull "${image}" >/dev/null 2>&1; then
      echo "Image ${image} validated"
      # Remove the pulled image to save space
      docker rmi "${image}" >/dev/null 2>&1 || true
      return 0
    else
      log_error "Failed to pull image ${image}"
      echo "This may indicate:"
      echo "  - Image does not exist at ${image}"
      echo "  - Network connectivity issues"
      echo "  - Authentication required (set GHCR_USERNAME and GHCR_TOKEN)"
      return 1
    fi
  fi
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

  # Docker missing or daemon not running
  if ! command -v apt-get >/dev/null 2>&1; then
    log_error "Docker is required for backup image build, but automatic install is only supported on apt-get systems (Ubuntu/Debian)."
    exit 1
  fi

  echo "Docker not found or daemon not running; installing..."
  apt-get update -y
  apt-get install -y docker.io

  # Start and enable docker
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker
    sleep 3
  else
    service docker start
    sleep 3
  fi

  # Re-check docker daemon with retries
  local max_attempts=10
  local attempt=0
  while [ ${attempt} -lt ${max_attempts} ]; do
    if docker info >/dev/null 2>&1; then
      echo "Docker daemon is running."
      return 0
    fi
    attempt=$((attempt + 1))
    echo "Waiting for docker daemon... (attempt ${attempt}/${max_attempts})"
    sleep 2
  done

  log_error "Docker installation failed or daemon is not running after ${max_attempts} attempts."
  echo "Attempting to check docker status:"
  systemctl status docker || service docker status || true
  exit 1
}

PROMPT_IN="/dev/stdin"
if [[ ! -t 0 && -r /dev/tty ]]; then
  PROMPT_IN="/dev/tty"
fi

echo "== Voxeil Panel Installer =="

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
GHCR_OWNER="${GHCR_OWNER:-${GITHUB_REPOSITORY%%/*}}"
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
BACKUP_TOKEN="${BACKUP_TOKEN:-}"
MAILCOW_AUTH_USER="${MAILCOW_AUTH_USER:-admin}"
MAILCOW_AUTH_PASS="${MAILCOW_AUTH_PASS:-}"

# ========= inputs (interactive, with defaults) =========
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PANEL_TLS_ISSUER="${PANEL_TLS_ISSUER:-letsencrypt-prod}"
SITE_PORT_START="${SITE_PORT_START:-31000}"
SITE_PORT_END="${SITE_PORT_END:-31999}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-ghcr.io/ark322/voxeil-controller:latest}"
PANEL_IMAGE="${PANEL_IMAGE:-ghcr.io/ark322/voxeil-panel:latest}"

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
    ADMIN_PASSWORD="$(prompt_password "Admin password")"
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
if [[ -z "${BACKUP_TOKEN}" ]]; then
  BACKUP_TOKEN="$(openssl rand -hex 32)"
fi

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

# ========= ensure docker is installed FIRST (before k3s) =========
ensure_docker

# ========= build backup images BEFORE k3s (docker must be ready) =========
log_step "Building backup images (before k3s)"
if [[ ! -d infra/docker/images/backup-service || ! -d infra/docker/images/backup-runner ]]; then
  log_error "infra/docker/images/backup-service or backup-runner is missing."
  exit 1
fi

# Check Dockerfile existence
if [[ ! -f infra/docker/images/backup-service/Dockerfile ]]; then
  log_error "infra/docker/images/backup-service/Dockerfile is missing."
  exit 1
fi
if [[ ! -f infra/docker/images/backup-runner/Dockerfile ]]; then
  log_error "infra/docker/images/backup-runner/Dockerfile is missing."
  exit 1
fi

# Use buildx if available, fallback to legacy builder
BUILD_CMD="docker build"
if docker buildx version >/dev/null 2>&1; then
  echo "Using docker buildx"
  BUILD_CMD="docker buildx build --load"
else
  echo "Using legacy docker build (buildx not available)"
fi

# Build images with explicit tags (no spaces, proper naming)
echo "Building backup-service:local..."
${BUILD_CMD} -t backup-service:local infra/docker/images/backup-service || {
  log_error "Failed to build backup-service image"
  exit 1
}

echo "Building backup-runner:local..."
${BUILD_CMD} -t backup-runner:local infra/docker/images/backup-runner || {
  log_error "Failed to build backup-runner image"
  exit 1
}

# Verify images exist after build
if ! docker image inspect backup-service:local >/dev/null 2>&1; then
  log_error "backup-service:local image not found after build"
  exit 1
fi
if ! docker image inspect backup-runner:local >/dev/null 2>&1; then
  log_error "backup-runner:local image not found after build"
  exit 1
fi
echo "Backup images built successfully"

# ========= install k3s if needed =========
log_step "Installing k3s (if needed)"
if ! command -v kubectl >/dev/null 2>&1; then
  echo "Installing k3s..."
  curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
fi

need_cmd kubectl

# Wait for k3s API
wait_for_k3s_api

# Check kubectl context
check_kubectl_context

log_step "Waiting for node to be registered and ready"
echo "Waiting for node to be registered..."
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

echo "Node registered, waiting for Ready condition..."
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

# ========= render manifests to temp dir =========
RENDER_DIR="$(mktemp -d)"
if [[ ! -d "${RENDER_DIR}" ]]; then
  log_error "Failed to create temporary directory"
  exit 1
fi
# Cleanup temp dir on exit
cleanup_render_dir() {
  if [[ -n "${RENDER_DIR:-}" && -d "${RENDER_DIR}" ]]; then
    rm -rf "${RENDER_DIR}" || true
  fi
}
trap cleanup_render_dir EXIT

BACKUP_SYSTEM_NAME="backup-system"
SERVICES_DIR="${RENDER_DIR}/services"
TEMPLATES_DIR="${RENDER_DIR}/templates"
PLATFORM_DIR="${SERVICES_DIR}/platform"
BACKUP_SYSTEM_DIR="${SERVICES_DIR}/${BACKUP_SYSTEM_NAME}"

if [[ ! -d infra/k8s/services/infra-db ]]; then
  echo "infra/k8s/services/infra-db is missing; run from the repository root or download the full archive."
  exit 1
fi
if [[ ! -d infra/k8s/services/dns-zone ]]; then
  echo "infra/k8s/services/dns-zone is missing; run from the repository root or download the full archive."
  exit 1
fi
if [[ ! -d infra/k8s/services/mail-zone ]]; then
  echo "infra/k8s/services/mail-zone is missing; run from the repository root or download the full archive."
  exit 1
fi
if [[ ! -d infra/k8s/services/backup-system ]]; then
  echo "infra/k8s/services/backup-system is missing; run from the repository root or download the full archive."
  exit 1
fi
if [[ ! -d infra/k8s/services/cert-manager ]]; then
  echo "infra/k8s/services/cert-manager is missing; run from the repository root or download the full archive."
  exit 1
fi
if [[ ! -d infra/k8s/services/traefik ]]; then
  echo "infra/k8s/services/traefik is missing; run from the repository root or download the full archive."
  exit 1
fi
if [[ ! -d infra/k8s/services/kyverno ]]; then
  echo "infra/k8s/services/kyverno is missing; run from the repository root or download the full archive."
  exit 1
fi
if [[ ! -d infra/k8s/services/flux-system ]]; then
  echo "infra/k8s/services/flux-system is missing; run from the repository root or download the full archive."
  exit 1
fi
if [[ ! -d infra/k8s/services/platform ]]; then
  echo "infra/k8s/services/platform is missing; run from the repository root or download the full archive."
  exit 1
fi
if [[ ! -d infra/k8s/templates ]]; then
  echo "infra/k8s/templates is missing; run from the repository root or download the full archive."
  exit 1
fi
if ! mkdir -p "${SERVICES_DIR}"; then
  log_error "Failed to create services directory: ${SERVICES_DIR}"
  exit 1
fi
if ! cp -r infra/k8s/services/* "${SERVICES_DIR}/"; then
  log_error "Failed to copy services directory"
  exit 1
fi
if ! cp -r infra/k8s/templates "${TEMPLATES_DIR}"; then
  log_error "Failed to copy templates directory"
  exit 1
fi

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

echo "Templating manifests..."
# Check critical manifest files exist before templating
REQUIRED_MANIFESTS=(
  "${PLATFORM_DIR}/controller-deploy.yaml"
  "${PLATFORM_DIR}/panel-deploy.yaml"
  "${PLATFORM_DIR}/panel-ingress.yaml"
  "${PLATFORM_DIR}/panel-auth.yaml"
  "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml"
  "${SERVICES_DIR}/infra-db/postgres-secret.yaml"
  "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml"
  "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml"
  "${SERVICES_DIR}/infra-db/pgadmin-auth.yaml"
  "${SERVICES_DIR}/mail-zone/mailcow-core.yaml"
  "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml"
  "${SERVICES_DIR}/mail-zone/mailcow-auth.yaml"
  "${SERVICES_DIR}/dns-zone/tsig-secret.yaml"
  "${BACKUP_SYSTEM_DIR}/backup-service-secret.yaml"
)

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

sed -i "s|REPLACE_CONTROLLER_IMAGE|${CONTROLLER_IMAGE_ESC}|g" "${PLATFORM_DIR}/controller-deploy.yaml"
sed -i "s|REPLACE_PANEL_IMAGE|${PANEL_IMAGE_ESC}|g" "${PLATFORM_DIR}/panel-deploy.yaml"
sed -i "s|REPLACE_PANEL_DOMAIN|${PANEL_DOMAIN_ESC}|g" "${PLATFORM_DIR}/panel-ingress.yaml"
sed -i "s|REPLACE_PANEL_TLS_ISSUER|${PANEL_TLS_ISSUER_ESC}|g" "${PLATFORM_DIR}/panel-ingress.yaml"
sed -i "s|REPLACE_PANEL_BASICAUTH|${PANEL_BASICAUTH_B64_ESC}|g" "${PLATFORM_DIR}/panel-auth.yaml"
sed -i "s|REPLACE_LETSENCRYPT_EMAIL|${LETSENCRYPT_EMAIL_ESC}|g" "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml"
sed -i "s|REPLACE_POSTGRES_PASSWORD|${POSTGRES_PASSWORD_ESC}|g" "${SERVICES_DIR}/infra-db/postgres-secret.yaml"
sed -i "s|REPLACE_PGADMIN_EMAIL|${PGADMIN_EMAIL_ESC}|g" "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml"
sed -i "s|REPLACE_PGADMIN_PASSWORD|${PGADMIN_PASSWORD_ESC}|g" "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml"
sed -i "s|REPLACE_PGADMIN_DOMAIN|${PGADMIN_DOMAIN_ESC}|g" "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml"
sed -i "s|REPLACE_PANEL_TLS_ISSUER|${PANEL_TLS_ISSUER_ESC}|g" "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml"
sed -i "s|REPLACE_PGADMIN_BASICAUTH|${PGADMIN_BASICAUTH_ESC}|g" "${SERVICES_DIR}/infra-db/pgadmin-auth.yaml"
sed -i "s|REPLACE_MAILCOW_HOSTNAME|${MAILCOW_DOMAIN_ESC}|g" "${SERVICES_DIR}/mail-zone/mailcow-core.yaml"
sed -i "s|REPLACE_MAILCOW_DOMAIN|${MAILCOW_DOMAIN_ESC}|g" "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml"
sed -i "s|REPLACE_MAILCOW_TLS_ISSUER|${MAILCOW_TLS_ISSUER_ESC}|g" "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml"
sed -i "s|REPLACE_MAILCOW_BASICAUTH|${MAILCOW_BASICAUTH_ESC}|g" "${SERVICES_DIR}/mail-zone/mailcow-auth.yaml"
sed -i "s|REPLACE_ME_BASE64LIKE|${TSIG_SECRET_ESC}|g" "${SERVICES_DIR}/dns-zone/tsig-secret.yaml"
sed -i "s|REPLACE_BACKUP_TOKEN|${BACKUP_TOKEN_ESC}|g" "${BACKUP_SYSTEM_DIR}/backup-service-secret.yaml"
if grep -rl "REPLACE_IMAGE_BASE" "${BACKUP_SYSTEM_DIR}" >/dev/null 2>&1; then
  echo "ERROR: REPLACE_IMAGE_BASE placeholder not fully replaced in backup-system manifests."
  exit 1
fi
if grep -q "REPLACE_PANEL_BASICAUTH" "${PLATFORM_DIR}/panel-auth.yaml"; then
  echo "ERROR: REPLACE_PANEL_BASICAUTH placeholder not fully replaced in panel-auth.yaml."
  exit 1
fi

# Validate that all REPLACE_* placeholders (except those in backup-job-templates-configmap.yaml which are runtime templates) are replaced
log_step "Validating all REPLACE_* placeholders are replaced"
REMAINING_PLACEHOLDERS=$(find "${SERVICES_DIR}" "${PLATFORM_DIR}" -type f \( -name "*.yaml" -o -name "*.yml" \) ! -name "backup-job-templates-configmap.yaml" -exec grep -l "REPLACE_" {} + 2>/dev/null | xargs grep -h "REPLACE_" 2>/dev/null | grep -v "REPLACE_SITE_SLUG\|REPLACE_TENANT_NAMESPACE\|REPLACE_DB_" | sort -u || true)
if [[ -n "${REMAINING_PLACEHOLDERS}" ]]; then
  echo "ERROR: The following REPLACE_* placeholders were not replaced:"
  echo "${REMAINING_PLACEHOLDERS}"
  exit 1
fi

# ========= apply =========
log_step "Applying Traefik entrypoints config"
if [[ ! -d "${SERVICES_DIR}/traefik" ]]; then
  log_error "Traefik directory missing: ${SERVICES_DIR}/traefik"
  exit 1
fi
kubectl apply -f "${SERVICES_DIR}/traefik"

log_step "Installing cert-manager (cluster-wide)"
if [[ ! -f "${SERVICES_DIR}/cert-manager/cert-manager.yaml" ]]; then
  log_error "cert-manager.yaml missing: ${SERVICES_DIR}/cert-manager/cert-manager.yaml"
  exit 1
fi

# Check if Kyverno is installed and might cause webhook timeouts
if kubectl get namespace kyverno >/dev/null 2>&1; then
  echo "Kyverno namespace detected, checking webhook readiness..."
  # Wait a moment for Kyverno webhooks to be responsive
  sleep 2
  echo "Checking Kyverno deployments..."
  
  # Check if Kyverno admission controller deployment exists
  # Use a short timeout for get command to avoid hanging
  if kubectl get deployment kyverno-admission-controller -n kyverno --request-timeout=5s >/dev/null 2>&1; then
    echo "Checking Kyverno admission controller readiness (timeout: 30s)..."
    # kubectl wait has a timeout, make it non-blocking
    # Suppress stderr to avoid noise, but allow exit code to be checked
    if kubectl wait --for=condition=Available deployment/kyverno-admission-controller -n kyverno --timeout=30s --request-timeout=35s 2>/dev/null; then
      echo "✓ Kyverno admission controller is ready"
    else
      echo "⚠ Warning: Kyverno admission controller may not be fully ready (timeout or not available)"
      echo "  Proceeding anyway - this may cause webhook timeouts during cert-manager installation."
    fi
  else
    echo "Kyverno admission controller deployment not found (may be installing or using different name)"
  fi
  
  # Also check for other common Kyverno deployments (non-blocking)
  if kubectl get deployment kyverno -n kyverno --request-timeout=5s >/dev/null 2>&1; then
    echo "Checking Kyverno main deployment readiness (timeout: 30s)..."
    if kubectl wait --for=condition=Available deployment/kyverno -n kyverno --timeout=30s --request-timeout=35s 2>/dev/null; then
      echo "✓ Kyverno main deployment is ready"
    else
      echo "⚠ Kyverno main deployment not ready yet (proceeding anyway)"
    fi
  fi
  echo "Proceeding with cert-manager installation..."
else
  echo "Kyverno namespace not found (will be installed later)"
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
echo "Waiting for cert-manager CRDs..."
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
echo "Waiting for cert-manager deployments..."
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
echo "Applying ClusterIssuers."
if [[ -f "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml" ]]; then
  retry_apply "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml" "ClusterIssuers" 3 || {
    log_error "Failed to apply ClusterIssuers after retries"
    echo "Continuing anyway - ClusterIssuers can be applied later"
  }
fi

log_step "Installing Kyverno (idempotent)"
# Idempotent namespace creation
kubectl apply -f "${SERVICES_DIR}/kyverno/namespace.yaml"

# Idempotent Kyverno installation: use server-side apply with force-conflicts
KYVERNO_MANIFEST="${SERVICES_DIR}/kyverno/install.yaml"
echo "Applying Kyverno manifests (server-side, idempotent)..."
kubectl apply --server-side --force-conflicts -f "${KYVERNO_MANIFEST}" || {
  log_error "Failed to apply Kyverno manifests"
  exit 1
}
echo "Kyverno resources applied successfully"

# Immediately fix cleanup jobs to ensure they use correct images
# This prevents old bitnami/kubectl images from being used
fix_kyverno_cleanup_jobs

# Wait for Kyverno deployments with proper polling
echo "Waiting for Kyverno deployments to be available..."
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
  exit 1
}

# Apply policies (idempotent) - wait a bit for Kyverno to be fully ready
echo "Waiting for Kyverno to be fully operational..."
sleep 5
echo "Applying Kyverno policies..."
kubectl apply -f "${SERVICES_DIR}/kyverno/policies.yaml"

# Wait a moment for policies to be active
echo "Waiting for policies to be active..."
sleep 3

# Fix any failed cleanup jobs (e.g., ImagePullBackOff from old bitnami/kubectl images)
fix_kyverno_cleanup_jobs

log_step "Installing Flux controllers"
kubectl apply -f "${SERVICES_DIR}/flux-system/namespace.yaml"
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
echo "Waiting for Flux deployments..."
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

log_step "Applying platform base manifests"
kubectl apply -f "${PLATFORM_DIR}/namespace.yaml"
kubectl apply -f "${PLATFORM_DIR}/rbac.yaml"
# Ensure serviceAccount exists before applying deployment (required for Kyverno policies)
if ! kubectl get serviceaccount controller-sa -n platform >/dev/null 2>&1; then
  echo "Creating controller-sa serviceAccount..."
  kubectl apply -f "${PLATFORM_DIR}/rbac.yaml"
fi
kubectl apply -f "${PLATFORM_DIR}/pvc.yaml"
kubectl apply -f "${PLATFORM_DIR}/platform-secrets.yaml"
kubectl apply -f "${PLATFORM_DIR}/panel-auth.yaml"
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

# Validate controller image before applying deployment (non-blocking)
log_step "Validating controller image"
if ! validate_image "${CONTROLLER_IMAGE}"; then
  echo "WARNING: Controller image validation failed: ${CONTROLLER_IMAGE}"
  echo "Continuing anyway - k3s will attempt to pull the image during deployment."
  echo "If the image doesn't exist, the deployment will fail and you'll need to:"
  echo "  - Build and push the image to ${CONTROLLER_IMAGE}"
  echo "  - Or set GHCR_USERNAME and GHCR_TOKEN if the image is private"
  echo ""
fi

# Validate panel image before applying deployment (non-blocking)
log_step "Validating panel image"
if ! validate_image "${PANEL_IMAGE}"; then
  echo "WARNING: Panel image validation failed: ${PANEL_IMAGE}"
  echo "Continuing anyway - k3s will attempt to pull the image during deployment."
  echo "If the image doesn't exist, the deployment will fail and you'll need to:"
  echo "  - Build and push the image to ${PANEL_IMAGE}"
  echo "  - Or set GHCR_USERNAME and GHCR_TOKEN if the image is private"
  echo ""
fi

log_step "Applying infra DB manifests"
kubectl apply -f "${SERVICES_DIR}/infra-db/namespace.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/postgres-secret.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pvc.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/postgres-service.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/postgres-statefulset.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/networkpolicy.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pgadmin-auth.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pgadmin-svc.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pgadmin-deploy.yaml"

# Wait for postgres StatefulSet to be ready (PVC will bind when pod is scheduled)
# This is critical because controller depends on postgres
echo "Waiting for postgres StatefulSet to be ready..."
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
  local postgres_pod
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
echo "Waiting for pgadmin Deployment to be ready..."
# Poll first to ensure Deployment exists
for i in {1..30}; do
  if kubectl get deployment pgadmin -n infra-db >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! kubectl wait --for=condition=Available deployment/pgadmin -n infra-db --timeout="${DEPLOYMENT_ROLLOUT_TIMEOUT}s"; then
  log_error "pgadmin Deployment did not become available within ${DEPLOYMENT_ROLLOUT_TIMEOUT}s"
  echo "=== pgadmin Pod Status ==="
  kubectl get pods -n infra-db -l app=pgadmin || true
  echo ""
  kubectl describe deployment pgadmin -n infra-db || true
  exit 1
fi
echo "pgadmin Deployment is ready"

# Now apply platform workloads after postgres is ready
log_step "Applying platform workloads"
kubectl apply -f "${PLATFORM_DIR}/controller-deploy.yaml"
kubectl apply -f "${PLATFORM_DIR}/controller-svc.yaml"
kubectl apply -f "${PLATFORM_DIR}/panel-deploy.yaml"
kubectl apply -f "${PLATFORM_DIR}/panel-svc.yaml"

log_step "Applying DNS (bind9) manifests"
kubectl apply -f "${SERVICES_DIR}/dns-zone/namespace.yaml"
kubectl apply -f "${SERVICES_DIR}/dns-zone/tsig-secret.yaml"
kubectl apply -f "${SERVICES_DIR}/dns-zone/pvc.yaml"
kubectl apply -f "${SERVICES_DIR}/dns-zone/bind9.yaml"

# Wait for bind9 Deployment to be ready (PVC will bind when pod is scheduled)
echo "Waiting for bind9 Deployment to be ready..."
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
echo "bind9 Deployment is ready"

log_step "Applying mailcow manifests"
kubectl apply -f "${SERVICES_DIR}/mail-zone/namespace.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-secrets.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-auth.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-core.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/networkpolicy.yaml"

# Wait for mailcow-mysql StatefulSet to be ready (PVC will bind when pod is scheduled)
# This is critical because other mailcow components (php-fpm, postfix, dovecot) depend on mysql
echo "Waiting for mailcow-mysql StatefulSet to be ready..."
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
echo "mailcow-mysql StatefulSet is ready"

log_step "Importing backup images to k3s"
# Images were already built before k3s installation
# Verify images exist before import
if ! docker image inspect backup-service:local >/dev/null 2>&1; then
  log_error "backup-service:local image not found. Cannot import to k3s."
  exit 1
fi
if ! docker image inspect backup-runner:local >/dev/null 2>&1; then
  log_error "backup-runner:local image not found. Cannot import to k3s."
  exit 1
fi

# Check k3s command exists
if ! command -v k3s >/dev/null 2>&1; then
  log_error "k3s command not found. Cannot import images."
  exit 1
fi

# Check if images already imported (idempotent)
if k3s ctr images list | grep -q "backup-service:local"; then
  echo "backup-service:local already imported, skipping..."
else
  echo "Importing backup-service:local to k3s..."
  docker save backup-service:local | k3s ctr images import - || {
    log_error "Failed to import backup-service:local to k3s"
    exit 1
  }
fi

if k3s ctr images list | grep -q "backup-runner:local"; then
  echo "backup-runner:local already imported, skipping..."
else
  echo "Importing backup-runner:local to k3s..."
  docker save backup-runner:local | k3s ctr images import - || {
    log_error "Failed to import backup-runner:local to k3s"
    exit 1
  }
fi

# Verify images in k3s
echo "Verifying images in k3s..."
k3s ctr images list | grep -E "(backup-service|backup-runner)" || {
  log_error "Backup images not found in k3s after import"
  exit 1
}

log_step "Applying backup-system manifests"
backup_apply "${BACKUP_SYSTEM_DIR}/namespace.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/serviceaccount.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/rbac.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/pvc.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-scripts-configmap.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-job-templates-configmap.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-service-secret.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-service-deploy.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-service-svc.yaml"

# Wait for backup-service Deployment to be ready (PVC will bind when pod is scheduled)
echo "Waiting for backup-service Deployment to be ready..."
# Poll first to ensure Deployment exists
for i in {1..30}; do
  if kubectl get deployment backup-service -n backup-system >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! kubectl wait --for=condition=Available deployment/backup-service -n backup-system --timeout="${DEPLOYMENT_ROLLOUT_TIMEOUT}s"; then
  log_error "backup-service Deployment did not become available within ${DEPLOYMENT_ROLLOUT_TIMEOUT}s"
  echo "=== backup-service Pod Status ==="
  kubectl get pods -n backup-system -l app=backup-service || true
  echo ""
  kubectl describe deployment backup-service -n backup-system || true
  echo ""
  echo "=== PVC Status ==="
  kubectl get pvc -n backup-system || true
  exit 1
fi
echo "backup-service Deployment is ready"

log_step "Applying ingresses"
kubectl apply -f "${PLATFORM_DIR}/panel-ingress.yaml"
kubectl apply -f "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml"
kubectl apply -f "${SERVICES_DIR}/dns-zone/traefik-tcp"
kubectl apply -f "${SERVICES_DIR}/mail-zone/traefik-tcp"
kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml"

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

ports_tcp=(22 80 443 25 465 587 143 993 110 995 53)
ports_udp=(53)

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

allow_all=true
if [[ -s "${ALLOWLIST_FILE}" ]]; then
  allow_all=false
fi

if [[ "${allow_all}" == "true" ]]; then
  for port in "${ports_tcp[@]}"; do
    ufw allow "${port}/tcp"
  done
  for port in "${ports_udp[@]}"; do
    ufw allow "${port}/udp"
  done
else
  while IFS= read -r line; do
    entry="$(echo "${line}" | xargs)"
    [[ -z "${entry}" ]] && continue
    [[ "${entry}" == \#* ]] && continue
    for port in "${ports_tcp[@]}"; do
      ufw allow from "${entry}" to any port "${port}" proto tcp
    done
    for port in "${ports_udp[@]}"; do
      ufw allow from "${entry}" to any port "${port}" proto udp
    done
  done < "${ALLOWLIST_FILE}"
fi

if [[ "${EXPOSE_CONTROLLER}" =~ ^[Yy]$ ]]; then
  echo "Controller exposure is disabled by default."
fi

ufw --force enable
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
    cat > /etc/fail2ban/jail.d/voxeil.conf <<'EOF'
[sshd]
enabled = true
bantime = 1h
findtime = 10m
maxretry = 5
EOF
    systemctl enable fail2ban || true
    systemctl restart fail2ban || true
  fi
  
  # Disable SSH root login for security
  echo "Configuring SSH security..."
  if [ -f /etc/ssh/sshd_config ]; then
    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.voxeil-backup.$(date +%Y%m%d_%H%M%S) || true
    
    # Disable root login
    if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
      sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    else
      echo "PermitRootLogin no" >> /etc/ssh/sshd_config
    fi
    
    # Ensure password authentication is still enabled (for non-root users)
    if grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then
      sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    else
      echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
    fi
    
    # Reload SSH config if systemctl is available
    if command -v systemctl >/dev/null 2>&1; then
      systemctl reload sshd || systemctl reload ssh || true
      echo "SSH root login disabled. Please ensure you have a non-root user with sudo access."
    fi
  fi
fi

# ========= wait for readiness =========
log_step "Waiting for controller and panel to become available"

# Wait for controller with proper polling and diagnostic on failure
echo "Waiting for controller deployment..."
# Poll first to ensure deployment exists
for i in {1..30}; do
  if kubectl get deployment controller -n platform >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for controller deployment to appear... (${i}/30)"
  sleep 1
done

if ! kubectl wait --for=condition=Available deployment/controller -n platform --timeout="${DEPLOYMENT_ROLLOUT_TIMEOUT}s"; then
  log_error "Controller deployment did not become available within ${DEPLOYMENT_ROLLOUT_TIMEOUT}s"
  diagnose_deployment "platform" "controller"
  exit 1
fi

# Additional pod-level readiness check
echo "Verifying controller pods are ready..."
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
echo "All controller pods are ready"

# Wait for panel with proper polling
echo "Waiting for panel deployment..."
for i in {1..30}; do
  if kubectl get deployment panel -n platform >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for panel deployment to appear... (${i}/30)"
  sleep 1
done

if ! kubectl wait --for=condition=Available deployment/panel -n platform --timeout="${DEPLOYMENT_ROLLOUT_TIMEOUT}s"; then
  log_error "Panel deployment did not become available within ${DEPLOYMENT_ROLLOUT_TIMEOUT}s"
  diagnose_deployment "platform" "panel"
  exit 1
fi

# Additional pod-level readiness check for panel
echo "Verifying panel pods are ready..."
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
echo "All panel pods are ready"

# Health check verification
log_step "Verifying health endpoints"
echo "Checking controller health endpoint..."
CONTROLLER_POD="$(kubectl get pod -n platform -l app=controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "${CONTROLLER_POD}" ]; then
  # Try wget first, fallback to curl if wget not available
  if kubectl exec -n platform "${CONTROLLER_POD}" -- sh -c "command -v wget >/dev/null 2>&1 && wget -q -O- http://localhost:8080/health || (command -v curl >/dev/null 2>&1 && curl -sf http://localhost:8080/health || exit 1)" >/dev/null 2>&1; then
    echo "Controller health endpoint is responding"
  else
    echo "WARNING: Controller health endpoint check failed (may be starting up or wget/curl not available)"
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
echo "Done."
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
echo "- Verify backups in the backup-system PVC (mounted at /backups)."
echo ""
echo ""
echo ""