#!/usr/bin/env bash
# Install phase: k3s installation
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=../../lib/k3s.sh
source "${REPO_ROOT}/lib/k3s.sh"
# shellcheck source=../../lib/kube.sh
source "${REPO_ROOT}/lib/kube.sh"

log_phase "install/10-k3s"

SKIP_K3S="${SKIP_K3S:-false}"
INSTALL_K3S="${INSTALL_K3S:-false}"

# Handle k3s installation based on flags
if [ "${SKIP_K3S}" = "true" ]; then
  if ! ensure_kubectl; then
    die 1 "kubectl not found and --skip-k3s specified. Cannot proceed."
  fi
  if ! check_kubectl_context >/dev/null 2>&1; then
    die 1 "kubectl cannot reach cluster and --skip-k3s specified. Cannot proceed."
  fi
  log_info "Skipping k3s installation (--skip-k3s)"
  # Verify nodes exist when skipping k3s installation
  if ! run_kubectl get nodes --no-headers 2>/dev/null | grep -q .; then
    die 1 "No nodes found in cluster. k3s may not be running or kubeconfig is incorrect."
  fi
elif [ "${INSTALL_K3S}" = "true" ] || ! command_exists kubectl; then
  if ! is_k3s_installed; then
    install_k3s || die 1 "k3s installation failed"
  else
    log_info "k3s already present (kubectl found), not reinstalling"
    if ! is_installed "K3S_INSTALLED"; then
      write_state_flag "K3S_INSTALLED"
    fi
  fi
else
  log_info "kubectl found, using existing cluster"
  if ! check_kubectl_context >/dev/null 2>&1; then
    die 1 "kubectl found but cluster is not reachable"
  fi
  if ! is_installed "K3S_INSTALLED"; then
    write_state_flag "K3S_INSTALLED"
  fi
fi

# Verify kubectl is available
ensure_kubectl || die 1 "kubectl not available"

# Set KUBECONFIG if provided
if [ -n "${KUBECONFIG:-}" ]; then
  export KUBECONFIG
  log_info "Using kubeconfig: ${KUBECONFIG}"
fi

# Wait for k3s API
wait_for_k3s_api || die 1 "k3s API not ready"

# Wait for nodes to exist and be Ready (REQUIRED - fail if nodes don't appear)
log_info "Waiting for nodes to exist..."
node_wait_attempts=0
node_wait_max=90
nodes_exist=false
while [ ${node_wait_attempts} -lt ${node_wait_max} ]; do
  if run_kubectl get nodes --no-headers 2>/dev/null | grep -q .; then
    log_ok "Nodes exist"
    nodes_exist=true
    break
  fi
  node_wait_attempts=$((node_wait_attempts + 1))
  if [ $((node_wait_attempts % 10)) -eq 0 ]; then
    log_info "Still waiting for nodes to exist... (${node_wait_attempts}/${node_wait_max})"
  fi
  sleep 2
done

if [ "${nodes_exist}" != "true" ]; then
  log_error "Nodes did not appear after $((node_wait_max * 2)) seconds"
  run_kubectl get nodes || true
  die 1 "Cluster has no nodes. k3s may not be running properly or kubeconfig is incorrect."
fi

# Wait for all nodes to be Ready (REQUIRED)
log_info "Waiting for all nodes to be Ready..."
if ! run_kubectl wait node --all --for=condition=Ready --timeout=180s >/dev/null 2>&1; then
  log_error "Nodes did not become Ready within 180s"
  run_kubectl get nodes -o wide || true
  die 1 "Nodes are not Ready. Cluster is not functional."
fi
log_ok "All nodes are Ready"

# Check kubectl context
check_kubectl_context || die 1 "kubectl context check failed"

log_ok "k3s installation phase complete"
