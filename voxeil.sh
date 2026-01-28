#!/usr/bin/env bash
set -Eeuo pipefail

# Voxeil Panel - Single Entrypoint Script
# Supports: install, uninstall, purge-node, doctor, help, nuke

OWNER="${OWNER:-ARK322}"
REPO="${REPO:-voxeil-panel}"
REF="${REF:-main}"

# Colors for output
RED="\033[0;31m"
YELLOW="\033[1;33m"
GREEN="\033[0;32m"
NC="\033[0m"

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Ensure curl is available
ensure_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    log_error "curl is required but not installed."
    if command -v apt-get >/dev/null 2>&1; then
      log_info "Attempting to install curl..."
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y curl >/dev/null 2>&1 || {
        log_error "Failed to install curl. Please install manually: apt-get install -y curl"
        exit 1
      }
    else
      log_error "Please install curl manually."
      exit 1
    fi
  fi
}

# Download a script from GitHub
download_script() {
  local script_path="$1"
  local output_path="$2"
  local desc="${3:-${script_path}}"
  
  ensure_curl
  
  local url="https://raw.githubusercontent.com/${OWNER}/${REPO}/${REF}/${script_path}"
  
  log_info "Downloading ${desc}..."
  if ! curl -fL --retry 5 --retry-delay 1 --max-time 60 -o "${output_path}" "${url}"; then
    log_error "Failed to download ${desc} from ${url}"
    exit 1
  fi
  
  if [[ ! -s "${output_path}" ]]; then
    log_error "Downloaded ${desc} is empty"
    exit 1
  fi
  
  chmod +x "${output_path}"
  log_info "Downloaded ${desc} successfully"
}

# Show help
show_help() {
  cat <<EOF
Voxeil Panel - Installation and Management Script

Usage:
  voxeil.sh [--ref <branch|tag|commit>] <subcommand> [flags...]

Subcommands:
  install          Install Voxeil Panel (default if no subcommand)
  uninstall        Uninstall Voxeil Panel (safe, removes only Voxeil resources)
  purge-node       Complete node wipe (removes k3s, requires --force)
  nuke             Alias for purge-node (IRREVERSIBLE, requires --force)
  doctor           Check installation status (read-only)
  help             Show this help message

Global Flags:
  --ref <ref>      Use specific branch/tag/commit (default: main)

Install Flags:
  --doctor, --dry-run, --force, --skip-k3s, --install-k3s
  --kubeconfig <path>, --profile minimal|full
  --with-mail, --with-dns, --version <tag>, --channel stable|main

Uninstall Flags:
  --doctor, --dry-run, --force, --purge-node, --keep-volumes
  --kubeconfig <path>

Examples:
  # Install (default)
  curl -fL -o /tmp/voxeil.sh https://raw.githubusercontent.com/ARK322/voxeil-panel/main/voxeil.sh
  bash /tmp/voxeil.sh install

  # Install with version pinning
  bash /tmp/voxeil.sh --ref v1.0.0 install

  # Check status
  bash /tmp/voxeil.sh doctor

  # Safe uninstall
  bash /tmp/voxeil.sh uninstall --force

  # Purge node (full reset)
  bash /tmp/voxeil.sh purge-node --force

  # Nuke (alias for purge-node)
  bash /tmp/voxeil.sh nuke --force

Note: Downloading to a file is recommended over curl|bash due to occasional pipe glitches.

EOF
}

# Parse global flags
GLOBAL_ARGS=()
SUBCMD=""
SUBCMD_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --ref)
      REF="$2"
      shift 2
      ;;
    install|uninstall|purge-node|doctor|help|nuke)
      if [[ -z "${SUBCMD}" ]]; then
        SUBCMD="$1"
      else
        SUBCMD_ARGS+=("$1")
      fi
      shift
      ;;
    *)
      if [[ -z "${SUBCMD}" ]]; then
        # Before subcommand, treat as global flag
        GLOBAL_ARGS+=("$1")
      else
        # After subcommand, pass to subcommand
        SUBCMD_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

# Default to install if no subcommand
if [[ -z "${SUBCMD}" ]]; then
  SUBCMD="install"
fi

# Handle help
if [[ "${SUBCMD}" == "help" ]]; then
  show_help
  exit 0
fi

# Handle nuke (alias for purge-node)
if [[ "${SUBCMD}" == "nuke" ]]; then
  SUBCMD="purge-node"
  # Ensure --force is present
  HAS_FORCE=false
  for arg in "${SUBCMD_ARGS[@]}"; do
    if [[ "${arg}" == "--force" ]]; then
      HAS_FORCE=true
      break
    fi
  done
  if [[ "${HAS_FORCE}" != "true" ]]; then
    SUBCMD_ARGS+=("--force")
  fi
fi

# Handle doctor
if [[ "${SUBCMD}" == "doctor" ]]; then
  INSTALLER_TMP="$(mktemp)"
  cleanup() { rm -f "${INSTALLER_TMP}"; }
  trap cleanup EXIT
  
  # Download cmd/doctor.sh
  download_script "cmd/doctor.sh" "${INSTALLER_TMP}" "doctor"
  exec bash "${INSTALLER_TMP}" "${SUBCMD_ARGS[@]}"
fi

# Handle purge-node (security guard)
if [[ "${SUBCMD}" == "purge-node" ]]; then
  HAS_FORCE=false
  for arg in "${SUBCMD_ARGS[@]}"; do
    if [[ "${arg}" == "--force" ]]; then
      HAS_FORCE=true
      break
    fi
  done
  
  if [[ "${HAS_FORCE}" != "true" ]]; then
    log_error "purge-node requires --force flag for safety"
    log_error "Usage: voxeil.sh purge-node --force [other flags...]"
    exit 1
  fi
  
  # Remove --keep-volumes from args if present (not relevant for purge-node)
  FILTERED_ARGS=()
  for arg in "${SUBCMD_ARGS[@]}"; do
    if [[ "${arg}" == "--keep-volumes" ]]; then
      log_warn "Ignoring --keep-volumes for purge-node (volumes will be removed)"
      continue
    fi
    FILTERED_ARGS+=("${arg}")
  done
  
  UNINSTALLER_TMP="$(mktemp)"
  cleanup() { rm -f "${UNINSTALLER_TMP}"; }
  trap cleanup EXIT
  
  # Download cmd/purge-node.sh
  download_script "cmd/purge-node.sh" "${UNINSTALLER_TMP}" "purge-node"
  exec bash "${UNINSTALLER_TMP}" "${FILTERED_ARGS[@]}"
fi

# Handle install
if [[ "${SUBCMD}" == "install" ]]; then
  INSTALLER_TMP="$(mktemp)"
  cleanup() { rm -f "${INSTALLER_TMP}"; }
  trap cleanup EXIT
  
  # Download cmd/install.sh (or installer.sh wrapper for backward compatibility)
  download_script "cmd/install.sh" "${INSTALLER_TMP}" "install"
  
  # Pass --version if --ref was used (installer uses --version)
  INSTALLER_ARGS=()
  if [[ "${REF}" != "main" ]]; then
    INSTALLER_ARGS+=("--version" "${REF}")
  fi
  INSTALLER_ARGS+=("${SUBCMD_ARGS[@]}")
  
  exec bash "${INSTALLER_TMP}" "${INSTALLER_ARGS[@]}"
fi

# Handle uninstall
if [[ "${SUBCMD}" == "uninstall" ]]; then
  UNINSTALLER_TMP="$(mktemp)"
  cleanup() { rm -f "${UNINSTALLER_TMP}"; }
  trap cleanup EXIT
  
  # Download cmd/uninstall.sh (or uninstaller.sh wrapper for backward compatibility)
  download_script "cmd/uninstall.sh" "${UNINSTALLER_TMP}" "uninstall"
  exec bash "${UNINSTALLER_TMP}" "${SUBCMD_ARGS[@]}"
fi

# Unknown subcommand
log_error "Unknown subcommand: ${SUBCMD}"
echo ""
show_help
exit 1
