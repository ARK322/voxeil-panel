#!/usr/bin/env bash
# Doctor phase: Environment checks
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "doctor/00-env"

EXIT_CODE=0

# Check state file
echo "=== State Registry ==="
if [ -f "${STATE_FILE}" ]; then
  echo "State file found at ${STATE_FILE}:"
  cat "${STATE_FILE}" | sed 's/^/  /'
  echo ""
else
  echo "  ⚠ No state file found"
  EXIT_CODE=1
  echo ""
fi

# Check kubectl availability
if ! ensure_kubectl || ! check_kubectl_context >/dev/null 2>&1; then
  echo "⚠ kubectl not available or cluster not accessible"
  echo "  Skipping Kubernetes resource checks"
  echo ""
  exit ${EXIT_CODE}
fi

log_ok "Environment checks complete"
