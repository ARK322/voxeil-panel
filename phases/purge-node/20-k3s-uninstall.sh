#!/usr/bin/env bash
# Purge-node phase: k3s uninstall
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../lib/k3s.sh"

log_phase "purge-node/20-k3s-uninstall"

# Uninstall k3s
uninstall_k3s || die 1 "k3s uninstall failed"

log_ok "k3s uninstall phase complete"
