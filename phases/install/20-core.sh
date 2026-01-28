#!/usr/bin/env bash
# Install phase: Core infrastructure (cert-manager, kyverno, flux, traefik, platform)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "install/20-core"

# This phase will contain the core installation logic from installer.sh
# For now, it's a placeholder that will be populated with actual installer.sh code
# The installer.sh code for cert-manager, kyverno, flux, traefik, and platform
# will be moved here in subsequent refactoring steps.

log_info "Core infrastructure installation phase"
log_warn "This phase is a placeholder - actual implementation will be migrated from installer.sh"

log_ok "Core infrastructure phase complete"
