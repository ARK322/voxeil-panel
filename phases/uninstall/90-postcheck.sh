#!/usr/bin/env bash
# Uninstall phase: Post-uninstall checks
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/kube.sh
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "uninstall/90-postcheck"

# Ensure kubectl is available
ensure_kubectl || exit 1

# List of voxeil-owned namespaces
VOXEIL_NAMESPACES=(
  "platform"
  "cert-manager"
  "kyverno"
  "infra-db"
  "dns-zone"
  "mail-zone"
  "flux-system"
)

FAILED=0
REMAINING_NAMESPACES=()

log_info "Checking for remaining voxeil-owned namespaces..."

# Check each namespace
for ns in "${VOXEIL_NAMESPACES[@]}"; do
  if run_kubectl get namespace "${ns}" >/dev/null 2>&1; then
    # Verify it's actually owned by voxeil
    owned=$(run_kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.voxeil\.io/owned}' 2>/dev/null || echo "")
    if [ "${owned}" = "true" ]; then
      REMAINING_NAMESPACES+=("${ns}")
      FAILED=$((FAILED + 1))
      log_warn "Found remaining voxeil-owned namespace: ${ns}"
    fi
  fi
done

# Check for any other namespaces with voxeil.io/owned=true label
log_info "Scanning for any other namespaces with voxeil.io/owned=true label..."
ALL_VOXEIL_NS=""
ALL_VOXEIL_NS=$(run_kubectl get namespaces -l voxeil.io/owned=true --no-headers -o custom-columns=:metadata.name 2>/dev/null || echo "")

if [ -n "${ALL_VOXEIL_NS}" ]; then
  while IFS= read -r ns; do
    if [ -n "${ns}" ]; then
      # Check if already in our list
      found=false
      for existing_ns in "${REMAINING_NAMESPACES[@]}"; do
        if [ "${existing_ns}" = "${ns}" ]; then
          found=true
          break
        fi
      done
      if [ "${found}" = "false" ]; then
        REMAINING_NAMESPACES+=("${ns}")
        FAILED=$((FAILED + 1))
        log_warn "Found additional voxeil-owned namespace: ${ns}"
      fi
    fi
  done <<< "${ALL_VOXEIL_NS}"
fi

# Check for voxeil CRDs (only those we install)
log_info "Checking for voxeil CRDs..."
VOXEIL_CRDS=(
  "certificates.cert-manager.io"
  "certificaterequests.cert-manager.io"
  "challenges.acme.cert-manager.io"
  "orders.acme.cert-manager.io"
  "clusterissuers.cert-manager.io"
  "issuers.cert-manager.io"
  "policies.kyverno.io"
  "clusterpolicies.kyverno.io"
  "admissionreports.kyverno.io"
  "clusteradmissionreports.kyverno.io"
  "backgroundscans.kyverno.io"
  "clustercleanuppolicies.kyverno.io"
  "cleanuppolicies.kyverno.io"
  "updaterequests.kyverno.io"
  "kustomizations.kustomize.toolkit.fluxcd.io"
  "gitrepositories.source.toolkit.fluxcd.io"
  "helmreleases.helm.toolkit.fluxcd.io"
)

REMAINING_CRDS=()
for crd in "${VOXEIL_CRDS[@]}"; do
  if run_kubectl get crd "${crd}" >/dev/null 2>&1; then
    # Check if it's actually from our installation (has voxeil label or part-of label)
    labels=$(run_kubectl get crd "${crd}" -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "")
    if echo "${labels}" | grep -q "voxeil\|part-of.*voxeil" || [ -z "${labels}" ]; then
      # For CRDs, we're more lenient - they might be from other sources
      # Only warn if we're sure they're ours
      log_info "Found CRD: ${crd} (may be from other sources, not removing)"
    fi
  fi
done

# Print summary
echo ""
echo "=== Post-Uninstall Check Summary ==="

if [ ${FAILED} -eq 0 ]; then
  log_ok "No voxeil-owned namespaces remaining"
  echo ""
  log_ok "Uninstall verification complete - system is clean"
  exit 0
else
  log_error "Found ${FAILED} remaining voxeil-owned namespace(s):"
  for ns in "${REMAINING_NAMESPACES[@]}"; do
    echo "  - ${ns}"
    log_info "Namespace ${ns} details:"
    run_kubectl get namespace "${ns}" -o yaml | grep -A 5 "status:" || true
  done
  echo ""
  log_error "Uninstall verification failed - manual cleanup may be required"
  log_error "To force cleanup, you may need to manually remove finalizers or resources"
  exit 1
fi
