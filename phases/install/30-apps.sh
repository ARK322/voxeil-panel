#!/usr/bin/env bash
# Install phase: Applications (infra-db, backup-system, dns-zone, mail-zone)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "install/30-apps"

# This phase will contain the application installation logic from installer.sh
# For now, it's a placeholder that will be populated with actual installer.sh code
# The installer.sh code for infra-db, backup-system, dns-zone, and mail-zone
# will be moved here in subsequent refactoring steps.

log_info "Applications installation phase"
log_warn "This phase is a placeholder - actual implementation will be migrated from installer.sh"

log_ok "Applications phase complete"
