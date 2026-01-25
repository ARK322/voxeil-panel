#!/usr/bin/env bash
set -euo pipefail

# Nuke script - calls uninstaller with --purge-node --force
# This is a convenience wrapper for complete node wipe

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALLER="${SCRIPT_DIR}/../uninstaller/uninstaller.sh"

if [ ! -f "${UNINSTALLER}" ]; then
  echo "ERROR: uninstaller.sh not found at ${UNINSTALLER}"
  exit 1
fi

echo "=== Voxeil Nuke Script ==="
echo ""
echo "This will:"
echo "  1. Remove all Voxeil resources from the cluster"
echo "  2. Remove k3s and rancher directories (--purge-node)"
echo "  3. Remove /var/lib/voxeil state registry"
echo ""
echo "WARNING: This is a destructive operation that will wipe the node."
echo ""

exec bash "${UNINSTALLER}" --purge-node --force "$@"
