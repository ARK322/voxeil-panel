#!/usr/bin/env bash
# Install phase: Generate required secrets
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "install/15-secrets"

# Ensure kubectl is available
ensure_kubectl || exit 1
check_kubectl_context || exit 1

# Ensure state directory exists
ensure_state_dir

# Load existing state.env if present
if [ -f "${STATE_ENV_FILE}" ]; then
  log_info "Loading existing secrets from ${STATE_ENV_FILE}"
  # shellcheck disable=SC1090
  set +u
  source "${STATE_ENV_FILE}" 2>/dev/null || true
  set -u
fi

# Helper to get or generate a secret value
get_or_generate_secret() {
  local key="$1"
  local env_var="$2"
  local default_generator="${3:-rand}"
  
  # Check if already in state.env
  if [ -f "${STATE_ENV_FILE}" ]; then
    local existing_value
    existing_value=$(grep "^${key}=" "${STATE_ENV_FILE}" 2>/dev/null | cut -d'=' -f2- || echo "")
    if [ -n "${existing_value}" ]; then
      echo "${existing_value}"
      return 0
    fi
  fi
  
  # Check environment variable
  if [ -n "${env_var}" ] && [ -n "${!env_var:-}" ]; then
    echo "${!env_var}"
    return 0
  fi
  
  # Generate new value
  local new_value
  if [ "${default_generator}" = "rand" ]; then
    new_value=$(rand)
  else
    new_value=$(eval "${default_generator}")
  fi
  
  # Save to state.env
  if ! grep -q "^${key}=" "${STATE_ENV_FILE}" 2>/dev/null; then
    echo "${key}=${new_value}" >> "${STATE_ENV_FILE}"
    chmod 600 "${STATE_ENV_FILE}"
  fi
  
  echo "${new_value}"
}

# Generate all required secrets
log_info "Generating platform secrets..."

ADMIN_API_KEY=$(get_or_generate_secret "ADMIN_API_KEY" "VOXEIL_ADMIN_API_KEY")
JWT_SECRET=$(get_or_generate_secret "JWT_SECRET" "VOXEIL_JWT_SECRET")
PANEL_ADMIN_USERNAME=$(get_or_generate_secret "PANEL_ADMIN_USERNAME" "VOXEIL_PANEL_ADMIN_USERNAME" 'echo "admin"')
PANEL_ADMIN_PASSWORD=$(get_or_generate_secret "PANEL_ADMIN_PASSWORD" "VOXEIL_PANEL_ADMIN_PASSWORD")
PANEL_ADMIN_EMAIL=$(get_or_generate_secret "PANEL_ADMIN_EMAIL" "VOXEIL_PANEL_ADMIN_EMAIL" 'echo "admin@voxeil.local"')
SITE_NODEPORT_START=$(get_or_generate_secret "SITE_NODEPORT_START" "VOXEIL_SITE_NODEPORT_START" 'echo "30000"')
SITE_NODEPORT_END=$(get_or_generate_secret "SITE_NODEPORT_END" "VOXEIL_SITE_NODEPORT_END" 'echo "32767"')
MAILCOW_API_URL=$(get_or_generate_secret "MAILCOW_API_URL" "VOXEIL_MAILCOW_API_URL" 'echo "http://mailcow.mail-zone.svc.cluster.local"')
MAILCOW_API_KEY=$(get_or_generate_secret "MAILCOW_API_KEY" "VOXEIL_MAILCOW_API_KEY" 'echo ""')
POSTGRES_HOST=$(get_or_generate_secret "POSTGRES_HOST" "VOXEIL_POSTGRES_HOST" 'echo "postgres.infra-db.svc.cluster.local"')
POSTGRES_PORT=$(get_or_generate_secret "POSTGRES_PORT" "VOXEIL_POSTGRES_PORT" 'echo "5432"')
POSTGRES_ADMIN_USER=$(get_or_generate_secret "POSTGRES_ADMIN_USER" "VOXEIL_POSTGRES_ADMIN_USER" 'echo "postgres"')
POSTGRES_ADMIN_PASSWORD=$(get_or_generate_secret "POSTGRES_ADMIN_PASSWORD" "VOXEIL_POSTGRES_ADMIN_PASSWORD")
POSTGRES_DB=$(get_or_generate_secret "POSTGRES_DB" "VOXEIL_POSTGRES_DB" 'echo "voxeil"')

# Ensure platform namespace exists
if ! run_kubectl get namespace platform >/dev/null 2>&1; then
  log_info "Creating platform namespace..."
  run_kubectl create namespace platform || true
  run_kubectl label namespace platform app.kubernetes.io/part-of=voxeil app.kubernetes.io/managed-by=voxeil voxeil.io/owned=true --overwrite || true
fi

# Create or update platform-secrets secret
log_info "Creating platform-secrets secret in platform namespace..."

# Use create with --dry-run=client and pipe to apply for idempotency
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
  --from-literal=POSTGRES_DB="${POSTGRES_DB}" \
  --dry-run=client -o yaml 2>/dev/null | run_kubectl apply -f - >/dev/null 2>&1 || {
  # If create fails, try to delete and recreate
  log_info "Secret may already exist, updating..."
  run_kubectl delete secret platform-secrets --namespace=platform --ignore-not-found >/dev/null 2>&1
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
    log_error "Failed to create platform-secrets secret"
    exit 1
  }
}

log_ok "Platform secrets created/updated (secrets not printed to stdout)"
log_info "Secret values are stored in ${STATE_ENV_FILE} (if generated)"

log_ok "Secret generation phase complete"
