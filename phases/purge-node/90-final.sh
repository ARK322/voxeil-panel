#!/usr/bin/env bash
# Purge-node phase: Final steps
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

log_phase "purge-node/90-final"

log_ok "Node purge complete - k3s and all Voxeil files removed"
log_warn "IMPORTANT: A system reboot is recommended to ensure all changes take effect"
log_warn "  Run: sudo reboot"

log_ok "Final phase complete"
