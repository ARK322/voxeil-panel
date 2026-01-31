#!/usr/bin/env bash
# Doctor phase: Cluster checks
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/kube.sh
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "doctor/10-cluster"

EXIT_CODE=0

# Check kubectl availability
if ! ensure_kubectl; then
  log_error "kubectl not available"
  EXIT_CODE=2
  exit ${EXIT_CODE}
fi

# Check API reachability
log_info "Checking k3s API reachability..."
if ! run_kubectl cluster-info >/dev/null 2>&1; then
  log_error "Cannot reach k3s API"
  EXIT_CODE=2
  exit ${EXIT_CODE}
fi

log_ok "k3s API is reachable"

# Check nodes
log_info "Checking cluster nodes..."
if run_kubectl get nodes >/dev/null 2>&1; then
  node_count=$(run_kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
  ready_count=$(run_kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
  
  if [ "${node_count}" -gt 0 ] && [ "${ready_count}" -eq "${node_count}" ]; then
    log_ok "All ${node_count} node(s) are Ready"
  else
    log_error "Nodes not ready: ${ready_count}/${node_count}"
    EXIT_CODE=1
  fi
else
  log_error "Cannot get nodes"
  EXIT_CODE=1
fi

exit ${EXIT_CODE}
