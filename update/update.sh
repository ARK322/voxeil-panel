#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

K3S_BIN=""
if command -v k3s >/dev/null 2>&1; then
  K3S_BIN="k3s"
elif [[ -x /usr/local/bin/k3s ]]; then
  K3S_BIN="/usr/local/bin/k3s"
else
  echo "ERROR: k3s not found. Install k3s or ensure it is in PATH."
  exit 1
fi

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
else
  KUBECTL=("${K3S_BIN}" kubectl)
fi

CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-ghcr.io/ark322/voxeil-controller:latest}"
PANEL_IMAGE="${PANEL_IMAGE:-ghcr.io/ark322/voxeil-panel:latest}"
BACKUP_SERVICE_IMAGE="${BACKUP_SERVICE_IMAGE:-backup-service:local}"

echo "Updating platform images..."
"${KUBECTL[@]}" -n platform set image deploy/controller controller="${CONTROLLER_IMAGE}"
"${KUBECTL[@]}" -n platform set image deploy/panel panel="${PANEL_IMAGE}"
"${KUBECTL[@]}" -n platform rollout status deploy/controller --timeout=180s
"${KUBECTL[@]}" -n platform rollout status deploy/panel --timeout=180s

echo "Updating backup-service image..."
"${KUBECTL[@]}" -n backup-system set image deploy/backup-service backup-service="${BACKUP_SERVICE_IMAGE}"
"${KUBECTL[@]}" -n backup-system rollout status deploy/backup-service --timeout=180s

echo "OK: platform + backup-service images updated."
