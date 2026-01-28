#!/usr/bin/env bash
# Alias for install.sh - maintains backward compatibility
# Use: bash cmd/installer.sh or voxeil.sh install
set -Eeuo pipefail

exec "$(dirname "$0")/install.sh" "$@"
