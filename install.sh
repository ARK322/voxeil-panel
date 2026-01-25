#!/usr/bin/env bash
set -euo pipefail

# Voxeil Panel Installer Wrapper
# Downloads and executes the self-contained installer script

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}

need_cmd curl
need_cmd mktemp

# Use sudo only if not running as root
SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  need_cmd sudo
  SUDO="sudo"
fi

OWNER="${OWNER:-ARK322}"
REPO="${REPO:-voxeil-panel}"
REF="${REF:-main}"

INSTALLER_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/${REF}/installer/installer.sh"
INSTALLER_PATH="$(mktemp)"

cleanup() { rm -f "${INSTALLER_PATH}"; }
trap cleanup EXIT

echo "Downloading Voxeil installer..."
if ! curl -fL --retry 3 --retry-delay 1 --max-time 60 -o "${INSTALLER_PATH}" "${INSTALLER_URL}"; then
  echo "ERROR: Failed to download installer from ${INSTALLER_URL}"
  exit 1
fi

if [[ ! -s "${INSTALLER_PATH}" ]]; then
  echo "ERROR: Downloaded installer is empty"
  exit 1
fi

if ! chmod +x "${INSTALLER_PATH}"; then
  echo "ERROR: Failed to make installer executable"
  exit 1
fi

echo "Starting installer..."
exec ${SUDO} bash "${INSTALLER_PATH}" "$@"
