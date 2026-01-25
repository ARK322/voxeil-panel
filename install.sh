#!/usr/bin/env bash
set -euo pipefail

# Voxeil Panel Installer - Backward Compatibility Wrapper
# This script is deprecated. Use voxeil.sh instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOXEIL_SCRIPT="${SCRIPT_DIR}/voxeil.sh"

# Check if voxeil.sh exists locally (for development)
if [[ -f "${VOXEIL_SCRIPT}" ]]; then
  echo "Note: install.sh is deprecated. Use 'voxeil.sh' instead."
  echo ""
  exec bash "${VOXEIL_SCRIPT}" install "$@"
fi

# If voxeil.sh doesn't exist locally, download and run it
# This handles the case where someone downloads install.sh directly
echo "Note: install.sh is deprecated. Use 'voxeil.sh' instead."
echo ""

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}

need_cmd curl
need_cmd mktemp

OWNER="${OWNER:-ARK322}"
REPO="${REPO:-voxeil-panel}"
REF="${REF:-main}"

# Parse --ref if present (before downloading voxeil.sh)
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      REF="$2"
      shift 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

VOXEIL_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/${REF}/voxeil.sh"
VOXEIL_PATH="$(mktemp)"

cleanup() { rm -f "${VOXEIL_PATH}"; }
trap cleanup EXIT

echo "Downloading voxeil.sh..."
if ! curl -fL --retry 5 --retry-delay 1 --max-time 60 -o "${VOXEIL_PATH}" "${VOXEIL_URL}"; then
  echo "ERROR: Failed to download voxeil.sh from ${VOXEIL_URL}"
  exit 1
fi

if [[ ! -s "${VOXEIL_PATH}" ]]; then
  echo "ERROR: Downloaded voxeil.sh is empty"
  exit 1
fi

chmod +x "${VOXEIL_PATH}"

# Support backward compatibility: install.sh uninstall, install.sh purge-node, etc.
# Default to install if no subcommand
SUBCMD="install"
VOXEIL_ARGS=()
if [[ ${#ARGS[@]} -gt 0 ]]; then
  case "${ARGS[0]}" in
    install|uninstall|purge-node|doctor|help)
      SUBCMD="${ARGS[0]}"
      VOXEIL_ARGS=("${ARGS[@]:1}")
      ;;
    *)
      # No subcommand, treat all as install args
      VOXEIL_ARGS=("${ARGS[@]}")
      ;;
  esac
fi

# Pass --ref to voxeil.sh if it was specified
if [[ "${REF}" != "main" ]]; then
  exec bash "${VOXEIL_PATH}" --ref "${REF}" "${SUBCMD}" "${VOXEIL_ARGS[@]}"
else
  exec bash "${VOXEIL_PATH}" "${SUBCMD}" "${VOXEIL_ARGS[@]}"
fi
