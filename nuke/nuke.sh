#!/usr/bin/env bash
# Nuke wrapper - calls cmd/purge-node.sh --force
# This wrapper maintains backward compatibility for direct nuke.sh usage
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD_PURGE_NODE="${SCRIPT_DIR}/../cmd/purge-node.sh"

# Show nuke banner
ORANGE="\033[38;5;208m"
GRAY="\033[38;5;252m"
RED="\033[38;5;196m"
NC="\033[0m"

echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║                                                                        ║"
echo "║                                                                        ║"
echo "║  ${ORANGE}██╗   ██╗${GRAY}  ██████╗   ██╗  ██╗  ███████╗  ██╗  ██╗${NC}                    ║"
echo "║  ${ORANGE}██║   ██║${GRAY} ██╔═══██╗  ╚██╗██╔╝  ██╔════╝  ██║  ██║${NC}                    ║"
echo "║  ${ORANGE}██║   ██║${GRAY} ██║   ██║   ╚███╔╝   █████╗    ██║  ██║${NC}                    ║"
echo "║  ${ORANGE}╚██╗ ██╔╝${GRAY} ██║   ██║   ██╔██╗   ██╔══╝    ██║  ██║${NC}                    ║"
echo "║  ${ORANGE} ╚████╔╝ ${GRAY} ╚██████╔╝  ██╔╝ ██╗  ███████╗  ██║   ███████╗${NC}            ║"
echo "║  ${ORANGE}  ╚═══╝  ${GRAY}  ╚═════╝   ╚═╝  ╚═╝  ╚══════╝  ╚═╝   ╚══════╝${NC}            ║"
echo "║                                                                        ║"
echo "║  ${RED}NUKE MODE${NC}                                                              ║"
echo "║  ${GRAY}Complete Node Wipe${NC}                                                    ║"
echo "║                                                                        ║"
echo "║  ${RED}⚠ DESTRUCTIVE OPERATION ⚠${NC}                                            ║"
echo "║                                                                        ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "== Voxeil Nuke Script =="
echo ""
echo "=== [WARN] This will: ==="
echo "  1. Remove all Voxeil resources from the cluster"
echo "  2. Remove k3s and rancher directories (--purge-node)"
echo "  3. Remove /var/lib/voxeil state registry"
echo ""
echo "=== [WARN] This is a destructive operation that will wipe the node. ==="
echo ""

# Simple error logging for wrapper
log_error() {
  echo "=== [ERROR] $1 ===" >&2
}

# Call purge-node with --force
if [ -f "${CMD_PURGE_NODE}" ]; then
  exec bash "${CMD_PURGE_NODE}" --force "$@"
else
  log_error "cmd/purge-node.sh not found. This is a wrapper script."
  exit 1
fi
