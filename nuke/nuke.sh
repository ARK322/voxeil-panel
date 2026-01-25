#!/usr/bin/env bash
set -euo pipefail

# Nuke script - calls uninstaller with --purge-node --force
# This is a convenience wrapper for complete node wipe
# Does NOT require repo clone - downloads uninstaller from GitHub if needed

OWNER="${OWNER:-ARK322}"
REPO="${REPO:-voxeil-panel}"
REF="${REF:-main}"

# Try to find uninstaller locally first (if running from repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALLER="${SCRIPT_DIR}/../uninstaller/uninstaller.sh"

# If local uninstaller doesn't exist, download it
if [ ! -f "${UNINSTALLER}" ]; then
  UNINSTALLER_TMP="$(mktemp)"
  cleanup() { rm -f "${UNINSTALLER_TMP}"; }
  trap cleanup EXIT
  
  if ! command -v curl >/dev/null 2>&1; then
    echo "=== [ERROR] curl is required but not installed ===" >&2
    exit 1
  fi
  
  echo "=== [INFO] Downloading uninstaller from GitHub ==="
  if ! curl -fL --retry 5 --retry-delay 1 --max-time 60 -o "${UNINSTALLER_TMP}" "https://raw.githubusercontent.com/${OWNER}/${REPO}/${REF}/uninstaller/uninstaller.sh"; then
    echo "=== [ERROR] Failed to download uninstaller ===" >&2
    exit 1
  fi
  
  chmod +x "${UNINSTALLER_TMP}"
  UNINSTALLER="${UNINSTALLER_TMP}"
fi

# ===== VOXEIL logo =====
ORANGE="\033[38;5;208m"
GRAY="\033[38;5;252m"
RED="\033[38;5;196m"
NC="\033[0m"

INNER=72
strip_ansi() { echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g'; }

box_line_center() {
  local line="$1"
  local plain len pad_left pad_right
  plain="$(strip_ansi "$line")"
  len=${#plain}
  if (( len > INNER )); then
    plain="${plain:0:INNER}"
    line="$plain"
    len=$INNER
  fi
  pad_left=$(( (INNER - len) / 2 ))
  pad_right=$(( INNER - len - pad_left ))
  printf "║%*s%b%*s║\n" "$pad_left" "" "$line" "$pad_right" ""
}

echo
echo "╔════════════════════════════════════════════════════════════════════════╗"
printf "║%*s║\n" "$INNER" ""
printf "║%*s║\n" "$INNER" ""

box_line_center "${ORANGE}██╗   ██╗${GRAY}  ██████╗   ██╗  ██╗  ███████╗  ██╗  ██╗${NC}"
box_line_center "${ORANGE}██║   ██║${GRAY} ██╔═══██╗  ╚██╗██╔╝  ██╔════╝  ██║  ██║${NC}"
box_line_center "${ORANGE}██║   ██║${GRAY} ██║   ██║   ╚███╔╝   █████╗    ██║  ██║${NC}"
box_line_center "${ORANGE}╚██╗ ██╔╝${GRAY} ██║   ██║   ██╔██╗   ██╔══╝    ██║  ██║${NC}"
box_line_center "${ORANGE} ╚████╔╝ ${GRAY} ╚██████╔╝  ██╔╝ ██╗  ███████╗  ██║   ███████╗${NC}"
box_line_center "${ORANGE}  ╚═══╝  ${GRAY}  ╚═════╝   ╚═╝  ╚═╝  ╚══════╝  ╚═╝   ╚══════╝${NC}"

printf "║%*s║\n" "$INNER" ""
box_line_center "${RED}NUKE MODE${NC}"
box_line_center "${GRAY}Complete Node Wipe${NC}"
printf "║%*s║\n" "$INNER" ""
box_line_center "${RED}⚠ DESTRUCTIVE OPERATION ⚠${NC}"
printf "║%*s║\n" "$INNER" ""
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo
echo "== Voxeil Nuke Script =="
echo ""
echo "=== [WARN] This will: ==="
echo "  1. Remove all Voxeil resources from the cluster"
echo "  2. Remove k3s and rancher directories (--purge-node)"
echo "  3. Remove /var/lib/voxeil state registry"
echo ""
echo "=== [WARN] This is a destructive operation that will wipe the node. ==="
echo ""

exec bash "${UNINSTALLER}" --purge-node --force "$@"
