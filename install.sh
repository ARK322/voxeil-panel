#!/usr/bin/env bash
set -euo pipefail

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}

need_cmd curl
need_cmd tar
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

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

ARCHIVE_URL="https://github.com/${OWNER}/${REPO}/archive/${REF}.tar.gz"
ARCHIVE_PATH="${TMP_DIR}/repo.tar.gz"

echo "Downloading ${OWNER}/${REPO}@${REF}..."
if ! curl -fsSL "${ARCHIVE_URL}" -o "${ARCHIVE_PATH}"; then
  echo "ERROR: Failed to download archive from ${ARCHIVE_URL}"
  exit 1
fi

if ! tar -xzf "${ARCHIVE_PATH}" -C "${TMP_DIR}"; then
  echo "ERROR: Failed to extract archive"
  exit 1
fi

EXTRACTED_DIR="${TMP_DIR}/${REPO}-${REF}"
if [[ ! -d "${EXTRACTED_DIR}" ]]; then
  # fallback if GitHub names the folder differently
  EXTRACTED_DIR="$(find "${TMP_DIR}" -maxdepth 1 -type d -name "${REPO}-*" | head -n 1 || true)"
fi

if [[ -z "${EXTRACTED_DIR}" || ! -d "${EXTRACTED_DIR}" ]]; then
  echo "Failed to locate extracted repo directory."
  exit 1
fi

if ! cd "${EXTRACTED_DIR}"; then
  echo "ERROR: Failed to change directory to ${EXTRACTED_DIR}"
  exit 1
fi

if [[ ! -f installer/installer.sh ]]; then
  echo "ERROR: installer/installer.sh not found in extracted archive."
  exit 1
fi

if ! chmod +x installer/installer.sh; then
  echo "ERROR: Failed to make installer/installer.sh executable"
  exit 1
fi

echo "Starting installer..."
exec ${SUDO} bash installer/installer.sh "$@"
