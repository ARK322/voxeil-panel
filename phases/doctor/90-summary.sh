#!/usr/bin/env bash
# Doctor phase: Summary
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../lib/common.sh"

log_phase "doctor/90-summary"

EXIT_CODE="${EXIT_CODE:-0}"

echo ""
echo "=== Doctor Check Summary ==="
if [ "${EXIT_CODE}" -eq 0 ]; then
  log_ok "System is healthy - all checks passed"
  echo ""
  echo "Cluster is ready for production use."
elif [ "${EXIT_CODE}" -eq 2 ]; then
  log_error "Unable to check system (kubectl/cluster not accessible)"
  echo ""
  echo "Please ensure k3s is installed and kubectl can access the cluster."
else
  log_error "System has issues - some checks failed"
  echo ""
  echo "Recommended next steps:"
  echo "  - Review error messages above"
  echo "  - For stuck namespaces: bash voxeil.sh uninstall --force"
  echo "  - For deployment issues: Check pod logs and events"
fi

exit "${EXIT_CODE}"
