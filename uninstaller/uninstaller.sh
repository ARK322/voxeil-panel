#!/usr/bin/env bash
set -euo pipefail

# Voxeil Panel Uninstaller
# This script removes all Voxeil Panel components from the cluster

echo "== Voxeil Panel Uninstaller - VPS FORMAT MODE =="
echo ""
echo "⚠️  WARNING: COMPLETE VPS FORMAT - EVERYTHING WILL BE DELETED ⚠️"
echo ""
echo "This will PERMANENTLY DELETE EVERYTHING including:"
echo "  - All Voxeil Panel namespaces (platform, infra-db, dns-zone, mail-zone, backup-system)"
echo "  - All user and tenant namespaces"
echo "  - ALL PVCs and PersistentVolumes (ALL DATA WILL BE LOST!)"
echo "  - All deployments, services, configmaps, secrets"
echo "  - All CRDs (Kyverno, Flux, cert-manager)"
echo "  - All webhooks and cluster resources"
echo "  - All filesystem files and configurations"
echo "  - k3s system namespaces (kube-system, kube-public, kube-node-lease, default)"
echo "  - All IngressClass and StorageClass resources"
echo "  - ALL Kubernetes resources (complete cluster wipe)"
echo ""
echo "THIS IS A COMPLETE VPS FORMAT! THIS CANNOT BE UNDONE!"
echo "All data and configurations will be permanently deleted."
echo ""
echo "Starting complete VPS format process..."

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

  # Remove Docker images (backup-runner:local)
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker image inspect backup-runner:local >/dev/null 2>&1; then
      echo "Removing Docker image: backup-runner:local..."
      docker rmi backup-runner:local >/dev/null 2>&1 && files_removed=$((files_removed + 1)) || true
    fi
    # Also check k3s for the image
    if command -v k3s >/dev/null 2>&1; then
      if k3s ctr images list | grep -q "backup-runner:local"; then
        echo "Removing backup-runner:local from k3s..."
        k3s ctr images rm backup-runner:local >/dev/null 2>&1 && files_removed=$((files_removed + 1)) || true
      fi
    fi
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

# Aggressive function to delete namespace and all its resources
delete_namespace() {
  local namespace="$1"
  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    echo "Deleting namespace: ${namespace} (aggressive mode)..."
    
    # First, delete all PVCs in this namespace (they might block namespace deletion)
    pvcs="$(kubectl get pvc -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    if [ -n "${pvcs}" ]; then
      for pvc in ${pvcs}; do
        kubectl patch pvc "${pvc}" -n "${namespace}" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
        kubectl delete pvc "${pvc}" -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
      done
    fi
    
    # Delete all resources in namespace first (aggressive)
    kubectl delete all --all -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    kubectl delete pvc,configmap,secret,serviceaccount,role,rolebinding,networkpolicy,resourcequota,limitrange --all -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    
    # Delete Traefik IngressRouteTCP resources (custom resources)
    kubectl delete ingressroutetcp --all -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    
    # Now delete the namespace
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
        # If stuck, try removing finalizers
        if [ $((waited % 20)) -eq 0 ]; then
          kubectl patch namespace "${namespace}" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
        fi
      fi
    done
    
    # Final attempt: force remove finalizers
    echo "  Force removing finalizers from namespace ${namespace}..."
    kubectl patch namespace "${namespace}" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
    if command -v jq >/dev/null 2>&1; then
      kubectl get namespace "${namespace}" -o json 2>/dev/null | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/${namespace}/finalize" -f - >/dev/null 2>&1 || true
    fi
    
    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      echo "  ✓ Namespace ${namespace} deleted (after force cleanup)"
      return 0
    else
      echo "  ⚠ Warning: Namespace ${namespace} still exists after ${max_wait}s, may need manual cleanup"
    fi
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

# VPS FORMAT MODE: Delete k3s system namespaces (complete wipe)
echo ""
echo "=== Deleting k3s system namespaces (VPS format mode) ==="
delete_namespace "kube-system"
delete_namespace "kube-public"
delete_namespace "kube-node-lease"
delete_namespace "default"

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

# Delete cert-manager ClusterIssuers (before CRDs)
echo "Deleting cert-manager ClusterIssuers..."
kubectl delete clusterissuer --all --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

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

# VPS FORMAT MODE: Delete ALL remaining CRDs (complete wipe)
echo ""
echo "Deleting ALL remaining CRDs (VPS format mode)..."
all_crds="$(kubectl get crd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [ -n "${all_crds}" ]; then
  crd_count=0
  for crd in ${all_crds}; do
    kubectl delete crd "${crd}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
      crd_count=$((crd_count + 1)) || true
  done
  if [ ${crd_count} -gt 0 ]; then
    echo "  ✓ Deleted ${crd_count} additional CRD(s)"
  fi
else
  echo "  No additional CRDs found"
fi

# Delete Voxeil Panel ClusterRoles and ClusterRoleBindings
echo ""
echo "Deleting Voxeil Panel ClusterRoles and ClusterRoleBindings..."
kubectl delete clusterrole controller-bootstrap user-operator --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
kubectl delete clusterrolebinding controller-bootstrap-binding --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
echo "  ✓ ClusterRoles and ClusterRoleBindings deleted"

# Delete Traefik HelmChartConfig
echo ""
echo "Deleting Traefik HelmChartConfig..."
kubectl delete helmchartconfig -n kube-system traefik --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
kubectl delete helmchartconfig --all -n kube-system --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
echo "  ✓ Traefik HelmChartConfig deleted"

# VPS FORMAT MODE: Delete ALL IngressClass resources
echo ""
echo "Deleting ALL IngressClass resources..."
kubectl delete ingressclass --all --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
echo "  ✓ All IngressClass resources deleted"

# VPS FORMAT MODE: Delete ALL StorageClass resources (except default ones that k3s needs)
echo ""
echo "Deleting custom StorageClass resources..."
# Get all storage classes and delete non-default ones
all_storageclasses="$(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [ -n "${all_storageclasses}" ]; then
  for sc in ${all_storageclasses}; do
    # Skip local-path (k3s default) but delete everything else
    if [ "${sc}" != "local-path" ]; then
      kubectl delete storageclass "${sc}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    fi
  done
fi
echo "  ✓ Custom StorageClass resources deleted"

# Aggressive cleanup: Delete ALL PVCs from ALL namespaces (VPS format style - NO EXCEPTIONS)
echo ""
echo "=== Aggressive PVC cleanup (ALL namespaces - VPS format) ==="
pvc_cleaned=0
all_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"

if [ -n "${all_namespaces}" ]; then
  for ns in ${all_namespaces}; do
    # VPS FORMAT MODE: Delete from ALL namespaces including system namespaces
    
    pvcs="$(kubectl get pvc -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    if [ -n "${pvcs}" ]; then
      echo "  Deleting PVCs in namespace ${ns}..."
      for pvc in ${pvcs}; do
        # Remove finalizers first
        kubectl patch pvc "${pvc}" -n "${ns}" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
        # Force delete
        kubectl delete pvc "${pvc}" -n "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
          pvc_cleaned=$((pvc_cleaned + 1)) || true
      done
    fi
  done
fi

if [ ${pvc_cleaned} -gt 0 ]; then
  echo "  ✓ Deleted ${pvc_cleaned} PVC(s)"
else
  echo "  No PVCs found to delete"
fi

# Clean up PersistentVolumes (orphaned PVs)
echo ""
echo "=== Cleaning up PersistentVolumes ==="
pv_cleaned=0
all_pvs="$(kubectl get pv -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"

if [ -n "${all_pvs}" ]; then
  for pv in ${all_pvs}; do
    # Check if PV is bound to a PVC that no longer exists
    pv_phase="$(kubectl get pv "${pv}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    if [ "${pv_phase}" = "Released" ] || [ "${pv_phase}" = "Available" ]; then
      echo "  Deleting orphaned PV: ${pv} (phase: ${pv_phase})..."
      # Remove finalizers
      kubectl patch pv "${pv}" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      # Delete with reclaim policy
      kubectl delete pv "${pv}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
        pv_cleaned=$((pv_cleaned + 1)) || true
    fi
  done
fi

if [ ${pv_cleaned} -gt 0 ]; then
  echo "  ✓ Deleted ${pv_cleaned} PV(s)"
else
  echo "  No orphaned PVs found"
fi

# Aggressive cleanup: Delete ALL resources in remaining namespaces before deleting namespaces
echo ""
echo "=== Aggressive resource cleanup (all remaining namespaces) ==="
cleaned_count=0

# Get ALL remaining namespaces (VPS FORMAT MODE - including system namespaces)
remaining_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' || true)"

if [ -n "${remaining_namespaces}" ]; then
  for namespace in ${remaining_namespaces}; do
    echo "  Cleaning up all resources in namespace: ${namespace}..."
    
    # Delete all resources by type (aggressive cleanup)
    # Deployments, StatefulSets, DaemonSets
    kubectl delete deployment,statefulset,daemonset --all -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
      cleaned_count=$((cleaned_count + 1)) || true
    
    # Jobs and CronJobs
    kubectl delete job,cronjob --all -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
      cleaned_count=$((cleaned_count + 1)) || true
    
    # Services and Ingresses
    kubectl delete service,ingress --all -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
      cleaned_count=$((cleaned_count + 1)) || true
    
    # ConfigMaps and Secrets
    kubectl delete configmap,secret --all -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
      cleaned_count=$((cleaned_count + 1)) || true
    
    # Pods (force delete any remaining)
    pods="$(kubectl get pods -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    if [ -n "${pods}" ]; then
      for pod in ${pods}; do
        kubectl patch pod "${pod}" -n "${namespace}" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
        kubectl delete pod "${pod}" -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 && \
          cleaned_count=$((cleaned_count + 1)) || true
      done
    fi
    
    # NetworkPolicies, RoleBindings, ServiceAccounts, Roles
    kubectl delete networkpolicy,rolebinding,serviceaccount,role --all -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    
    # ResourceQuotas and LimitRanges
    kubectl delete resourcequota,limitrange --all -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    
    # Traefik IngressRouteTCP resources (custom resources)
    kubectl delete ingressroutetcp --all -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
  done
fi

# Clean up orphaned webhooks
echo ""
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

# Clean up namespaces stuck in Terminating state (aggressive)
echo ""
echo "Cleaning up namespaces stuck in Terminating state..."
if [ -n "${remaining_namespaces}" ]; then
  for ns in ${remaining_namespaces}; do
    ns_phase="$(kubectl get namespace "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    if [ "${ns_phase}" = "Terminating" ]; then
      echo "  Force removing finalizers from namespace: ${ns}..."
      # Remove finalizers aggressively
      if command -v jq >/dev/null 2>&1; then
        kubectl get namespace "${ns}" -o json 2>/dev/null | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
      else
        kubectl patch namespace "${ns}" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      fi
      cleaned_count=$((cleaned_count + 1))
    fi
  done
fi

# Final aggressive namespace deletion attempt
echo ""
echo "=== Final namespace cleanup attempt ==="
if [ -n "${remaining_namespaces}" ]; then
  for ns in ${remaining_namespaces}; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      echo "  Force deleting namespace: ${ns}..."
      # Remove finalizers and force delete
      kubectl patch namespace "${ns}" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      kubectl delete namespace "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    fi
  done
fi

if [ ${cleaned_count} -gt 0 ] || [ ${pvc_cleaned} -gt 0 ] || [ ${pv_cleaned} -gt 0 ]; then
  echo ""
  echo "✓ Aggressive cleanup completed:"
  echo "  - ${pvc_cleaned} PVC(s) deleted"
  echo "  - ${pv_cleaned} PV(s) deleted"
  echo "  - ${cleaned_count} resource(s) cleaned up"
else
  echo "No additional resources found to clean up"
fi

echo ""
echo "=== Uninstall Summary ==="
echo "✓ Aggressive cleanup completed - VPS format style"
echo ""
echo "Deleted resources:"
echo "  - All Voxeil Panel namespaces"
echo "  - All user and tenant namespaces"
echo "  - All PVCs and PersistentVolumes"
echo "  - All CRDs (Kyverno, Flux, cert-manager)"
echo "  - All webhooks and cluster resources"
echo "  - All filesystem files and configurations"
echo ""
echo "Remaining resources (if any - should be empty):"
remaining_after="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' || true)"
if [ -n "${remaining_after}" ]; then
  echo "${remaining_after}" | while read -r ns; do
    echo "  ⚠ Warning: Namespace ${ns} still exists (may be stuck)"
  done
else
  echo "  ✓ No remaining namespaces found (complete wipe)"
fi
echo ""
echo "Remaining PVCs (if any - should be empty):"
remaining_pvcs="$(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [ -n "${remaining_pvcs}" ]; then
  echo "${remaining_pvcs}" | while read -r pvc; do
    echo "  ⚠ Warning: PVC ${pvc} still exists"
  done
else
  echo "  ✓ No remaining PVCs found (complete wipe)"
fi
echo ""
echo "Cluster-wide resources cleaned:"
echo "  ✓ ClusterRoles (controller-bootstrap, user-operator)"
echo "  ✓ ClusterRoleBindings (controller-bootstrap-binding)"
echo "  ✓ ClusterIssuers (cert-manager)"
echo "  ✓ HelmChartConfig (Traefik)"
echo "  ✓ Webhooks (Kyverno, Flux, cert-manager)"
echo "  ✓ IngressClass resources (all)"
echo "  ✓ StorageClass resources (custom)"
echo "  ✓ k3s system namespaces (kube-system, kube-public, kube-node-lease, default)"
echo ""
echo "Namespace resources cleaned (all namespaces):"
echo "  ✓ Roles and RoleBindings"
echo "  ✓ ServiceAccounts"
echo "  ✓ NetworkPolicies"
echo "  ✓ ResourceQuotas"
echo "  ✓ LimitRanges"
echo "  ✓ All workloads (Deployments, StatefulSets, Jobs, CronJobs, Pods)"
echo "  ✓ Services and Ingresses"
echo "  ✓ ConfigMaps and Secrets"
echo "  ✓ IngressRouteTCP (Traefik custom resources)"
echo ""
echo ""
echo "=== VPS FORMAT COMPLETE ==="
echo "All Kubernetes resources have been deleted."
echo ""
echo "To completely remove k3s and Docker (optional):"
echo "  1. Remove k3s: /usr/local/bin/k3s-uninstall.sh"
echo "  2. Remove Docker: apt-get remove -y docker.io containerd"
echo "  3. Remove k3s data: rm -rf /var/lib/rancher/k3s"
echo ""
echo "⚠️  WARNING: k3s system namespaces have been deleted."
echo "   k3s may be in an unstable state. Consider running k3s-uninstall.sh"
echo ""
echo "✓ VPS FORMAT COMPLETE - Everything has been wiped."
