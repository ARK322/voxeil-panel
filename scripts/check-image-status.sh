#!/usr/bin/env bash
set -euo pipefail

# Quick script to check image pull status
# Usage: bash scripts/check-image-status.sh

echo "=== Image Pull Status Check ==="
echo ""

# Check panel pods
echo "=== Panel Pods ==="
kubectl get pods -n platform -l app=panel -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,IMAGE:.spec.containers[0].image,WAITING:.status.containerStatuses[0].state.waiting.reason,ERROR:.status.containerStatuses[0].state.waiting.message 2>/dev/null || kubectl get pods -n platform -l app=panel

echo ""
echo "Panel pod details:"
for pod in $(kubectl get pods -n platform -l app=panel -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  echo "--- Pod: ${pod} ---"
  kubectl get pod "${pod}" -n platform -o jsonpath='{.status.containerStatuses[0]}' | python3 -m json.tool 2>/dev/null || kubectl describe pod "${pod}" -n platform | grep -A 10 "State:" || true
  echo ""
done

echo ""
echo "=== Controller Pods ==="
kubectl get pods -n platform -l app=controller -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,IMAGE:.spec.containers[0].image,WAITING:.status.containerStatuses[0].state.waiting.reason,ERROR:.status.containerStatuses[0].state.waiting.message 2>/dev/null || kubectl get pods -n platform -l app=controller

echo ""
echo "Controller pod details:"
for pod in $(kubectl get pods -n platform -l app=controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  echo "--- Pod: ${pod} ---"
  kubectl get pod "${pod}" -n platform -o jsonpath='{.status.containerStatuses[0]}' | python3 -m json.tool 2>/dev/null || kubectl describe pod "${pod}" -n platform | grep -A 10 "State:" || true
  echo ""
done

echo ""
echo "=== Image Pull Errors Summary ==="
IMAGE_ERRORS=$(kubectl get pods -n platform -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\t"}{.status.containerStatuses[0].state.waiting.message}{"\n"}{end}' 2>/dev/null | grep -E "(ImagePullBackOff|ErrImagePull|ImagePullError)" || echo "")

if [ -z "${IMAGE_ERRORS}" ]; then
  echo "✓ No image pull errors detected"
else
  echo "❌ Image pull errors found:"
  echo "${IMAGE_ERRORS}" | while IFS=$'\t' read -r pod reason message; do
    echo "  Pod: ${pod}"
    echo "  Reason: ${reason}"
    [ -n "${message}" ] && echo "  Message: ${message}"
    echo ""
  done
fi

echo ""
echo "=== Expected Images ==="
PANEL_IMAGE=$(kubectl get deployment panel -n platform -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "NOT FOUND")
CONTROLLER_IMAGE=$(kubectl get deployment controller -n platform -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "NOT FOUND")

echo "Panel image: ${PANEL_IMAGE}"
echo "Controller image: ${CONTROLLER_IMAGE}"

echo ""
echo "=== Quick Fix Commands ==="
if [ -n "${IMAGE_ERRORS}" ]; then
  echo "If images don't exist, you need to:"
  echo "1. Build images: ./scripts/build-images.sh --tag local"
  echo "2. Or push to registry: ./scripts/build-images.sh --push --tag latest"
  echo ""
  echo "Then update deployments:"
  echo "  kubectl set image deployment/panel panel=ghcr.io/ark322/voxeil-panel:local -n platform"
  echo "  kubectl set image deployment/controller controller=ghcr.io/ark322/voxeil-controller:local -n platform"
fi
