#!/usr/bin/env bash
# Install phase: k3s installation
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/k3s.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

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

# Check kubectl context
check_kubectl_context || die 1 "kubectl context check failed"

log_ok "k3s installation phase complete"
