#!/usr/bin/env bash
set -euo pipefail

# ========= helpers =========
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48; }

echo "== Voxeil Panel Installer =="

need_cmd curl
need_cmd sed
need_cmd mktemp

# ========= GHCR credentials =========
if [[ -z "${GHCR_USERNAME:-}" ]]; then
  echo "GHCR_USERNAME env var is required."
  exit 1
fi
if [[ -z "${GHCR_TOKEN:-}" ]]; then
  echo "GHCR_TOKEN env var is required."
  exit 1
fi
GHCR_EMAIL="${GHCR_EMAIL:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

# ========= inputs (defaults only) =========
PANEL_NODEPORT="${PANEL_NODEPORT:-30080}"
EXPOSE_CONTROLLER="${EXPOSE_CONTROLLER:-N}"
CONTROLLER_NODEPORT="${CONTROLLER_NODEPORT:-30081}"
SITE_PORT_START="${SITE_PORT_START:-31000}"
SITE_PORT_END="${SITE_PORT_END:-31999}"
ALLOW_IP="${ALLOW_IP:-}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-}"
PANEL_IMAGE="${PANEL_IMAGE:-}"
if [[ -z "${CONTROLLER_IMAGE}" ]]; then echo "CONTROLLER_IMAGE env var is required."; exit 1; fi
if [[ -z "${PANEL_IMAGE}" ]]; then echo "PANEL_IMAGE env var is required."; exit 1; fi
if [[ -z "${LETSENCRYPT_EMAIL}" ]]; then
  echo "LETSENCRYPT_EMAIL env var is required."
  exit 1
fi

CONTROLLER_API_KEY="$(rand)"
PANEL_ADMIN_PASSWORD="$(rand)"
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-$(rand)}}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${POSTGRES_ADMIN_PASSWORD}}"
POSTGRES_HOST="${POSTGRES_HOST:-postgres.infra.svc.cluster.local}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
MAILCOW_API_URL="${MAILCOW_API_URL:-http://mailcow-api.mail-zone.svc.cluster.local}"
MAILCOW_API_KEY="${MAILCOW_API_KEY:-$(rand)}"
MAILCOW_DB_NAME="${MAILCOW_DB_NAME:-mailcow}"
MAILCOW_DB_USER="${MAILCOW_DB_USER:-mailcow}"
MAILCOW_DB_PASSWORD="${MAILCOW_DB_PASSWORD:-$(rand)}"
MAILCOW_DB_ROOT_PASSWORD="${MAILCOW_DB_ROOT_PASSWORD:-$(rand)}"

echo ""
echo "Config:"
echo "  Panel NodePort: ${PANEL_NODEPORT}"
echo "  Controller NodePort (optional): ${CONTROLLER_NODEPORT} (enabled? ${EXPOSE_CONTROLLER})"
echo "  Site NodePort range: ${SITE_PORT_START}-${SITE_PORT_END}"
echo "  Allowlist: ${ALLOW_IP:-<none>}"
echo "  GHCR Username: ${GHCR_USERNAME}"
echo "  GHCR Email: ${GHCR_EMAIL:-<none>}"
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

if [[ ! -d infra/k8s/platform ]]; then
  echo "infra/k8s/platform is missing; run from the repository root or download the full archive."
  exit 1
fi
cp -r infra/k8s/platform "${RENDER_DIR}/platform"
if [[ -d infra/k8s/mailcow ]]; then
  cp -r infra/k8s/mailcow "${RENDER_DIR}/mailcow"
fi
if [[ -d infra/k8s/infra-db ]]; then
  cp -r infra/k8s/infra-db "${RENDER_DIR}/infra-db"
fi
if [[ -d infra/k8s/backup ]]; then
  cp -r infra/k8s/backup "${RENDER_DIR}/backup"
fi
cp -r infra/k8s/cert-manager "${RENDER_DIR}/cert-manager"

cat > "${RENDER_DIR}/platform/platform-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: platform-secrets
  namespace: platform
type: Opaque
stringData:
  ADMIN_API_KEY: "${CONTROLLER_API_KEY}"
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

if [[ -d "${RENDER_DIR}/mailcow" ]]; then
  cat > "${RENDER_DIR}/mailcow/mailcow-secrets.yaml" <<EOF
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
fi

echo "Templating manifests..."
sed -i "s|REPLACE_CONTROLLER_IMAGE|${CONTROLLER_IMAGE}|g" "${RENDER_DIR}/platform/controller-deploy.yaml"
sed -i "s|REPLACE_PANEL_IMAGE|${PANEL_IMAGE}|g" "${RENDER_DIR}/platform/panel-deploy.yaml"
sed -i "s|REPLACE_PANEL_NODEPORT|${PANEL_NODEPORT}|g" "${RENDER_DIR}/platform/panel-svc.yaml"
sed -i "s|REPLACE_CONTROLLER_NODEPORT|${CONTROLLER_NODEPORT}|g" "${RENDER_DIR}/platform/controller-nodeport.yaml"
if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
  sed -i "s|REPLACE_LETSENCRYPT_EMAIL|${LETSENCRYPT_EMAIL}|g" "${RENDER_DIR}/cert-manager/cluster-issuers.yaml"
fi
if [[ -d "${RENDER_DIR}/infra-db" ]]; then
  sed -i "s|REPLACE_POSTGRES_PASSWORD|${POSTGRES_PASSWORD}|g" "${RENDER_DIR}/infra-db/postgres-secret.yaml"
fi

# ========= apply =========
echo "Applying platform manifests..."
kubectl apply -f "${RENDER_DIR}/platform/namespace.yaml"
kubectl apply -f "${RENDER_DIR}/platform/rbac.yaml"
kubectl apply -f "${RENDER_DIR}/platform/platform-secrets.yaml"
kubectl create secret docker-registry ghcr-pull-secret \
  -n platform \
  --docker-server=ghcr.io \
  --docker-username="${GHCR_USERNAME}" \
  --docker-password="${GHCR_TOKEN}" \
  ${GHCR_EMAIL:+--docker-email="${GHCR_EMAIL}"} \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${RENDER_DIR}/platform/controller-deploy.yaml"
kubectl apply -f "${RENDER_DIR}/platform/controller-svc.yaml"
kubectl apply -f "${RENDER_DIR}/platform/panel-deploy.yaml"
kubectl apply -f "${RENDER_DIR}/platform/panel-svc.yaml"

if [[ -d "${RENDER_DIR}/infra-db" ]]; then
  echo "Applying infra DB manifests..."
  kubectl apply -f "${RENDER_DIR}/infra-db"
fi

if [[ -d "${RENDER_DIR}/backup" ]]; then
  echo "Applying backup manifests..."
  mkdir -p /backups/sites
  if ! kubectl apply -f "${RENDER_DIR}/backup"; then
    echo "Warning: failed to apply backup manifests; continuing install."
  fi
fi

if [[ -d "${RENDER_DIR}/mailcow" ]]; then
  echo "Applying mailcow manifests..."
  kubectl apply -f "${RENDER_DIR}/mailcow/namespace.yaml"
  kubectl apply -f "${RENDER_DIR}/mailcow/mailcow-secrets.yaml"
  kubectl apply -f "${RENDER_DIR}/mailcow/mailcow-core.yaml"
  kubectl apply -f "${RENDER_DIR}/mailcow/networkpolicy.yaml"
  if [[ -d "${RENDER_DIR}/mailcow/traefik-tcp" ]]; then
    kubectl apply -f "${RENDER_DIR}/mailcow/traefik-tcp"
  fi
fi

echo "Installing cert-manager (cluster-wide)..."
kubectl apply -f "${RENDER_DIR}/cert-manager/cert-manager.yaml"
echo "Applying ClusterIssuers."
kubectl apply -f "${RENDER_DIR}/cert-manager/cluster-issuers.yaml"

if [[ "${EXPOSE_CONTROLLER}" =~ ^[Yy]$ ]]; then
  kubectl apply -f "${RENDER_DIR}/platform/controller-nodeport.yaml"
fi

# ========= optional: UFW allowlist =========
if command -v ufw >/dev/null 2>&1 && [[ -n "${ALLOW_IP}" ]]; then
  echo "Configuring UFW allowlist..."
  ufw --force enable
  ufw allow from "${ALLOW_IP}" to any port "${PANEL_NODEPORT}" proto tcp
  ufw allow from "${ALLOW_IP}" to any port "${SITE_PORT_START}:${SITE_PORT_END}" proto tcp
  if [[ "${EXPOSE_CONTROLLER}" =~ ^[Yy]$ ]]; then
    ufw allow from "${ALLOW_IP}" to any port "${CONTROLLER_NODEPORT}" proto tcp
  fi
else
  echo "UFW skipped (no allowlist provided or ufw missing)."
fi

# ========= wait for readiness =========
echo "Waiting for controller and panel to become available..."
kubectl wait --for=condition=Available deployment/controller -n platform --timeout=180s
kubectl wait --for=condition=Available deployment/panel -n platform --timeout=180s

echo ""
echo "Done."
echo "Panel: http://<VPS_IP>:${PANEL_NODEPORT}"
echo "Panel admin password: ${PANEL_ADMIN_PASSWORD}"
echo "Controller API key: ${CONTROLLER_API_KEY}"
echo "Postgres: ${POSTGRES_HOST}:${POSTGRES_PORT} (admin user: ${POSTGRES_ADMIN_USER})"
echo "Controller DB creds stored in platform-secrets (POSTGRES_ADMIN_PASSWORD)."
echo ""
echo "Next steps:"
echo "- Log in to the panel and create your first site."
echo "- Deploy a site image via POST /sites/:slug/deploy."
echo "- Point DNS to this server and enable TLS per site via PATCH /sites/:slug/tls."
echo "- Configure Mailcow DNS (MX/SPF/DKIM) before enabling mail."
echo "- Verify backups in /backups/sites if backups are enabled."
echo ""