#!/usr/bin/env bash
# Alias for purge-node.sh --force - maintains backward compatibility
# Use: bash cmd/nuke.sh or voxeil.sh nuke --force
set -Eeuo pipefail

exec "$(dirname "$0")/purge-node.sh" --force "$@"
