#!/usr/bin/env bash
# Uninstaller wrapper - calls cmd/uninstall.sh or cmd/purge-node.sh
# This wrapper maintains backward compatibility for direct uninstaller.sh usage
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD_UNINSTALL="${SCRIPT_DIR}/../cmd/uninstall.sh"
CMD_PURGE_NODE="${SCRIPT_DIR}/../cmd/purge-node.sh"

# Simple error logging for wrapper
log_error() {
  echo "=== [ERROR] $1 ===" >&2
}

# Check for --purge-node flag
PURGE_NODE=false
for arg in "$@"; do
  if [ "${arg}" = "--purge-node" ]; then
    PURGE_NODE=true
    break
  fi
done

# If --purge-node, use purge-node orchestrator
if [ "${PURGE_NODE}" = "true" ]; then
  if [ -f "${CMD_PURGE_NODE}" ]; then
    # Remove --purge-node from args and pass rest
    FILTERED_ARGS=()
    for arg in "$@"; do
      if [ "${arg}" != "--purge-node" ]; then
        FILTERED_ARGS+=("${arg}")
      fi
    done
    exec bash "${CMD_PURGE_NODE}" "${FILTERED_ARGS[@]}"
  else
    log_error "cmd/purge-node.sh not found. This is a wrapper script."
    exit 1
  fi
else
  # Normal uninstall
  if [ -f "${CMD_UNINSTALL}" ]; then
    exec bash "${CMD_UNINSTALL}" "$@"
  else
    log_error "cmd/uninstall.sh not found. This is a wrapper script."
    exit 1
  fi
fi
