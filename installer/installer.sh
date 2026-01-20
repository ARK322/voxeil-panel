#!/usr/bin/env bash
set -euo pipefail

# ========= helpers =========
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48; }

echo "== Voxeil Panel Installer =="

need_cmd curl
need_cmd sed
need_cmd mktemp

GHCR_USERNAME="${GHCR_USERNAME:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
GHCR_EMAIL="${GHCR_EMAIL:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
PANEL_ADMIN_USERNAME="${PANEL_ADMIN_USERNAME:-}"
PANEL_ADMIN_PASSWORD="${PANEL_ADMIN_PASSWORD:-}"
PANEL_ADMIN_EMAIL="${PANEL_ADMIN_EMAIL:-}"
PGADMIN_EMAIL="${PGADMIN_EMAIL:-}"
PGADMIN_PASSWORD="${PGADMIN_PASSWORD:-}"
PGADMIN_DOMAIN="${PGADMIN_DOMAIN:-}"

# ========= inputs (interactive, with defaults) =========
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PANEL_TLS_ISSUER="${PANEL_TLS_ISSUER:-letsencrypt-prod}"
SITE_PORT_START="${SITE_PORT_START:-31000}"
SITE_PORT_END="${SITE_PORT_END:-31999}"
CONTROLLER_NODEPORT="${CONTROLLER_NODEPORT:-30081}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-ghcr.io/ark322/voxeil-controller:latest}"
PANEL_IMAGE="${PANEL_IMAGE:-ghcr.io/ark322/voxeil-panel:latest}"

prompt_with_default() {
  local label="$1"
  local current="$2"
  local input=""
  read -r -p "${label} [${current}]: " input
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
      read -r -p "${label} [${current}]: " input
      if [[ -z "${input}" ]]; then
        printf "%s" "${current}"
        return
      fi
      printf "%s" "${input}"
      return
    else
      read -r -p "${label}: " input
      if [[ -n "${input}" ]]; then
        printf "%s" "${input}"
        return
      fi
    fi
  done
}

echo ""
echo "== Config prompts =="
LETSENCRYPT_EMAIL="$(prompt_required "Let's Encrypt email" "${LETSENCRYPT_EMAIL}")"
PANEL_DOMAIN="$(prompt_required "Panel domain (e.g. panel.example.com)" "${PANEL_DOMAIN}")"
PANEL_ADMIN_USERNAME="$(prompt_required "Panel admin username" "${PANEL_ADMIN_USERNAME:-admin}")"
PANEL_ADMIN_EMAIL="$(prompt_required "Panel admin email" "${PANEL_ADMIN_EMAIL:-}")"
if [[ -z "${PGADMIN_DOMAIN}" ]]; then
  PGADMIN_DOMAIN="pgadmin.${PANEL_DOMAIN}"
fi
if [[ -z "${PGADMIN_EMAIL}" ]]; then
  PGADMIN_EMAIL="${PANEL_ADMIN_EMAIL}"
fi
if [[ -z "${PGADMIN_PASSWORD}" ]]; then
  PGADMIN_PASSWORD="$(rand)"
fi
PGADMIN_EMAIL="$(prompt_required "pgAdmin email" "${PGADMIN_EMAIL}")"
PGADMIN_PASSWORD="$(prompt_required "pgAdmin password" "${PGADMIN_PASSWORD}")"

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
MAILCOW_DB_NAME="${MAILCOW_DB_NAME:-mailcow}"
MAILCOW_DB_USER="${MAILCOW_DB_USER:-mailcow}"
MAILCOW_DB_PASSWORD="${MAILCOW_DB_PASSWORD:-$(rand)}"
MAILCOW_DB_ROOT_PASSWORD="${MAILCOW_DB_ROOT_PASSWORD:-$(rand)}"

echo ""
echo "Config:"
echo "  Panel domain: ${PANEL_DOMAIN}"
echo "  Panel TLS issuer: ${PANEL_TLS_ISSUER}"
echo "  Panel admin username: ${PANEL_ADMIN_USERNAME}"
echo "  Panel admin email: ${PANEL_ADMIN_EMAIL}"
echo "  pgAdmin domain: ${PGADMIN_DOMAIN}"
echo "  pgAdmin email: ${PGADMIN_EMAIL}"
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
if [[ -d infra/k8s/dns ]]; then
  cp -r infra/k8s/dns "${RENDER_DIR}/dns"
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
sed -i "s|REPLACE_CONTROLLER_NODEPORT|${CONTROLLER_NODEPORT}|g" "${RENDER_DIR}/platform/controller-nodeport.yaml"
sed -i "s|REPLACE_PANEL_DOMAIN|${PANEL_DOMAIN}|g" "${RENDER_DIR}/platform/panel-ingress.yaml"
sed -i "s|REPLACE_PANEL_TLS_ISSUER|${PANEL_TLS_ISSUER}|g" "${RENDER_DIR}/platform/panel-ingress.yaml"
if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
  sed -i "s|REPLACE_LETSENCRYPT_EMAIL|${LETSENCRYPT_EMAIL}|g" "${RENDER_DIR}/cert-manager/cluster-issuers.yaml"
fi
if [[ -d "${RENDER_DIR}/infra-db" ]]; then
  sed -i "s|REPLACE_POSTGRES_PASSWORD|${POSTGRES_PASSWORD}|g" "${RENDER_DIR}/infra-db/postgres-secret.yaml"
  sed -i "s|REPLACE_PGADMIN_EMAIL|${PGADMIN_EMAIL}|g" "${RENDER_DIR}/infra-db/pgadmin-secret.yaml"
  sed -i "s|REPLACE_PGADMIN_PASSWORD|${PGADMIN_PASSWORD}|g" "${RENDER_DIR}/infra-db/pgadmin-secret.yaml"
  sed -i "s|REPLACE_PGADMIN_DOMAIN|${PGADMIN_DOMAIN}|g" "${RENDER_DIR}/infra-db/pgadmin-ingress.yaml"
  sed -i "s|REPLACE_PANEL_TLS_ISSUER|${PANEL_TLS_ISSUER}|g" "${RENDER_DIR}/infra-db/pgadmin-ingress.yaml"
fi

# ========= apply =========
echo "Applying platform manifests..."
kubectl apply -f "${RENDER_DIR}/platform/namespace.yaml"
kubectl apply -f "${RENDER_DIR}/platform/rbac.yaml"
kubectl apply -f "${RENDER_DIR}/platform/platform-secrets.yaml"
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
kubectl apply -f "${RENDER_DIR}/platform/controller-deploy.yaml"
kubectl apply -f "${RENDER_DIR}/platform/controller-svc.yaml"
kubectl apply -f "${RENDER_DIR}/platform/panel-deploy.yaml"
kubectl apply -f "${RENDER_DIR}/platform/panel-svc.yaml"
kubectl apply -f "${RENDER_DIR}/platform/panel-ingress.yaml"

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

if [[ -d "${RENDER_DIR}/dns" ]]; then
  echo "Applying DNS (bind9) manifests..."
  kubectl apply -f "${RENDER_DIR}/dns/namespace.yaml"
  kubectl apply -f "${RENDER_DIR}/dns/bind9.yaml"
  if [[ -d "${RENDER_DIR}/dns/traefik-tcp" ]]; then
    kubectl apply -f "${RENDER_DIR}/dns/traefik-tcp"
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

echo "Controller stays internal (no NodePort)."

# ========= optional: UFW allowlist =========
mkdir -p /etc/voxeil
cat > /etc/voxeil/installer.env <<EOF
EXPOSE_CONTROLLER="N"
CONTROLLER_NODEPORT="30081"
EOF
touch /etc/voxeil/allowlist.txt

cat > /usr/local/bin/voxeil-ufw-apply <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ALLOWLIST_FILE="/etc/voxeil/allowlist.txt"
CONF="/etc/voxeil/installer.env"
EXPOSE_CONTROLLER="N"
CONTROLLER_NODEPORT="30081"
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