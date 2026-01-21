#!/usr/bin/env bash
set -euo pipefail

# ========= helpers =========
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 || true; }
backup_apply() {
  kubectl apply -f "$1" || {
    echo "Backup manifests failed to apply; aborting (backup is required)."
    exit 1
  }
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
PANEL_ADMIN_PASSWORD="${PANEL_ADMIN_PASSWORD:-$(rand)}"
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-$(rand)}}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${POSTGRES_ADMIN_PASSWORD}}"
POSTGRES_HOST="${POSTGRES_HOST:-postgres.infra.svc.cluster.local}"
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

# ========= install k3s if needed =========
if ! command -v kubectl >/dev/null 2>&1; then
  echo "Installing k3s..."
  curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
fi

need_cmd kubectl

echo "Waiting for node to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=180s

# ========= render manifests to temp dir =========
RENDER_DIR="$(mktemp -d)"
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
mkdir -p "${SERVICES_DIR}"
cp -r infra/k8s/services/* "${SERVICES_DIR}/"
cp -r infra/k8s/templates "${TEMPLATES_DIR}"

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
IMAGE_BASE="ghcr.io/${GHCR_OWNER}/${GHCR_REPO}"
if grep -rl "REPLACE_IMAGE_BASE" "${BACKUP_SYSTEM_DIR}" >/dev/null 2>&1; then
  grep -rl "REPLACE_IMAGE_BASE" "${BACKUP_SYSTEM_DIR}" | xargs sed -i "s|REPLACE_IMAGE_BASE|${IMAGE_BASE}|g"
fi
sed -i "s|REPLACE_CONTROLLER_IMAGE|${CONTROLLER_IMAGE}|g" "${PLATFORM_DIR}/controller-deploy.yaml"
sed -i "s|REPLACE_PANEL_IMAGE|${PANEL_IMAGE}|g" "${PLATFORM_DIR}/panel-deploy.yaml"
sed -i "s|REPLACE_PANEL_DOMAIN|${PANEL_DOMAIN}|g" "${PLATFORM_DIR}/panel-ingress.yaml"
sed -i "s|REPLACE_PANEL_TLS_ISSUER|${PANEL_TLS_ISSUER}|g" "${PLATFORM_DIR}/panel-ingress.yaml"
sed -i "s|REPLACE_PANEL_BASICAUTH|${PANEL_BASICAUTH_B64}|g" "${PLATFORM_DIR}/panel-auth.yaml"
sed -i "s|REPLACE_LETSENCRYPT_EMAIL|${LETSENCRYPT_EMAIL}|g" "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml"
sed -i "s|REPLACE_POSTGRES_PASSWORD|${POSTGRES_PASSWORD}|g" "${SERVICES_DIR}/infra-db/postgres-secret.yaml"
sed -i "s|REPLACE_PGADMIN_EMAIL|${PGADMIN_EMAIL}|g" "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml"
sed -i "s|REPLACE_PGADMIN_PASSWORD|${PGADMIN_PASSWORD}|g" "${SERVICES_DIR}/infra-db/pgadmin-secret.yaml"
sed -i "s|REPLACE_PGADMIN_DOMAIN|${PGADMIN_DOMAIN}|g" "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml"
sed -i "s|REPLACE_PANEL_TLS_ISSUER|${PANEL_TLS_ISSUER}|g" "${SERVICES_DIR}/infra-db/pgadmin-ingress.yaml"
sed -i "s|REPLACE_PGADMIN_BASICAUTH|${PGADMIN_BASICAUTH}|g" "${SERVICES_DIR}/infra-db/pgadmin-auth.yaml"
sed -i "s|REPLACE_MAILCOW_HOSTNAME|${MAILCOW_DOMAIN}|g" "${SERVICES_DIR}/mail-zone/mailcow-core.yaml"
sed -i "s|REPLACE_MAILCOW_DOMAIN|${MAILCOW_DOMAIN}|g" "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml"
sed -i "s|REPLACE_MAILCOW_TLS_ISSUER|${MAILCOW_TLS_ISSUER}|g" "${SERVICES_DIR}/mail-zone/mailcow-ingress.yaml"
sed -i "s|REPLACE_MAILCOW_BASICAUTH|${MAILCOW_BASICAUTH}|g" "${SERVICES_DIR}/mail-zone/mailcow-auth.yaml"
sed -i "s|REPLACE_ME_BASE64LIKE|${TSIG_SECRET}|g" "${SERVICES_DIR}/dns-zone/tsig-secret.yaml"
sed -i "s|REPLACE_BACKUP_TOKEN|${BACKUP_TOKEN}|g" "${BACKUP_SYSTEM_DIR}/backup-service-secret.yaml"
if grep -rl "REPLACE_IMAGE_BASE" "${BACKUP_SYSTEM_DIR}" >/dev/null 2>&1; then
  echo "ERROR: REPLACE_IMAGE_BASE placeholder not fully replaced in backup-system manifests."
  exit 1
fi
if grep -q "REPLACE_PANEL_BASICAUTH" "${PLATFORM_DIR}/panel-auth.yaml"; then
  echo "ERROR: REPLACE_PANEL_BASICAUTH placeholder not fully replaced in panel-auth.yaml."
  exit 1
fi

# ========= apply =========
echo "Applying Traefik entrypoints config..."
kubectl apply -f "${SERVICES_DIR}/traefik"

echo "Installing cert-manager (cluster-wide)..."
kubectl apply -f "${SERVICES_DIR}/cert-manager/cert-manager.yaml"
kubectl wait --for=condition=Established crd/certificates.cert-manager.io --timeout=180s
kubectl wait --for=condition=Established crd/certificaterequests.cert-manager.io --timeout=180s
kubectl wait --for=condition=Established crd/challenges.acme.cert-manager.io --timeout=180s
kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout=180s
kubectl wait --for=condition=Established crd/issuers.cert-manager.io --timeout=180s
kubectl wait --for=condition=Established crd/orders.acme.cert-manager.io --timeout=180s
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=180s
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=180s
kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=180s
echo "Applying ClusterIssuers."
if [[ -f "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml" ]]; then
  kubectl apply -f "${SERVICES_DIR}/cert-manager/cluster-issuers.yaml"
fi

echo "Installing Kyverno..."
kubectl apply -f "${SERVICES_DIR}/kyverno/namespace.yaml"
kubectl create -f "${SERVICES_DIR}/kyverno/install.yaml" --save-config=false || \
kubectl replace -f "${SERVICES_DIR}/kyverno/install.yaml" --force
kubectl wait --for=condition=Available deployment -n kyverno --all --timeout=300s
kubectl apply -f "${SERVICES_DIR}/kyverno/policies.yaml"

echo "Installing Flux controllers..."
kubectl apply -f "${SERVICES_DIR}/flux-system/namespace.yaml"
FLUX_INSTALL_URL="https://github.com/fluxcd/flux2/releases/download/v2.3.0/install.yaml"
curl -sfL "${FLUX_INSTALL_URL}" -o "${SERVICES_DIR}/flux-system/install.yaml"
kubectl apply -f "${SERVICES_DIR}/flux-system/install.yaml"
kubectl wait --for=condition=Available deployment -n flux-system --all --timeout=300s

echo "Applying platform base manifests..."
kubectl apply -f "${PLATFORM_DIR}/namespace.yaml"
kubectl apply -f "${PLATFORM_DIR}/rbac.yaml"
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

echo "Applying platform workloads..."
kubectl apply -f "${PLATFORM_DIR}/controller-deploy.yaml"
kubectl apply -f "${PLATFORM_DIR}/controller-svc.yaml"
kubectl apply -f "${PLATFORM_DIR}/panel-deploy.yaml"
kubectl apply -f "${PLATFORM_DIR}/panel-svc.yaml"

echo "Applying infra DB manifests..."
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

echo "Applying DNS (bind9) manifests..."
kubectl apply -f "${SERVICES_DIR}/dns-zone/namespace.yaml"
kubectl apply -f "${SERVICES_DIR}/dns-zone/tsig-secret.yaml"
kubectl apply -f "${SERVICES_DIR}/dns-zone/pvc.yaml"
kubectl apply -f "${SERVICES_DIR}/dns-zone/bind9.yaml"

echo "Applying mailcow manifests..."
kubectl apply -f "${SERVICES_DIR}/mail-zone/namespace.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-secrets.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-auth.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/mailcow-core.yaml"
kubectl apply -f "${SERVICES_DIR}/mail-zone/networkpolicy.yaml"

echo "Building and importing backup images..."
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is required to build backup images."
  exit 1
fi
if [[ ! -d infra/docker/images/backup-service || ! -d infra/docker/images/backup-runner ]]; then
  echo "ERROR: infra/docker/images/backup-service or backup-runner is missing."
  exit 1
fi
docker build -t backup-service:local infra/docker/images/backup-service
docker build -t backup-runner:local infra/docker/images/backup-runner
docker save backup-service:local | k3s ctr images import -
docker save backup-runner:local | k3s ctr images import -

echo "Applying backup-system manifests..."
backup_apply "${BACKUP_SYSTEM_DIR}/namespace.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/serviceaccount.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/rbac.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/pvc.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-scripts-configmap.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-job-templates-configmap.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-service-secret.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-service-deploy.yaml"
backup_apply "${BACKUP_SYSTEM_DIR}/backup-service-svc.yaml"

echo "Applying ingresses..."
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
fi

# ========= wait for readiness =========
echo "Waiting for controller and panel to become available..."
kubectl wait --for=condition=Available deployment/controller -n platform --timeout=180s
kubectl wait --for=condition=Available deployment/panel -n platform --timeout=180s

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