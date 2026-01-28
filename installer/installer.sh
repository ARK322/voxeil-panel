#!/usr/bin/env bash
# Installer wrapper - calls cmd/install.sh
# This wrapper maintains backward compatibility for direct installer.sh usage
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD_INSTALL="${SCRIPT_DIR}/../cmd/install.sh"

# Simple error logging for wrapper
log_error() {
  echo "=== [ERROR] $1 ===" >&2
}

# If cmd/install.sh exists, use it; otherwise fall back to legacy behavior
if [ -f "${CMD_INSTALL}" ]; then
  # Pass all arguments to cmd/install.sh
  exec bash "${CMD_INSTALL}" "$@"
else
  # Legacy fallback: if cmd/install.sh doesn't exist, this script should contain
  # the full installer logic (for backward compatibility during migration)
  log_error "cmd/install.sh not found. This is a wrapper script."
  log_error "Please ensure cmd/install.sh exists or use the full installer.sh"
  exit 1
fi
