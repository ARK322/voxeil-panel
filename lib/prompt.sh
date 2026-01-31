#!/usr/bin/env bash
# Interactive prompt utilities for installer
# Supports both interactive and non-interactive modes

# Check if we're in CI or non-interactive mode
is_interactive() {
  if [ "${VOXEIL_CI:-0}" = "1" ] || [ "${CI:-}" = "true" ] || [ ! -t 0 ]; then
    return 1  # Non-interactive
  fi
  return 0  # Interactive
}

# Prompt for a value with optional default
# Usage: prompt_value "label" "default_value" "is_secret"
prompt_value() {
  local label="$1"
  local default_value="${2:-}"
  local is_secret="${3:-false}"
  local value=""
  
  # Non-interactive mode: use default or environment variable
  if ! is_interactive; then
    # Try environment variable first (e.g., VOXEIL_PANEL_DOMAIN for "Panel Domain")
    local env_var
    env_var="VOXEIL_$(echo "${label}" | tr '[:lower:] ' '[:upper:]_' | tr -d '()')"
    if [ -n "${!env_var:-}" ]; then
      echo "${!env_var}"
      return 0
    fi
    # Use default if provided
    if [ -n "${default_value}" ]; then
      echo "${default_value}"
      return 0
    fi
    # Generate random if no default
    if [ "${is_secret}" = "true" ]; then
      rand
    else
      echo ""
    fi
    return 0
  fi
  
  # Interactive mode: prompt user
  local prompt_text="${label}"
  if [ -n "${default_value}" ]; then
    prompt_text="${prompt_text} [default: ${default_value}]"
  fi
  prompt_text="${prompt_text}: "
  
  if [ "${is_secret}" = "true" ]; then
    # Secret input (hidden)
    read -rs -p "${prompt_text}" value
    echo "" >&2  # Newline after hidden input
  else
    # Normal input
    read -r -p "${prompt_text}" value
  fi
  
  # Use default if empty
  if [ -z "${value}" ] && [ -n "${default_value}" ]; then
    value="${default_value}"
  fi
  
  echo "${value}"
}

# Prompt for yes/no question
# Usage: prompt_yesno "question" "default"
prompt_yesno() {
  local question="$1"
  local default="${2:-n}"
  local answer=""
  
  # Non-interactive mode: use default
  if ! is_interactive; then
    echo "${default}"
    return 0
  fi
  
  # Interactive mode
  local prompt_text="${question} [y/N]: "
  if [ "${default}" = "y" ] || [ "${default}" = "Y" ]; then
    prompt_text="${question} [Y/n]: "
  fi
  
  read -r -p "${prompt_text}" answer
  answer="${answer:-${default}}"
  
  case "${answer}" in
    [yY]|[yY][eE][sS]) echo "y" ;;
    *) echo "n" ;;
  esac
}
