#!/usr/bin/env bash
# Uninstall phase: Remove infrastructure
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "uninstall/30-remove-infra"

# This phase will contain infrastructure removal logic from uninstaller.sh
# For now, it's a placeholder that will be populated with actual uninstaller.sh code

log_info "Removing infrastructure phase"
log_warn "This phase is a placeholder - actual implementation will be migrated from uninstaller.sh"

log_ok "Infrastructure removal phase complete"
