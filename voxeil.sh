#!/usr/bin/env bash
set -Eeuo pipefail

# Voxeil Panel - Single Entrypoint Script
# Supports: install, uninstall, purge-node, doctor, help, nuke
# Downloads repo archive and runs cmd/*.sh orchestrators

OWNER="${OWNER:-ARK322}"
REPO="${REPO:-voxeil-panel}"
REF="${REF:-main}"

# Colors for output
RED="\033[0;31m"
YELLOW="\033[1;33m"
GREEN="\033[0;32m"
NC="\033[0m"

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Ensure curl or wget is available
ensure_downloader() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
    DOWNLOADER_FLAGS="-fL"
    return 0
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
    DOWNLOADER_FLAGS="-qO-"
    return 0
  fi

  log_error "Neither curl nor wget is available."
  if command -v apt-get >/dev/null 2>&1; then
    log_info "Attempting to install curl..."
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y curl >/dev/null 2>&1 || {
      log_error "Failed to install curl. Please install curl manually: apt-get install -y curl"
      exit 1
    }
    DOWNLOADER="curl"
    DOWNLOADER_FLAGS="-fL"
    return 0
  else
    log_error "Please install curl or wget manually."
    exit 1
  fi
}

# Download repo archive
download_repo_archive() {
  local temp_dir="$1"
  local branch="$2"
  local archive_path="${temp_dir}/repo.tar.gz"

  ensure_downloader

  # GitHub archive URL format: https://github.com/<owner>/<repo>/archive/refs/heads/<branch>.tar.gz
  local url="https://github.com/${OWNER}/${REPO}/archive/refs/heads/${branch}.tar.gz"

  log_info "Downloading repository archive (${branch})..."

  if [[ "${DOWNLOADER}" == "curl" ]]; then
    if ! curl ${DOWNLOADER_FLAGS} --retry 5 --retry-delay 1 --max-time 120 -o "${archive_path}" "${url}"; then
      log_error "Failed to download repository archive from ${url}"
      return 1
    fi
  elif [[ "${DOWNLOADER}" == "wget" ]]; then
    if ! wget --quiet --tries=5 --timeout=120 -O "${archive_path}" "${url}"; then
      log_error "Failed to download repository archive from ${url}"
      return 1
    fi
  fi

  if [[ ! -s "${archive_path}" ]]; then
    log_error "Downloaded archive is empty"
    return 1
  fi

  log_info "Downloaded repository archive successfully"
  echo "${archive_path}"
}

# Extract archive and find root directory
extract_repo_archive() {
  local archive_path="$1"
  local extract_dir="$2"

  log_info "Extracting repository archive..."

  # Extract archive
  if ! tar -xzf "${archive_path}" -C "${extract_dir}" 2>/dev/null; then
    log_error "Failed to extract archive"
    return 1
  fi

  # Find extracted root directory (format: repo-branch/)
  local extracted_root
  extracted_root=$(find "${extract_dir}" -maxdepth 1 -type d -name "${REPO}-*" | head -1)

  if [[ -z "${extracted_root}" ]]; then
    log_error "Could not find extracted repository root"
    return 1
  fi

  log_info "Extracted repository to ${extracted_root}"
  
  # Verify critical directories exist in extracted archive
  local missing_dirs=()
  for dir in "cmd" "phases" "lib"; do
    if [[ ! -d "${extracted_root}/${dir}" ]]; then
      missing_dirs+=("${dir}")
    fi
  done
  
  if [[ ${#missing_dirs[@]} -gt 0 ]]; then
    log_error "Critical directories missing from archive: ${missing_dirs[*]}"
    log_error "This usually means these directories haven't been pushed to the remote repository."
    log_error "Please ensure all files are committed and pushed:"
    log_error "  git add ${missing_dirs[*]}"
    log_error "  git commit -m 'Add missing directories'"
    log_error "  git push origin main"
    return 1
  fi
  
  echo "${extracted_root}"
}

# Make scripts executable
make_scripts_executable() {
  local repo_root="$1"

  log_info "Making scripts executable..."

  # Make cmd scripts executable
  if [[ -d "${repo_root}/cmd" ]]; then
    find "${repo_root}/cmd" -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true
  fi

  # Make phase scripts executable
  if [[ -d "${repo_root}/phases" ]]; then
    find "${repo_root}/phases" -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true
  fi

  # Make tools scripts executable (optional)
  if [[ -d "${repo_root}/tools" ]]; then
    find "${repo_root}/tools" -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true
  fi
}

# Check if we're in a local git repository with cmd/ directory
is_local_repo() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
  # Check if we're in a git repo and cmd/ exists
  if [[ -d "${script_dir}/.git" ]] && [[ -d "${script_dir}/cmd" ]] && [[ -f "${script_dir}/cmd/install.sh" ]]; then
    echo "${script_dir}"
    return 0
  fi
  
  # Also check parent directory (in case voxeil.sh is in repo root)
  local parent_dir
  parent_dir="$(dirname "${script_dir}")"
  if [[ -d "${parent_dir}/.git" ]] && [[ -d "${parent_dir}/cmd" ]] && [[ -f "${parent_dir}/cmd/install.sh" ]]; then
    echo "${parent_dir}"
    return 0
  fi
  
  return 1
}

# Download and extract repo, return extracted root
setup_repo() {
  # Check if we're in a local git repository - use it if available
  local local_repo
  if local_repo=$(is_local_repo); then
    log_info "Using local repository: ${local_repo}"
    # Make scripts executable
    make_scripts_executable "${local_repo}"
    echo "${local_repo}"
    return 0
  fi

  # Otherwise, download from GitHub
  local temp_dir
  temp_dir="$(mktemp -d)"

  # Cleanup trap (unless VOXEIL_KEEP_TMP is set)
  # Capture temp_dir value at trap definition time to avoid SC2064
  # Use a global variable for the trap to access
  if [[ "${VOXEIL_KEEP_TMP:-0}" != "1" ]]; then
    _voxeil_temp_dir="${temp_dir}"
    trap 'rm -rf "${_voxeil_temp_dir}"' EXIT
  else
    log_warn "VOXEIL_KEEP_TMP=1: keeping temp directory: ${temp_dir}"
  fi

  # Download archive
  local archive_path
  archive_path=$(download_repo_archive "${temp_dir}" "${REF}") || exit 1

  # Extract archive
  local extracted_root
  extracted_root=$(extract_repo_archive "${archive_path}" "${temp_dir}") || exit 1

  # Make scripts executable
  make_scripts_executable "${extracted_root}"

  # Debug: Verify critical files exist and show archive structure
  if [[ ! -f "${extracted_root}/cmd/install.sh" ]]; then
    log_warn "cmd/install.sh not found in extracted archive"
    log_warn "Extracted root: ${extracted_root}"
    log_warn "Top-level contents of extracted archive:"
    find "${extracted_root}/" -maxdepth 1 ! -path "${extracted_root}/" 2>/dev/null | head -20 | while IFS= read -r item; do
      ls -ld "$item" 2>/dev/null || true
    done || log_warn "Cannot list extracted root"
    if [[ -d "${extracted_root}/cmd" ]]; then
      log_warn "Contents of cmd directory:"
      find "${extracted_root}/cmd/" -maxdepth 1 ! -path "${extracted_root}/cmd/" 2>/dev/null | while IFS= read -r item; do
        ls -ld "$item" 2>/dev/null || true
      done || true
    else
      log_warn "cmd directory does not exist"
      log_warn "This usually means the cmd/ directory hasn't been pushed to the remote repository."
      log_warn "Please ensure all files in cmd/ are committed and pushed: git push origin main"
    fi
  fi

  echo "${extracted_root}"
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

# Setup repo (download and extract)
REPO_ROOT=""
REPO_ROOT=$(setup_repo)

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

  # Run cmd/purge-node.sh from extracted repo
  exec bash "${REPO_ROOT}/cmd/purge-node.sh" "${FILTERED_ARGS[@]}"
fi

# Handle doctor
if [[ "${SUBCMD}" == "doctor" ]]; then
  # Run cmd/doctor.sh from extracted repo
  exec bash "${REPO_ROOT}/cmd/doctor.sh" "${SUBCMD_ARGS[@]}"
fi

# Handle install
if [[ "${SUBCMD}" == "install" ]]; then
  # Pass --version if --ref was used (installer uses --version)
  INSTALLER_ARGS=()
  if [[ "${REF}" != "main" ]]; then
    INSTALLER_ARGS+=("--version" "${REF}")
  fi
  INSTALLER_ARGS+=("${SUBCMD_ARGS[@]}")

  # Verify cmd/install.sh exists before executing
  if [[ ! -f "${REPO_ROOT}/cmd/install.sh" ]]; then
    log_error "Install script not found: ${REPO_ROOT}/cmd/install.sh"
    log_error "This may indicate the repository archive is incomplete or the file is not tracked in git."
    if [[ -d "${REPO_ROOT}/cmd" ]]; then
      log_error "Files found in cmd directory:"
      find "${REPO_ROOT}/cmd/" -maxdepth 1 ! -path "${REPO_ROOT}/cmd/" 2>/dev/null | while IFS= read -r item; do
        ls -ld "$item" 2>/dev/null | while IFS= read -r line; do
          log_error "  $line"
        done || true
      done || true
    else
      log_error "cmd directory does not exist at: ${REPO_ROOT}/cmd"
    fi
    log_error "Repository root: ${REPO_ROOT}"
    exit 1
  fi

  # Run cmd/install.sh from extracted repo
  exec bash "${REPO_ROOT}/cmd/install.sh" "${INSTALLER_ARGS[@]}"
fi

# Handle uninstall
if [[ "${SUBCMD}" == "uninstall" ]]; then
  # Run cmd/uninstall.sh from extracted repo
  exec bash "${REPO_ROOT}/cmd/uninstall.sh" "${SUBCMD_ARGS[@]}"
fi

# Unknown subcommand
log_error "Unknown subcommand: ${SUBCMD}"
echo ""
show_help
exit 1
