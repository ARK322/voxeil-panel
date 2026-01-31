#!/usr/bin/env bash
# Purge-node phase: Confirmation
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../lib/validate.sh"

log_phase "purge-node/00-confirm"

# Check --force flag
check_force_flag "purge-node" || die 1 "purge-node requires --force flag"

log_warn "This will remove k3s and rancher directories from the node."
log_warn "This is a destructive operation."

log_ok "Confirmation phase complete"
