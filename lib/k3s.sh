#!/usr/bin/env bash
# k3s installation/uninstallation helpers
# Source this file: source "$(dirname "$0")/../lib/k3s.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Install k3s (calls official installer)
install_k3s() {
  log_info "Installing k3s..."
  if ! curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644; then
    log_error "k3s installation failed"
    return 1
  fi
  
  # Verify k3s binary exists
  if [[ ! -f /usr/local/bin/k3s ]]; then
    log_error "k3s installation failed: /usr/local/bin/k3s not found after install"
    return 1
  fi
  
  # Verify kubectl is available
  if ! command_exists kubectl && ! /usr/local/bin/k3s kubectl version --client >/dev/null 2>&1; then
    log_error "k3s installation failed: kubectl not available after install"
    return 1
  fi
  
  # Verify cluster API is reachable
  log_info "Verifying k3s cluster API is reachable..."
  if ! /usr/local/bin/k3s kubectl get --raw=/healthz >/dev/null 2>&1; then
    log_error "k3s installation failed: cluster API not reachable after install"
    return 1
  fi
  
  log_ok "k3s installed and cluster API is reachable"
  write_state_flag "K3S_INSTALLED"
  return 0
}

# Uninstall k3s (calls official uninstaller)
uninstall_k3s() {
  log_info "Uninstalling k3s..."
  
  # Stop and disable k3s service
  if command_exists systemctl; then
    log_info "Stopping k3s service..."
    systemctl stop k3s 2>/dev/null || true
    systemctl disable k3s 2>/dev/null || true
  fi
  
  # Run k3s uninstall script if available
  if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    log_info "Running k3s-uninstall.sh..."
    /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 || {
      log_warn "k3s-uninstall.sh failed, continuing with filesystem cleanup..."
    }
  fi
  
  # Run k3s-killall.sh if available
  if [ -f /usr/local/bin/k3s-killall.sh ]; then
    log_info "Running k3s-killall.sh..."
    /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || {
      log_warn "k3s-killall.sh failed, continuing with filesystem cleanup..."
    }
  fi
  
  # Remove k3s binaries and directories (fallback cleanup)
  log_info "Removing k3s binaries and directories..."
  rm -f /usr/local/bin/k3s /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr 2>/dev/null || true
  rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet /var/lib/cni /opt/cni /run/flannel /run/k3s /var/log/k3s 2>/dev/null || true
  rm -f /etc/systemd/system/k3s.service 2>/dev/null || true
  
  # Remove leftover network interfaces
  log_info "Removing leftover network interfaces..."
  if command_exists ip; then
    if ip link show cni0 >/dev/null 2>&1; then
      ip link delete cni0 2>/dev/null || true
    fi
    if ip link show flannel.1 >/dev/null 2>&1; then
      ip link delete flannel.1 2>/dev/null || true
    fi
  fi
  
  # Reset iptables/nft rules
  log_info "Resetting iptables/nft rules..."
  if command_exists iptables; then
    log_warn "Flushing iptables rules (this may affect firewall configuration)..."
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    iptables -t mangle -X 2>/dev/null || true
  fi
  if command_exists nft; then
    log_warn "Flushing nft ruleset (this may affect firewall configuration)..."
    nft flush ruleset 2>/dev/null || true
  fi
  
  if command_exists systemctl; then
    systemctl daemon-reload 2>/dev/null || true
  fi
  
  log_ok "k3s uninstalled"
  return 0
}

# Check if k3s is installed
is_k3s_installed() {
  [[ -f /usr/local/bin/k3s ]] || command_exists kubectl
}
