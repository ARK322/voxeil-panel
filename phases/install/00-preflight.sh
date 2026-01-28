#!/usr/bin/env bash
# Install phase: Preflight checks
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/validate.sh"

log_phase "install/00-preflight"

# Run preflight checks
preflight_checks "install" || die 1 "Preflight checks failed"

# Initialize render dir (for installer)
if [ -n "${RENDER_DIR:-}" ]; then
  source "${SCRIPT_DIR}/../../lib/fs.sh"
  init_render_dir || die 1 "Failed to initialize render directory"
fi

log_ok "Preflight checks passed"
