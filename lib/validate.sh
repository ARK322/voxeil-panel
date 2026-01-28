#!/usr/bin/env bash
# Validation utilities (safety checks, --force guard, env sanity)
# Source this file: source "$(dirname "$0")/../lib/validate.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Check --force flag guard
check_force_flag() {
  local operation="$1"
  local force="${FORCE:-false}"
  if [ "${force}" != "true" ]; then
    log_error "${operation} requires --force flag for safety"
    return 1
  fi
  return 0
}

# Validate email format (simple: must contain @ and . after @)
validate_email() {
  local email="$1"
  if [[ ! "${email}" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    log_error "Invalid email format: ${email}"
    return 1
  fi
  return 0
}

# Validate password is not empty
validate_password() {
  local password="$1"
  if [ -z "${password}" ]; then
    log_error "Password cannot be empty"
    return 1
  fi
  return 0
}

# Validate environment sanity
validate_env() {
  local errors=0
  
  # Check required commands
  if ! command_exists curl; then
    log_warn "curl not found (will attempt to install)"
  fi
  
  # Check if running as root (for install/uninstall)
  if [ "$(id -u)" -ne 0 ]; then
    log_warn "Not running as root (some operations may fail)"
  fi
  
  return 0
}

# Preflight checks (before install/uninstall)
preflight_checks() {
  local operation="$1"
  log_info "Running preflight checks for ${operation}..."
  
  # Validate environment
  validate_env || return 1
  
  # Check kubectl availability (if not installing k3s)
  if [ "${operation}" != "install" ] || [ "${SKIP_K3S:-false}" = "true" ]; then
    source "${SCRIPT_DIR}/kube.sh" 2>/dev/null || true
    if ! ensure_kubectl; then
      log_error "kubectl not found and k3s not available"
      return 1
    fi
  fi
  
  log_ok "Preflight checks passed"
  return 0
}
