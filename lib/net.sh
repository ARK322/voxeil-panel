#!/usr/bin/env bash
# Network utilities (curl/wget, GitHub fetch helpers)
# Source this file: source "$(dirname "$0")/../lib/net.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Ensure curl is available
ensure_curl() {
  if ! command_exists curl; then
    log_info "curl not found, attempting to install..."
    if command_exists apt-get; then
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y curl >/dev/null 2>&1 || {
        log_error "Failed to install curl. Please install curl manually: apt-get install -y curl"
        return 1
      }
    else
      log_error "curl is required but not installed. Please install curl manually."
      return 1
    fi
  fi
  return 0
}

# Download a script from GitHub (for voxeil.sh dispatcher)
download_script() {
  local script_path="$1"
  local output_path="$2"
  local desc="${3:-${script_path}}"
  local owner="${OWNER:-ARK322}"
  local repo="${REPO:-voxeil-panel}"
  local ref="${REF:-main}"
  
  ensure_curl
  
  local url="https://raw.githubusercontent.com/${owner}/${repo}/${ref}/${script_path}"
  
  log_info "Downloading ${desc}..."
  if ! curl -fL --retry 5 --retry-delay 1 --max-time 60 -o "${output_path}" "${url}"; then
    log_error "Failed to download ${desc} from ${url}"
    return 1
  fi
  
  if [[ ! -s "${output_path}" ]]; then
    log_error "Downloaded ${desc} is empty"
    return 1
  fi
  
  chmod +x "${output_path}"
  log_info "Downloaded ${desc} successfully"
  return 0
}

# Fetch a file from GitHub raw URL (for installer phases)
fetch_file() {
  local repo_path="$1"
  local output_path="$2"
  local max_retries="${3:-5}"
  local retry_delay="${4:-1}"
  local github_raw_base="${GITHUB_RAW_BASE:-}"
  local attempt=1
  
  ensure_curl
  
  if [ -z "${github_raw_base}" ]; then
    local repo="${REPO:-ARK322/voxeil-panel}"
    local ref="${REF:-main}"
    github_raw_base="https://raw.githubusercontent.com/${repo}/${ref}"
  fi
  
  local url="${github_raw_base}/${repo_path}"
  
  while [ "${attempt}" -le "${max_retries}" ]; do
    if curl -fL --retry 2 --retry-delay "${retry_delay}" --max-time 30 -o "${output_path}" "${url}" 2>/dev/null; then
      if [ -s "${output_path}" ]; then
        return 0
      else
        log_warn "Downloaded file is empty: ${url} (attempt ${attempt}/${max_retries})"
      fi
    else
      log_warn "Failed to fetch ${url} (attempt ${attempt}/${max_retries})"
    fi
    
    if [ "${attempt}" -lt "${max_retries}" ]; then
      sleep "${retry_delay}"
      retry_delay=$((retry_delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  
  log_error "Failed to fetch ${url} after ${max_retries} attempts"
  return 1
}

# Check network connectivity to a host
check_network_connectivity() {
  local host="$1"
  if command_exists curl; then
    if curl -fsSL --max-time 5 --connect-timeout 5 "https://${host}" >/dev/null 2>&1 || \
       curl -fsSL --max-time 5 --connect-timeout 5 "http://${host}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if command_exists ping; then
    if ping -c 1 -W 2 "${host}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}
