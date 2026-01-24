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

echo "Pre-update cleanup: Checking for stuck resources..."
# Clean up stuck pods with image pull errors (non-destructive)
for ns in platform backup-system; do
  if "${KUBECTL[@]}" get namespace "${ns}" >/dev/null 2>&1; then
    failed_pods="$("${KUBECTL[@]}" get pods -n "${ns}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | \
      grep -E "(ImagePullBackOff|ErrImagePull)" | cut -f1 || true)"
    
    if [ -n "${failed_pods}" ]; then
      echo "  Found stuck pods in ${ns}, cleaning up..."
      for pod in ${failed_pods}; do
        job_name="$("${KUBECTL[@]}" get pod "${pod}" -n "${ns}" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Job")].name}' 2>/dev/null || true)"
        if [ -n "${job_name}" ]; then
          "${KUBECTL[@]}" delete job "${job_name}" -n "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
        else
          "${KUBECTL[@]}" delete pod "${pod}" -n "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
        fi
      done
    fi
  fi
done

echo "Updating platform images..."
# Check namespace exists
if ! "${KUBECTL[@]}" get namespace platform >/dev/null 2>&1; then
  echo "ERROR: platform namespace not found"
  exit 1
fi
# Check deployments exist before updating
if ! "${KUBECTL[@]}" get deployment controller -n platform >/dev/null 2>&1; then
  echo "ERROR: controller deployment not found in platform namespace"
  exit 1
fi
if ! "${KUBECTL[@]}" get deployment panel -n platform >/dev/null 2>&1; then
  echo "ERROR: panel deployment not found in platform namespace"
  exit 1
fi

"${KUBECTL[@]}" -n platform set image deploy/controller controller="${CONTROLLER_IMAGE}"
"${KUBECTL[@]}" -n platform set image deploy/panel panel="${PANEL_IMAGE}"
"${KUBECTL[@]}" -n platform rollout status deploy/controller --timeout=180s
"${KUBECTL[@]}" -n platform rollout status deploy/panel --timeout=180s

echo "Updating backup-service image..."
# Check namespace exists
if ! "${KUBECTL[@]}" get namespace backup-system >/dev/null 2>&1; then
  echo "ERROR: backup-system namespace not found"
  exit 1
fi
# Check backup-service deployment exists
if ! "${KUBECTL[@]}" get deployment backup-service -n backup-system >/dev/null 2>&1; then
  echo "ERROR: backup-service deployment not found in backup-system namespace"
  exit 1
fi

"${KUBECTL[@]}" -n backup-system set image deploy/backup-service backup-service="${BACKUP_SERVICE_IMAGE}"
"${KUBECTL[@]}" -n backup-system rollout status deploy/backup-service --timeout=180s

echo "OK: platform + backup-service images updated."
