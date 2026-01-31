#!/usr/bin/env bash
# Install phase: Generate required secrets
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/lib/common.sh"
source "${REPO_ROOT}/lib/kube.sh"
if [ -f "${REPO_ROOT}/lib/prompt.sh" ]; then
  source "${REPO_ROOT}/lib/prompt.sh"
else
  # Fallback if prompt.sh doesn't exist (backward compatibility)
  is_interactive() {
    if [ "${VOXEIL_CI:-0}" = "1" ] || [ "${CI:-}" = "true" ] || [ ! -t 0 ]; then
      return 1
    fi
    return 0
  }
  prompt_value() {
    local label="$1"
    local default_value="${2:-}"
    local is_secret="${3:-false}"
    local env_var
    env_var="VOXEIL_$(echo "${label}" | tr '[:lower:] ' '[:upper:]_' | tr -d '()')"
    if [ -n "${!env_var:-}" ]; then
      echo "${!env_var}"
      return 0
    fi
    if [ -n "${default_value}" ]; then
      echo "${default_value}"
      return 0
    fi
    if [ "${is_secret}" = "true" ]; then
      rand
    else
      echo ""
    fi
  }
fi

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

# Prompt for critical configuration if interactive
if is_interactive; then
  log_info "Interactive mode: Please provide the following information"
  echo ""
fi

# Panel domain (required for ingress)
PANEL_DOMAIN=""
PANEL_DOMAIN=$(prompt_value "Panel Domain" "${VOXEIL_PANEL_DOMAIN:-}" "false")
if [ -z "${PANEL_DOMAIN}" ]; then
  if is_interactive; then
    log_error "Panel domain is required"
    exit 1
  else
    log_warn "Panel domain not provided, using placeholder (ingress will be excluded)"
    PANEL_DOMAIN="REPLACE_PANEL_DOMAIN"
  fi
fi

# SSL/TLS issuer (optional, defaults to letsencrypt-prod)
TLS_ISSUER=""
TLS_ISSUER=$(prompt_value "TLS Issuer (ClusterIssuer name)" "${VOXEIL_TLS_ISSUER:-letsencrypt-prod}" "false")
if [ -z "${TLS_ISSUER}" ]; then
  TLS_ISSUER="letsencrypt-prod"
fi

# Panel admin credentials
PANEL_ADMIN_USERNAME=""
PANEL_ADMIN_USERNAME=$(prompt_value "Panel Admin Username" "${VOXEIL_PANEL_ADMIN_USERNAME:-admin}" "false")
if [ -z "${PANEL_ADMIN_USERNAME}" ]; then
  PANEL_ADMIN_USERNAME="admin"
fi

PANEL_ADMIN_PASSWORD=""
if is_interactive; then
  PANEL_ADMIN_PASSWORD=$(prompt_value "Panel Admin Password" "" "true")
  if [ -z "${PANEL_ADMIN_PASSWORD}" ]; then
    log_warn "No password provided, generating random password"
    PANEL_ADMIN_PASSWORD=$(rand)
  fi
else
  # Non-interactive: use env var or generate
  PANEL_ADMIN_PASSWORD=$(get_or_generate_secret "PANEL_ADMIN_PASSWORD" "VOXEIL_PANEL_ADMIN_PASSWORD")
fi

PANEL_ADMIN_EMAIL=""
PANEL_ADMIN_EMAIL=$(prompt_value "Panel Admin Email" "${VOXEIL_PANEL_ADMIN_EMAIL:-admin@${PANEL_DOMAIN}}" "false")
if [ -z "${PANEL_ADMIN_EMAIL}" ]; then
  PANEL_ADMIN_EMAIL="admin@${PANEL_DOMAIN}"
fi

# Other secrets (can be auto-generated)
ADMIN_API_KEY=""
ADMIN_API_KEY=$(get_or_generate_secret "ADMIN_API_KEY" "VOXEIL_ADMIN_API_KEY")
JWT_SECRET=""
JWT_SECRET=$(get_or_generate_secret "JWT_SECRET" "VOXEIL_JWT_SECRET")
SITE_NODEPORT_START=""
SITE_NODEPORT_START=$(get_or_generate_secret "SITE_NODEPORT_START" "VOXEIL_SITE_NODEPORT_START" 'echo "30000"')
SITE_NODEPORT_END=""
SITE_NODEPORT_END=$(get_or_generate_secret "SITE_NODEPORT_END" "VOXEIL_SITE_NODEPORT_END" 'echo "32767"')
MAILCOW_API_URL=""
MAILCOW_API_URL=$(get_or_generate_secret "MAILCOW_API_URL" "VOXEIL_MAILCOW_API_URL" 'echo "http://mailcow.mail-zone.svc.cluster.local"')
MAILCOW_API_KEY=""
MAILCOW_API_KEY=$(get_or_generate_secret "MAILCOW_API_KEY" "VOXEIL_MAILCOW_API_KEY" 'echo ""')
POSTGRES_HOST=""
POSTGRES_HOST=$(get_or_generate_secret "POSTGRES_HOST" "VOXEIL_POSTGRES_HOST" 'echo "postgres.infra-db.svc.cluster.local"')
POSTGRES_PORT=""
POSTGRES_PORT=$(get_or_generate_secret "POSTGRES_PORT" "VOXEIL_POSTGRES_PORT" 'echo "5432"')
POSTGRES_ADMIN_USER=""
POSTGRES_ADMIN_USER=$(get_or_generate_secret "POSTGRES_ADMIN_USER" "VOXEIL_POSTGRES_ADMIN_USER" 'echo "postgres"')
POSTGRES_ADMIN_PASSWORD=""
POSTGRES_ADMIN_PASSWORD=$(get_or_generate_secret "POSTGRES_ADMIN_PASSWORD" "VOXEIL_POSTGRES_ADMIN_PASSWORD")
POSTGRES_DB=""
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
  run_kubectl delete secret platform-secrets --namespace=platform --request-timeout=30s --ignore-not-found >/dev/null 2>&1
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

# Save panel domain and TLS issuer to state.env for later use
if ! grep -q "^PANEL_DOMAIN=" "${STATE_ENV_FILE}" 2>/dev/null; then
  echo "PANEL_DOMAIN=${PANEL_DOMAIN}" >> "${STATE_ENV_FILE}"
  chmod 600 "${STATE_ENV_FILE}"
fi
if ! grep -q "^TLS_ISSUER=" "${STATE_ENV_FILE}" 2>/dev/null; then
  echo "TLS_ISSUER=${TLS_ISSUER}" >> "${STATE_ENV_FILE}"
  chmod 600 "${STATE_ENV_FILE}"
fi

# Ensure dns-zone namespace exists and create bind9-tsig secret
log_info "Ensuring dns-zone namespace and bind9-tsig secret..."

# Ensure dns-zone namespace exists
if ! run_kubectl get namespace dns-zone >/dev/null 2>&1; then
  log_info "Creating dns-zone namespace..."
  run_kubectl create namespace dns-zone || true
  run_kubectl label namespace dns-zone app.kubernetes.io/part-of=voxeil app.kubernetes.io/managed-by=voxeil voxeil.io/owned=true --overwrite || true
fi

# Generate or retrieve TSIG secret values
TSIG_NAME="voxeil-tsig"
TSIG_ALG="hmac-sha256"

# Generate TSIG_SECRET as a secure random base64 string (minimum 16 bytes for hmac-sha256)
if command_exists openssl; then
  TSIG_SECRET=$(openssl rand -base64 32 | tr -d '\n' || rand)
else
  # Fallback to rand() if openssl not available
  TSIG_SECRET=$(rand)
fi

# Check if we have a stored value in state.env
if [ -f "${STATE_ENV_FILE}" ]; then
  stored_tsig=$(grep "^BIND9_TSIG_SECRET=" "${STATE_ENV_FILE}" 2>/dev/null | cut -d'=' -f2- || echo "")
  if [ -n "${stored_tsig}" ]; then
    TSIG_SECRET="${stored_tsig}"
  else
    # Save generated value
    echo "BIND9_TSIG_SECRET=${TSIG_SECRET}" >> "${STATE_ENV_FILE}"
    chmod 600 "${STATE_ENV_FILE}"
  fi
fi

# Create bind9-tsig secret (idempotent)
log_info "Creating bind9-tsig secret in dns-zone namespace..."
if ! run_kubectl get secret bind9-tsig -n dns-zone >/dev/null 2>&1; then
  run_kubectl create secret generic bind9-tsig \
    --namespace=dns-zone \
    --from-literal=TSIG_NAME="${TSIG_NAME}" \
    --from-literal=TSIG_ALG="${TSIG_ALG}" \
    --from-literal=TSIG_SECRET="${TSIG_SECRET}" >/dev/null 2>&1 || {
    log_error "Failed to create bind9-tsig secret"
    exit 1
  }
  log_ok "bind9-tsig secret created"
else
  log_info "bind9-tsig secret already exists, skipping creation"
fi

log_ok "Secret generation phase complete"
