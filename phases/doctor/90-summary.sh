#!/usr/bin/env bash
# Doctor phase: Summary
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

log_phase "doctor/90-summary"

EXIT_CODE="${EXIT_CODE:-0}"

echo ""
echo "=== Summary ==="
if [ ${EXIT_CODE} -eq 0 ]; then
  echo "[OK] System is clean - no Voxeil resources found"
else
  echo "[WARN] System has leftover Voxeil resources"
  echo ""
  echo "Recommended next steps:"
  echo "  bash /tmp/voxeil.sh uninstall --force"
fi

exit ${EXIT_CODE}
