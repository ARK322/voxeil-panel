#!/usr/bin/env bash
set -euo pipefail

# Voxeil Panel Uninstaller
# This script removes all Voxeil Panel components from the cluster

echo "== Voxeil Panel Uninstaller =="
echo ""
echo "WARNING: This will delete all Voxeil Panel components including:"
echo "  - All application namespaces (platform, infra-db, dns-zone, mail-zone, backup-system)"
echo "  - All user and tenant namespaces"
echo "  - All data in PVCs (this cannot be undone!)"
echo "  - Kyverno policies and resources"
echo "  - Flux resources"
echo ""

# Support non-interactive mode via environment variable
if [[ "${UNINSTALL_CONFIRM:-}" == "yes" ]]; then
  echo "Non-interactive mode: UNINSTALL_CONFIRM=yes detected, proceeding..."
  confirm="yes"
else
  read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm
fi

if [[ "${confirm}" != "yes" ]]; then
  echo "Uninstall cancelled."
  exit 0
fi

# Check if kubectl is available
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is not installed or not in PATH"
  exit 1
fi

# Check if we can connect to cluster
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to Kubernetes cluster"
  exit 1
fi

echo ""
echo "Starting uninstall process..."
echo ""

# Function to delete namespace and wait for it to be removed
delete_namespace() {
  local namespace="$1"
  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    echo "Deleting namespace: ${namespace}..."
    kubectl delete namespace "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    
    # Wait for namespace to be deleted (with timeout)
    local max_wait=60
    local waited=0
    while [ ${waited} -lt ${max_wait} ]; do
      if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        echo "  ✓ Namespace ${namespace} deleted"
        return 0
      fi
      sleep 1
      waited=$((waited + 1))
      if [ $((waited % 10)) -eq 0 ]; then
        echo "  Waiting for namespace ${namespace} to be deleted... (${waited}/${max_wait}s)"
      fi
    done
    echo "  ⚠ Warning: Namespace ${namespace} still exists after ${max_wait}s, may need manual cleanup"
  else
    echo "  Namespace ${namespace} does not exist, skipping"
  fi
}

# Delete Voxeil Panel namespaces
echo "=== Deleting Voxeil Panel namespaces ==="
delete_namespace "platform"
delete_namespace "infra-db"
delete_namespace "dns-zone"
delete_namespace "mail-zone"
delete_namespace "backup-system"

# Delete user namespaces (all namespaces matching user-* pattern)
echo ""
echo "=== Deleting user namespaces ==="
user_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^user-' || true)"
if [ -n "${user_namespaces}" ]; then
  for ns in ${user_namespaces}; do
    delete_namespace "${ns}"
  done
else
  echo "No user namespaces found"
fi

# Delete tenant namespaces (all namespaces matching tenant-* pattern)
echo ""
echo "=== Deleting tenant namespaces ==="
tenant_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^tenant-' || true)"
if [ -n "${tenant_namespaces}" ]; then
  for ns in ${tenant_namespaces}; do
    delete_namespace "${ns}"
  done
else
  echo "No tenant namespaces found"
fi

# Delete Kyverno (optional - ask user)
echo ""
if [[ "${UNINSTALL_CONFIRM:-}" == "yes" ]]; then
  # Non-interactive: default to not deleting (safer)
  delete_kyverno="N"
else
  read -p "Delete Kyverno? (y/N): " delete_kyverno
fi
if [[ "${delete_kyverno}" =~ ^[Yy]$ ]]; then
  echo "Deleting Kyverno..."
  delete_namespace "kyverno"
  
  # Delete Kyverno CRDs
  echo "Deleting Kyverno CRDs..."
  kubectl delete crd -l app.kubernetes.io/name=kyverno --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete crd policies.kyverno.io --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete crd clusterpolicies.kyverno.io --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete crd policyreports.wgpolicyk8s.io --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete crd clusterpolicyreports.wgpolicyk8s.io --ignore-not-found=true >/dev/null 2>&1 || true
  echo "  ✓ Kyverno CRDs deleted"
fi

# Delete Flux (optional - ask user)
echo ""
if [[ "${UNINSTALL_CONFIRM:-}" == "yes" ]]; then
  # Non-interactive: default to not deleting (safer)
  delete_flux="N"
else
  read -p "Delete Flux? (y/N): " delete_flux
fi
if [[ "${delete_flux}" =~ ^[Yy]$ ]]; then
  echo "Deleting Flux..."
  delete_namespace "flux-system"
  
  # Delete Flux CRDs
  echo "Deleting Flux CRDs..."
  kubectl delete crd -l app.kubernetes.io/name=flux --ignore-not-found=true >/dev/null 2>&1 || true
  echo "  ✓ Flux CRDs deleted"
fi

# Delete cert-manager (optional - ask user)
echo ""
if [[ "${UNINSTALL_CONFIRM:-}" == "yes" ]]; then
  # Non-interactive: default to not deleting (safer)
  delete_cert_manager="N"
else
  read -p "Delete cert-manager? (y/N): " delete_cert_manager
fi
if [[ "${delete_cert_manager}" =~ ^[Yy]$ ]]; then
  echo "Deleting cert-manager..."
  delete_namespace "cert-manager"
  
  # Delete cert-manager CRDs
  echo "Deleting cert-manager CRDs..."
  kubectl delete crd -l app.kubernetes.io/name=cert-manager --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete crd certificates.cert-manager.io --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete crd certificaterequests.cert-manager.io --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete crd challenges.acme.cert-manager.io --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete crd clusterissuers.cert-manager.io --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete crd issuers.cert-manager.io --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete crd orders.acme.cert-manager.io --ignore-not-found=true >/dev/null 2>&1 || true
  echo "  ✓ cert-manager CRDs deleted"
fi

# Clean up any remaining problematic resources
echo ""
echo "=== Cleaning up any remaining problematic resources ==="
cleaned_count=0

# Get all remaining namespaces (excluding system namespaces)
remaining_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -vE '^(kube-system|kube-public|kube-node-lease|default)$' || true)"

if [ -n "${remaining_namespaces}" ]; then
  for namespace in ${remaining_namespaces}; do
    # Find pods with ImagePullBackOff or ErrImagePull errors
    failed_pods="$(kubectl get pods -n "${namespace}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | \
      grep -E "(ImagePullBackOff|ErrImagePull)" | cut -f1 || true)"
    
    if [ -n "${failed_pods}" ]; then
      for pod in ${failed_pods}; do
        job_name="$(kubectl get pod "${pod}" -n "${namespace}" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Job")].name}' 2>/dev/null || true)"
        if [ -n "${job_name}" ]; then
          kubectl delete job "${job_name}" -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
            cleaned_count=$((cleaned_count + 1)) || true
        else
          kubectl delete pod "${pod}" -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
            cleaned_count=$((cleaned_count + 1)) || true
        fi
      done
    fi
  done
fi

if [ ${cleaned_count} -gt 0 ]; then
  echo "Cleaned up ${cleaned_count} problematic resource(s)"
else
  echo "No problematic resources found"
fi

echo ""
echo "=== Uninstall Summary ==="
echo "Voxeil Panel components have been removed."
echo ""
echo "Remaining resources (if any):"
kubectl get namespaces 2>/dev/null | grep -vE '^(NAME|kube-system|kube-public|kube-node-lease|default)$' || echo "No remaining namespaces"
echo ""
echo "Note: If you want to completely remove k3s, run:"
echo "  /usr/local/bin/k3s-uninstall.sh"
echo ""
echo "Uninstall completed."
