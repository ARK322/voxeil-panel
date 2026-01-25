#!/usr/bin/env bash
set -Eeuo pipefail

# Deprecated wrapper for backward compatibility
# This script redirects to voxeil.sh
# 
# IMPORTANT: voxeil.sh is the single entrypoint for all Voxeil operations.
# This install.sh wrapper is kept for backward compatibility only.

echo "[WARN] install.sh is deprecated. Use voxeil.sh instead." >&2
echo "[WARN] See README.md for the recommended single-entrypoint approach." >&2
echo "[INFO] Redirecting to voxeil.sh install..." >&2
echo ""

# Download voxeil.sh if not present
VOXEIL_SCRIPT="/tmp/voxeil.sh"
OWNER="${OWNER:-ARK322}"
REPO="${REPO:-voxeil-panel}"
REF="${REF:-main}"

if [[ ! -f "${VOXEIL_SCRIPT}" ]]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] curl is required but not installed." >&2
    exit 1
  fi
  
  echo "[INFO] Downloading voxeil.sh..."
  if ! curl -fL --retry 5 --retry-delay 1 --max-time 60 -o "${VOXEIL_SCRIPT}" "https://raw.githubusercontent.com/${OWNER}/${REPO}/${REF}/voxeil.sh"; then
    echo "[ERROR] Failed to download voxeil.sh" >&2
    exit 1
  fi
  
  chmod +x "${VOXEIL_SCRIPT}"
fi

# Execute voxeil.sh install with all arguments
exec bash "${VOXEIL_SCRIPT}" install "$@"
