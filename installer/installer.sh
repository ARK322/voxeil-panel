#!/usr/bin/env bash
set -euo pipefail

# ========= helpers =========
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48; }

echo "== Voxeil Panel Installer =="

need_cmd curl
need_cmd sed
need_cmd mktemp

# ========= inputs =========
read -rp "Panel NodePort [30080]: " PANEL_NODEPORT
PANEL_NODEPORT="${PANEL_NODEPORT:-30080}"

read -rp "Expose controller via NodePort for admin use? [y/N]: " EXPOSE_CONTROLLER
EXPOSE_CONTROLLER="${EXPOSE_CONTROLLER:-N}"
read -rp "Controller NodePort [30081]: " CONTROLLER_NODEPORT
CONTROLLER_NODEPORT="${CONTROLLER_NODEPORT:-30081}"

read -rp "Site NodePort range start [31000]: " SITE_PORT_START
SITE_PORT_START="${SITE_PORT_START:-31000}"

read -rp "Site NodePort range end [31999]: " SITE_PORT_END
SITE_PORT_END="${SITE_PORT_END:-31999}"

read -rp "Allowlist your IP/CIDR for NodePorts (recommended) [empty=skip]: " ALLOW_IP

read -rp "Controller image (full ref, e.g. registry/user/controller:tag): " CONTROLLER_IMAGE
if [[ -z "${CONTROLLER_IMAGE}" ]]; then echo "controller image required"; exit 1; fi

read -rp "Panel image (full ref, e.g. registry/user/panel:tag): " PANEL_IMAGE
if [[ -z "${PANEL_IMAGE}" ]]; then echo "panel image required"; exit 1; fi

CONTROLLER_API_KEY="$(rand)"
PANEL_ADMIN_PASSWORD="$(rand)"

echo ""
echo "Config:"
echo "  Panel NodePort: ${PANEL_NODEPORT}"
echo "  Controller NodePort (optional): ${CONTROLLER_NODEPORT} (enabled? ${EXPOSE_CONTROLLER})"
echo "  Site NodePort range: ${SITE_PORT_START}-${SITE_PORT_END}"
echo "  Allowlist: ${ALLOW_IP:-<none>}"
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
cp -r infra/k8s/platform "${RENDER_DIR}/platform"

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
EOF

echo "Templating manifests..."
sed -i "s|REPLACE_CONTROLLER_IMAGE|${CONTROLLER_IMAGE}|g" "${RENDER_DIR}/platform/controller-deploy.yaml"
sed -i "s|REPLACE_PANEL_IMAGE|${PANEL_IMAGE}|g" "${RENDER_DIR}/platform/panel-deploy.yaml"
sed -i "s|REPLACE_PANEL_NODEPORT|${PANEL_NODEPORT}|g" "${RENDER_DIR}/platform/panel-svc.yaml"
sed -i "s|REPLACE_CONTROLLER_NODEPORT|${CONTROLLER_NODEPORT}|g" "${RENDER_DIR}/platform/controller-nodeport.yaml"

# ========= apply =========
echo "Applying platform manifests..."
kubectl apply -f "${RENDER_DIR}/platform/namespace.yaml"
kubectl apply -f "${RENDER_DIR}/platform/rbac.yaml"
kubectl apply -f "${RENDER_DIR}/platform/platform-secrets.yaml"
kubectl apply -f "${RENDER_DIR}/platform/controller-deploy.yaml"
kubectl apply -f "${RENDER_DIR}/platform/controller-svc.yaml"
kubectl apply -f "${RENDER_DIR}/platform/panel-deploy.yaml"
kubectl apply -f "${RENDER_DIR}/platform/panel-svc.yaml"

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
echo ""
