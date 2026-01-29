#!/usr/bin/env bash
# Common utilities for Voxeil scripts
# Source this file in phase scripts: source "$(dirname "$0")/../lib/common.sh"

set -Eeuo pipefail

# Colors for output
RED="\033[0;31m"
YELLOW="\033[1;33m"
GREEN="\033[0;32m"
NC="\033[0m"

# Error tracking
LAST_COMMAND=""
LAST_LINE=""

# Logging functions
log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_ok() {
  echo -e "${GREEN}[OK]${NC} $1"
}

# Phase logging (for phase scripts)
log_phase() {
  local phase_name="$1"
  echo ""
  echo -e "${GREEN}[PHASE]${NC} ${phase_name}"
}

# Error handling
die() {
  local exit_code="${1:-1}"
  local message="${2:-}"
  if [ -n "${message}" ]; then
    log_error "${message}"
  fi
  if [ -n "${LAST_LINE}" ] && [ -n "${LAST_COMMAND}" ]; then
    log_error "Failed at line ${LAST_LINE}: ${LAST_COMMAND}"
  fi
  exit "${exit_code}"
}

# Trap setup (call this in phase scripts)
setup_error_trap() {
  trap 'LAST_COMMAND="${BASH_COMMAND}"; LAST_LINE="${LINENO}"' DEBUG
  trap 'if [ $? -ne 0 ]; then
    log_error "Command failed at line ${LAST_LINE}: ${LAST_COMMAND}"
    exit 1
  fi' ERR
}

# Require root
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
  fi
}

# Check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Retry helper (for idempotent operations)
retry() {
  local max_attempts="${1:-3}"
  local delay="${2:-1}"
  shift 2
  local cmd="$*"
  local attempt=1
  
  while [ ${attempt} -le ${max_attempts} ]; do
    if eval "${cmd}"; then
      return 0
    fi
    if [ ${attempt} -lt ${max_attempts} ]; then
      log_warn "Attempt ${attempt}/${max_attempts} failed, retrying in ${delay}s..."
      sleep "${delay}"
      delay=$((delay * 2))  # Exponential backoff
    fi
    attempt=$((attempt + 1))
  done
  
  log_error "Command failed after ${max_attempts} attempts: ${cmd}"
  return 1
}

# Safe source helper (source a file if it exists)
safe_source() {
  local file="$1"
  if [ -f "${file}" ]; then
    # shellcheck disable=SC1090
    source "${file}"
  else
    log_warn "File not found: ${file}"
    return 1
  fi
}

# Wait timeout (configurable, default 600s)
VOXEIL_WAIT_TIMEOUT="${VOXEIL_WAIT_TIMEOUT:-600}"

# State registry helpers
STATE_FILE="/var/lib/voxeil/install.state"
STATE_ENV_FILE="/var/lib/voxeil/state.env"

ensure_state_dir() {
  mkdir -p "$(dirname "${STATE_FILE}")"
}

init_state_registry() {
  ensure_state_dir
  touch "${STATE_FILE}"
  chmod 644 "${STATE_FILE}"
}

state_set() {
  local key="$1"
  local value="$2"
  init_state_registry
  if ! grep -q "^${key}=" "${STATE_FILE}" 2>/dev/null; then
    echo "${key}=${value}" >> "${STATE_FILE}"
  else
    if command_exists sed; then
      sed -i "s/^${key}=.*/${key}=${value}/" "${STATE_FILE}"
    else
      local temp_file
      temp_file="$(mktemp)"
      grep -v "^${key}=" "${STATE_FILE}" > "${temp_file}" 2>/dev/null || true
      echo "${key}=${value}" >> "${temp_file}"
      mv "${temp_file}" "${STATE_FILE}"
    fi
  fi
}

state_get() {
  local key="$1"
  local default="${2:-0}"
  if [ -f "${STATE_FILE}" ]; then
    grep "^${key}=" "${STATE_FILE}" 2>/dev/null | cut -d'=' -f2- || echo "${default}"
  else
    echo "${default}"
  fi
}

state_load() {
  if [ -f "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    set +u
    source "${STATE_FILE}" 2>/dev/null || true
    set -u
  fi
}

write_state_flag() {
  state_set "$1" "1"
}

read_state_flag() {
  state_get "$1" "0"
}

is_installed() {
  local flag="$1"
  [ "$(read_state_flag "${flag}")" = "1" ]
}

# Label namespace helper
label_namespace() {
  local namespace="$1"
  local dry_run="${DRY_RUN:-false}"
  if [ "${dry_run}" = "true" ]; then
    echo "[DRY-RUN] kubectl label namespace \"${namespace}\" app.kubernetes.io/part-of=voxeil --overwrite"
  else
    kubectl label namespace "${namespace}" app.kubernetes.io/part-of=voxeil --overwrite >/dev/null 2>&1 || true
  fi
}

# Utility helpers
need_cmd() {
  command_exists "$1" || { log_error "Missing required command: $1"; exit 1; }
}

rand() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 || true
}

# Dry run wrapper
run() {
  local cmd="$1"
  local dry_run="${DRY_RUN:-false}"
  if [ "${dry_run}" = "true" ]; then
    echo "[DRY-RUN] ${cmd}"
  else
    eval "${cmd}"
  fi
}
