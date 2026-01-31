#!/usr/bin/env bash
# Doctor phase: Leftover resource checks
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/kube.sh
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "doctor/30-leftovers"

EXIT_CODE=0

# List of voxeil-owned namespaces
VOXEIL_NAMESPACES=(
  "platform"
  "cert-manager"
  "kyverno"
  "infra-db"
  "dns-zone"
  "mail-zone"
  "flux-system"
)

log_info "Checking for stuck namespaces..."

STUCK_NAMESPACES=()
for ns in "${VOXEIL_NAMESPACES[@]}"; do
  if run_kubectl get namespace "${ns}" >/dev/null 2>&1; then
    phase=$(run_kubectl get namespace "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    owned=$(run_kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.voxeil\.io/owned}' 2>/dev/null || echo "")
    
    if [ "${phase}" = "Terminating" ]; then
      if [ "${owned}" = "true" ]; then
        STUCK_NAMESPACES+=("${ns}")
        log_error "Found stuck voxeil-owned namespace in Terminating state: ${ns}"
        EXIT_CODE=1
      else
        log_warn "Found namespace in Terminating state (not owned by voxeil): ${ns}"
      fi
    elif [ "${phase}" = "Active" ] && [ "${owned}" = "true" ]; then
      log_info "Found active voxeil-owned namespace: ${ns} (expected if installed)"
    fi
  fi
done

# Check for any other namespaces with voxeil.io/owned=true that are stuck
ALL_VOXEIL_NS=""
ALL_VOXEIL_NS=$(run_kubectl get namespaces -l voxeil.io/owned=true --no-headers -o custom-columns=:metadata.name 2>/dev/null || echo "")

if [ -n "${ALL_VOXEIL_NS}" ]; then
  while IFS= read -r ns; do
    if [ -n "${ns}" ]; then
      phase=$(run_kubectl get namespace "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      
      if [ "${phase}" = "Terminating" ]; then
        # Check if already in our list
        found=false
        for existing_ns in "${STUCK_NAMESPACES[@]}"; do
          if [ "${existing_ns}" = "${ns}" ]; then
            found=true
            break
          fi
        done
        if [ "${found}" = "false" ]; then
          STUCK_NAMESPACES+=("${ns}")
          log_error "Found additional stuck voxeil-owned namespace: ${ns}"
          EXIT_CODE=1
        fi
      fi
    fi
  done <<< "${ALL_VOXEIL_NS}"
fi

if [ ${#STUCK_NAMESPACES[@]} -gt 0 ]; then
  log_error "Found ${#STUCK_NAMESPACES[@]} stuck namespace(s): ${STUCK_NAMESPACES[*]}"
  log_warn "Recommendation: Run 'voxeil.sh uninstall --force' to clean up"
else
  log_ok "No stuck namespaces found"
fi

exit ${EXIT_CODE}
