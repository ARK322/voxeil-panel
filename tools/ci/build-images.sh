#!/bin/bash
set -euo pipefail

# Build script for Voxeil Panel images
# Usage:
#   ./scripts/build-images.sh [--push] [--tag TAG]
#   --push: Push images to GHCR after building
#   --tag TAG: Use custom tag (default: latest)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default values
PUSH=false
TAG="${TAG:-latest}"
GHCR_OWNER="${GHCR_OWNER:-ark322}"
GHCR_REPO="${GHCR_REPO:-voxeil-panel}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --push)
      PUSH=true
      shift
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --owner)
      GHCR_OWNER="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--push] [--tag TAG] [--owner OWNER]"
      exit 1
      ;;
  esac
done

# Check if Docker is available
if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker is not installed or not in PATH"
  exit 1
fi

# Bulletproof prompt system: prefer /dev/tty if readable, else /dev/stdin
# PROMPT_OUT: prefer /dev/tty if writable/readable, else /dev/stdout
# This ensures prompts work in SSH command mode and piped execution
if [[ -r /dev/tty ]]; then
  PROMPT_IN="/dev/tty"
else
  PROMPT_IN="/dev/stdin"
fi

if [[ -w /dev/tty ]] && [[ -r /dev/tty ]]; then
  PROMPT_OUT="/dev/tty"
else
  PROMPT_OUT="/dev/stdout"
fi

# Check if logged in to GHCR (if pushing)
if [ "$PUSH" = true ]; then
  if ! docker info | grep -q "Username"; then
    echo "Warning: Not logged in to Docker. You may need to:"
    echo "  echo \$GHCR_TOKEN | docker login ghcr.io -u \$GHCR_USERNAME --password-stdin"
    echo ""
    printf "Continue anyway? (y/N) " > "${PROMPT_OUT}"
    if read -r -n 1 -t 30 reply < "${PROMPT_IN}"; then
      printf "\n" > "${PROMPT_OUT}"
      if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
        exit 1
      fi
    else
      printf "\n" > "${PROMPT_OUT}"
      echo "No input received, exiting."
      exit 1
    fi
  fi
fi

CONTROLLER_IMAGE="ghcr.io/${GHCR_OWNER}/voxeil-controller:${TAG}"
PANEL_IMAGE="ghcr.io/${GHCR_OWNER}/voxeil-panel:${TAG}"

echo "=== Building Voxeil Panel Images ==="
echo "Controller image: ${CONTROLLER_IMAGE}"
echo "Panel image: ${PANEL_IMAGE}"
echo "Push to registry: ${PUSH}"
echo ""

# Build controller image
echo "Building controller image..."
cd "${REPO_ROOT}/apps/controller" || { echo "Error: failed to cd to ${REPO_ROOT}/apps/controller"; exit 1; }
docker build -t "${CONTROLLER_IMAGE}" .
echo "✓ Controller image built: ${CONTROLLER_IMAGE}"

# Build panel image
echo "Building panel image..."
cd "${REPO_ROOT}/apps/panel" || { echo "Error: failed to cd to ${REPO_ROOT}/apps/panel"; exit 1; }
docker build -t "${PANEL_IMAGE}" .
echo "✓ Panel image built: ${PANEL_IMAGE}"

# Optionally create local tags for testing
if [ "$TAG" != "local" ]; then
  echo ""
  echo "Creating local tags for testing..."
  docker tag "${CONTROLLER_IMAGE}" "ghcr.io/${GHCR_OWNER}/voxeil-controller:local" || true
  docker tag "${PANEL_IMAGE}" "ghcr.io/${GHCR_OWNER}/voxeil-panel:local" || true
  echo "✓ Local tags created"
fi

# Push images if requested
if [ "$PUSH" = true ]; then
  echo ""
  echo "Pushing images to GHCR..."
  docker push "${CONTROLLER_IMAGE}"
  echo "✓ Controller image pushed"
  docker push "${PANEL_IMAGE}"
  echo "✓ Panel image pushed"
  echo ""
  echo "Images are now available at:"
  echo "  - ${CONTROLLER_IMAGE}"
  echo "  - ${PANEL_IMAGE}"
else
  echo ""
  echo "Images built locally. To push to GHCR, run:"
  echo "  docker push ${CONTROLLER_IMAGE}"
  echo "  docker push ${PANEL_IMAGE}"
  echo ""
  echo "Or use this script with --push flag:"
  echo "  $0 --push --tag ${TAG}"
fi

echo ""
echo "=== Build Complete ==="
echo ""
echo "To use these images during installation, set:"
echo "  export CONTROLLER_IMAGE=${CONTROLLER_IMAGE}"
echo "  export PANEL_IMAGE=${PANEL_IMAGE}"
echo ""
if [ "$TAG" = "local" ] || [ "$PUSH" = false ]; then
  echo "For local images, the installer will detect them automatically."
fi
