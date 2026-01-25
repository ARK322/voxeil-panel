#!/usr/bin/env bash
set -euo pipefail

# Voxeil Panel Clean Verification Script
# Detects leftover resources and exits non-zero if anything remains

EXIT_CODE=0

echo "=== Voxeil Panel Clean Verification ==="
echo ""

# Check kubectl availability
if ! command -v kubectl >/dev/null 2>&1 || ! kubectl cluster-info >/dev/null 2>&1; then
  echo "⚠ kubectl not available or cluster not accessible"
  echo "  Skipping Kubernetes resource checks..."
  KUBECTL_AVAILABLE=false
else
  KUBECTL_AVAILABLE=true
fi

# Check for leftover namespaces
echo "Checking namespaces..."
if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  VOXEIL_NAMESPACES="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^(platform|infra-db|dns-zone|mail-zone|backup-system|kyverno|flux-system|cert-manager|user-|tenant-)' || true)"
  if [ -n "${VOXEIL_NAMESPACES}" ]; then
    echo "  ✗ Found Voxeil namespaces:"
    echo "${VOXEIL_NAMESPACES}" | while read -r ns; do
      echo "    - ${ns}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil namespaces found"
  fi
else
  echo "  ⚠ Skipped (kubectl not available)"
fi

# Check for leftover CRDs
echo ""
echo "Checking CRDs..."
if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  VOXEIL_CRDS="$(kubectl get crd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '(cert-manager|kyverno|flux)' || true)"
  if [ -n "${VOXEIL_CRDS}" ]; then
    echo "  ✗ Found Voxeil CRDs:"
    echo "${VOXEIL_CRDS}" | while read -r crd; do
      echo "    - ${crd}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil CRDs found"
  fi
else
  echo "  ⚠ Skipped (kubectl not available)"
fi

# Check for leftover ClusterRoles
echo ""
echo "Checking ClusterRoles..."
if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  VOXEIL_CLUSTERROLES="$(kubectl get clusterrole -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '(controller-bootstrap|user-operator)' || true)"
  if [ -n "${VOXEIL_CLUSTERROLES}" ]; then
    echo "  ✗ Found Voxeil ClusterRoles:"
    echo "${VOXEIL_CLUSTERROLES}" | while read -r cr; do
      echo "    - ${cr}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil ClusterRoles found"
  fi
else
  echo "  ⚠ Skipped (kubectl not available)"
fi

# Check for leftover ClusterRoleBindings
echo ""
echo "Checking ClusterRoleBindings..."
if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  VOXEIL_CLUSTERROLEBINDINGS="$(kubectl get clusterrolebinding -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E 'controller-bootstrap-binding' || true)"
  if [ -n "${VOXEIL_CLUSTERROLEBINDINGS}" ]; then
    echo "  ✗ Found Voxeil ClusterRoleBindings:"
    echo "${VOXEIL_CLUSTERROLEBINDINGS}" | while read -r crb; do
      echo "    - ${crb}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil ClusterRoleBindings found"
  fi
else
  echo "  ⚠ Skipped (kubectl not available)"
fi

# Check for leftover webhooks
echo ""
echo "Checking webhooks..."
if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  VOXEIL_WEBHOOKS="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE '(kyverno|cert-manager|flux)' || true)"
  if [ -n "${VOXEIL_WEBHOOKS}" ]; then
    echo "  ✗ Found Voxeil webhooks:"
    echo "${VOXEIL_WEBHOOKS}" | while read -r wh; do
      echo "    - ${wh}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil webhooks found"
  fi
else
  echo "  ⚠ Skipped (kubectl not available)"
fi

# Check for leftover PVCs
echo ""
echo "Checking PVCs..."
if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  VOXEIL_PVCS="$(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '^(platform|infra-db|dns-zone|mail-zone|backup-system|user-|tenant-)/' || true)"
  if [ -n "${VOXEIL_PVCS}" ]; then
    echo "  ✗ Found Voxeil PVCs:"
    echo "${VOXEIL_PVCS}" | while read -r pvc; do
      echo "    - ${pvc}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil PVCs found"
  fi
else
  echo "  ⚠ Skipped (kubectl not available)"
fi

# Check for leftover PersistentVolumes
echo ""
echo "Checking PersistentVolumes..."
if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  # Check for PVs that might be from Voxeil (by checking if they're Released/Available and have local-path storage class)
  VOXEIL_PVS="$(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.storageClassName}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -E 'local-path.*(Released|Available)' | cut -f1 || true)"
  if [ -n "${VOXEIL_PVS}" ]; then
    echo "  ⚠ Found potentially orphaned PVs (local-path, Released/Available):"
    echo "${VOXEIL_PVS}" | while read -r pv; do
      echo "    - ${pv}"
    done
    # Don't fail on this - these might be from other applications
  else
    echo "  ✓ No orphaned PVs found"
  fi
else
  echo "  ⚠ Skipped (kubectl not available)"
fi

# Check for leftover filesystem files
echo ""
echo "Checking filesystem files..."
FILES_FOUND=0
if [ -d /etc/voxeil ]; then
  echo "  ✗ Found /etc/voxeil directory"
  FILES_FOUND=1
  EXIT_CODE=1
fi
if [ -f /usr/local/bin/voxeil-ufw-apply ]; then
  echo "  ✗ Found /usr/local/bin/voxeil-ufw-apply"
  FILES_FOUND=1
  EXIT_CODE=1
fi
if [ -f /var/lib/voxeil/install.state ]; then
  echo "  ✗ Found /var/lib/voxeil/install.state"
  FILES_FOUND=1
  EXIT_CODE=1
fi
if [ ${FILES_FOUND} -eq 0 ]; then
  echo "  ✓ No Voxeil filesystem files found"
fi

# Check for leftover ClusterIssuers
echo ""
echo "Checking ClusterIssuers..."
if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  VOXEIL_CLUSTERISSUERS="$(kubectl get clusterissuer -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '(letsencrypt-prod|letsencrypt-staging)' || true)"
  if [ -n "${VOXEIL_CLUSTERISSUERS}" ]; then
    echo "  ✗ Found Voxeil ClusterIssuers:"
    echo "${VOXEIL_CLUSTERISSUERS}" | while read -r ci; do
      echo "    - ${ci}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil ClusterIssuers found"
  fi
else
  echo "  ⚠ Skipped (kubectl not available)"
fi

# Check for leftover HelmChartConfig
echo ""
echo "Checking HelmChartConfig..."
if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  if kubectl get helmchartconfig traefik -n kube-system >/dev/null 2>&1; then
    # Check if it has the voxeil label
    if kubectl get helmchartconfig traefik -n kube-system -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -q "voxeil"; then
      echo "  ✗ Found Voxeil HelmChartConfig: traefik"
      EXIT_CODE=1
    else
      echo "  ✓ No Voxeil HelmChartConfig found"
    fi
  else
    echo "  ✓ No Voxeil HelmChartConfig found"
  fi
else
  echo "  ⚠ Skipped (kubectl not available)"
fi

# Summary
echo ""
echo "=== Summary ==="
if [ ${EXIT_CODE} -eq 0 ]; then
  echo "✓ System is clean - no Voxeil resources found"
  exit 0
else
  echo "✗ System has leftover Voxeil resources"
  echo ""
  echo "Run the uninstaller to clean up:"
  echo "  ./uninstaller/uninstaller.sh"
  exit 1
fi
