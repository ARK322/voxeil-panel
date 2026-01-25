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
echo ""
echo "Starting uninstall process..."

# Docker check function (for cleanup operations)
ensure_docker() {
  echo ""
  echo "=== Checking Docker availability ==="
  
  # Check if docker command exists
  if ! command -v docker >/dev/null 2>&1; then
    echo "⚠️  Docker command not found (some cleanup operations may be limited)"
    return 1
  fi
  
  # Check if daemon is reachable
  # Try multiple times as Docker might be starting up
  local check_attempts=3
  local check_attempt=0
  while [ ${check_attempt} -lt ${check_attempts} ]; do
    if docker info >/dev/null 2>&1; then
      echo "✓ Docker is available and running"
      return 0
    fi
    check_attempt=$((check_attempt + 1))
    if [ ${check_attempt} -lt ${check_attempts} ]; then
      sleep 1
    fi
  done
  
  # Check if Docker socket exists
  if [ -S /var/run/docker.sock ] 2>/dev/null || [ -S /run/docker.sock ] 2>/dev/null; then
    echo "⚠️  Docker socket exists but docker info failed (permission issue?)"
    echo "   Some cleanup operations may be limited"
    return 1
  fi
  
  echo "⚠️  Docker daemon is not running (some cleanup operations may be limited)"
  return 1
}

# Clean up filesystem files (works even if kubectl is not available)
cleanup_filesystem_files() {
  echo ""
  echo "=== Cleaning up filesystem files ==="
  files_removed=0

  # Remove Voxeil configuration files
  if [ -d /etc/voxeil ]; then
    echo "Removing /etc/voxeil directory..."
    rm -rf /etc/voxeil && files_removed=$((files_removed + 1)) || true
  fi

  # Remove voxeil-ufw-apply script
  if [ -f /usr/local/bin/voxeil-ufw-apply ]; then
    echo "Removing /usr/local/bin/voxeil-ufw-apply..."
    rm -f /usr/local/bin/voxeil-ufw-apply && files_removed=$((files_removed + 1)) || true
  fi

  # Remove systemd service files
  if [ -f /etc/systemd/system/voxeil-ufw-apply.service ]; then
    echo "Stopping and removing voxeil-ufw-apply.service..."
    systemctl stop voxeil-ufw-apply.service 2>/dev/null || true
    systemctl disable voxeil-ufw-apply.service 2>/dev/null || true
    rm -f /etc/systemd/system/voxeil-ufw-apply.service && files_removed=$((files_removed + 1)) || true
  fi

  if [ -f /etc/systemd/system/voxeil-ufw-apply.path ]; then
    echo "Stopping and removing voxeil-ufw-apply.path..."
    systemctl stop voxeil-ufw-apply.path 2>/dev/null || true
    systemctl disable voxeil-ufw-apply.path 2>/dev/null || true
    rm -f /etc/systemd/system/voxeil-ufw-apply.path && files_removed=$((files_removed + 1)) || true
  fi

  # Reload systemd if services were removed
  if [ ${files_removed} -gt 0 ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
  fi

  # Remove fail2ban voxeil config
  if [ -f /etc/fail2ban/jail.d/voxeil.conf ]; then
    echo "Removing /etc/fail2ban/jail.d/voxeil.conf..."
    rm -f /etc/fail2ban/jail.d/voxeil.conf && files_removed=$((files_removed + 1)) || true
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
      systemctl reload fail2ban 2>/dev/null || true
    fi
  fi

  # Remove SSH config backups (voxeil-backup.*)
  if ls /etc/ssh/sshd_config.voxeil-backup.* 2>/dev/null | grep -q .; then
    echo "Removing SSH config backups..."
    rm -f /etc/ssh/sshd_config.voxeil-backup.* && files_removed=$((files_removed + 1)) || true
  fi

  if [ ${files_removed} -gt 0 ]; then
    echo "Removed ${files_removed} file(s)/directory(ies)"
  else
    echo "No filesystem files found to remove"
  fi
  
  return ${files_removed}
}

# Clean up filesystem files first (works even without kubectl)
cleanup_filesystem_files || true

# Check if kubectl is available
if ! command -v kubectl >/dev/null 2>&1; then
  echo "⚠️  kubectl is not installed or not in PATH"
  echo ""
  echo "This means k3s/Kubernetes is not installed."
  echo "Filesystem files have been cleaned up (if any were found)."
  echo ""
  echo "If you want to completely remove everything, you can:"
  echo "  1. Remove k3s: /usr/local/bin/k3s-uninstall.sh (if exists)"
  echo "  2. Remove Docker (if installed): apt-get remove -y docker.io containerd"
  echo ""
  echo "Exiting uninstaller (nothing to uninstall from Kubernetes)."
  # Small delay to allow curl to finish writing before pipe closes
  sleep 0.1 2>/dev/null || true
  exit 0
fi

# Check if we can connect to cluster
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "⚠️  Cannot connect to Kubernetes cluster"
  echo ""
  echo "The cluster may not be running or k3s may have been removed."
  echo "Filesystem files have been cleaned up (if any were found)."
  echo ""
  echo "If you want to completely remove everything, you can:"
  echo "  1. Remove k3s: /usr/local/bin/k3s-uninstall.sh (if exists)"
  echo "  2. Remove Docker (if installed): apt-get remove -y docker.io containerd"
  echo ""
  echo "Exiting uninstaller (cannot connect to cluster)."
  # Small delay to allow curl to finish writing before pipe closes
  sleep 0.1 2>/dev/null || true
  exit 0
fi

# Check Docker (non-fatal, just warn if unavailable)
ensure_docker || true

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

# Delete Kyverno (automatic)
echo ""
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

# Delete Flux (automatic)
echo ""
echo "Deleting Flux..."
delete_namespace "flux-system"

# Delete Flux CRDs
echo "Deleting Flux CRDs..."
kubectl delete crd -l app.kubernetes.io/name=flux --ignore-not-found=true >/dev/null 2>&1 || true
echo "  ✓ Flux CRDs deleted"

# Delete cert-manager (automatic)
echo ""
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

# Clean up any remaining problematic resources
echo ""
echo "=== Cleaning up any remaining problematic resources ==="
cleaned_count=0

# Clean up orphaned webhooks
echo "Cleaning up orphaned webhooks..."
orphaned_webhooks="$(kubectl get validatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE '(kyverno|flux|cert-manager)' || true)"
orphaned_mutating="$(kubectl get mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE '(kyverno|flux|cert-manager)' || true)"

for webhook in ${orphaned_webhooks}; do
  kubectl delete validatingwebhookconfiguration "${webhook}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
    cleaned_count=$((cleaned_count + 1)) || true
done

for webhook in ${orphaned_mutating}; do
  kubectl delete mutatingwebhookconfiguration "${webhook}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
    cleaned_count=$((cleaned_count + 1)) || true
done

# Clean up stuck PVCs with finalizers
echo "Cleaning up stuck PVCs..."
for ns in platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager; do
  if kubectl get namespace "${ns}" >/dev/null 2>&1; then
    pvcs="$(kubectl get pvc -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    for pvc in ${pvcs}; do
      kubectl patch pvc "${pvc}" -n "${ns}" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      kubectl delete pvc "${pvc}" -n "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
        cleaned_count=$((cleaned_count + 1)) || true
    done
  fi
done

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

# Clean up namespaces stuck in Terminating state
echo "Cleaning up namespaces stuck in Terminating state..."
for ns in ${remaining_namespaces}; do
  if kubectl get namespace "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Terminating"; then
    echo "  Fixing namespace ${ns} stuck in Terminating..."
    # Remove finalizers
    if command -v jq >/dev/null 2>&1; then
      kubectl get namespace "${ns}" -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
    else
      # Fallback: patch finalizers
      kubectl patch namespace "${ns}" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
    fi
    cleaned_count=$((cleaned_count + 1))
  fi
done

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
echo "Note: If you want to remove Docker, run:"
echo "  apt-get remove -y docker.io containerd"
echo ""
echo "Uninstall completed."
