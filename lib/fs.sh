#!/usr/bin/env bash
# Filesystem utilities (temp dirs, atomic write, safe rm)
# Source this file: source "$(dirname "$0")/../lib/fs.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Initialize RENDER_DIR (for installer)
init_render_dir() {
  RENDER_DIR="${RENDER_DIR:-$(mktemp -d)}"
  if [[ ! -d "${RENDER_DIR}" ]]; then
    log_error "Failed to create temporary directory"
    return 1
  fi
  export RENDER_DIR
  return 0
}

# Cleanup render dir
cleanup_render_dir() {
  if [[ -n "${RENDER_DIR:-}" && -d "${RENDER_DIR}" ]]; then
    rm -rf "${RENDER_DIR}" || true
  fi
}

# Create temp directory
create_temp_dir() {
  local prefix="${1:-voxeil}"
  mktemp -d -t "${prefix}.XXXXXX"
}

# Atomic write (write to temp file, then move)
atomic_write() {
  local file="$1"
  local content="$2"
  local temp_file
  temp_file="$(mktemp)"
  echo "${content}" > "${temp_file}"
  mv "${temp_file}" "${file}"
}

# Safe remove (with dry-run support)
safe_rm() {
  local path="$1"
  local dry_run="${DRY_RUN:-false}"
  if [ "${dry_run}" = "true" ]; then
    echo "[DRY-RUN] rm -rf ${path}"
  else
    rm -rf "${path}" 2>/dev/null || true
  fi
}

# Safe remove file
safe_rm_file() {
  local file="$1"
  local dry_run="${DRY_RUN:-false}"
  if [ "${dry_run}" = "true" ]; then
    echo "[DRY-RUN] rm -f ${file}"
  else
    rm -f "${file}" 2>/dev/null || true
  fi
}
