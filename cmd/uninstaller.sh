#!/usr/bin/env bash
# Alias for uninstall.sh - maintains backward compatibility
# Use: bash cmd/uninstaller.sh or voxeil.sh uninstall
set -Eeuo pipefail

exec "$(dirname "$0")/uninstall.sh" "$@"
