#!/usr/bin/env bash
# Uninstall phase: Remove infrastructure
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "uninstall/30-remove-infra"

# Ensure kubectl is available
ensure_kubectl || exit 1

# Remove infrastructure (after applications)
log_info "Removing infrastructure..."
if ! run_kubectl delete -k "${SCRIPT_DIR}/../../infra/k8s/clusters/prod" --ignore-not-found --request-timeout=120s; then
  log_warn "Some resources may not have been found (this is expected during uninstall)"
fi

# Wait for infrastructure resources to be deleted before namespace cleanup
log_info "Waiting for infrastructure resources to be deleted..."
TIMEOUT="${VOXEIL_WAIT_TIMEOUT:-600}"

# Wait for voxeil namespaces to have resources cleaned up
VOXEIL_NAMESPACES=("platform" "cert-manager" "kyverno" "infra-db" "dns-zone" "mail-zone" "flux-system")

for ns in "${VOXEIL_NAMESPACES[@]}"; do
  if ! run_kubectl get namespace "${ns}" >/dev/null 2>&1; then
    continue
  fi
  
  # Wait for deployments/statefulsets to be deleted
  waited=0
  has_resources=true
  while [ ${waited} -lt 60 ] && [ "${has_resources}" = "true" ]; do
    deploy_count=$(run_kubectl get deployments,statefulsets -n "${ns}" --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "${deploy_count}" -eq "0" ]; then
      has_resources=false
    else
      sleep 2
      waited=$((waited + 2))
    fi
  done
  
  if [ "${has_resources}" = "true" ]; then
    log_warn "Namespace ${ns} still has resources (will be cleaned up in namespace phase)"
  fi
done

log_ok "Infrastructure removal phase complete"
