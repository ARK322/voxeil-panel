#!/usr/bin/env bash
set -euo pipefail

# ========= State Registry =========
STATE_FILE="/var/lib/voxeil/install.state"

# Read state flag
read_state_flag() {
  local flag="$1"
  if [ -f "${STATE_FILE}" ]; then
    grep "^${flag}=" "${STATE_FILE}" 2>/dev/null | cut -d'=' -f2 || echo "0"
  else
    echo "0"
  fi
}

# Check if component is installed
is_installed() {
  local flag="$1"
  [ "$(read_state_flag "${flag}")" = "1" ]
}

# ========= Command-line arguments =========
DRY_RUN=false
FORCE=false
DOCTOR=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --doctor)
      DOCTOR=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--dry-run] [--force] [--doctor]"
      exit 1
      ;;
  esac
done

# ========= Doctor mode =========
if [ "${DOCTOR}" = "true" ]; then
  echo "=== Voxeil Panel Uninstaller - Doctor Mode ==="
  echo ""
  echo "Scanning for leftover resources..."
  echo ""
  
  EXIT_CODE=0
  
  # Check for leftover namespaces
  echo "Checking namespaces..."
  VOXEIL_NAMESPACES="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^(platform|infra-db|dns-zone|mail-zone|backup-system|kyverno|flux-system|cert-manager|user-|tenant-)' || true)"
  if [ -n "${VOXEIL_NAMESPACES}" ]; then
    echo "  ⚠ Found Voxeil namespaces:"
    echo "${VOXEIL_NAMESPACES}" | while read -r ns; do
      echo "    - ${ns}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil namespaces found"
  fi
  
  # Check for leftover CRDs
  echo ""
  echo "Checking CRDs..."
  VOXEIL_CRDS="$(kubectl get crd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '(cert-manager|kyverno|flux)' || true)"
  if [ -n "${VOXEIL_CRDS}" ]; then
    echo "  ⚠ Found Voxeil CRDs:"
    echo "${VOXEIL_CRDS}" | while read -r crd; do
      echo "    - ${crd}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil CRDs found"
  fi
  
  # Check for leftover ClusterRoles
  echo ""
  echo "Checking ClusterRoles..."
  VOXEIL_CLUSTERROLES="$(kubectl get clusterrole -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '(controller-bootstrap|user-operator)' || true)"
  if [ -n "${VOXEIL_CLUSTERROLES}" ]; then
    echo "  ⚠ Found Voxeil ClusterRoles:"
    echo "${VOXEIL_CLUSTERROLES}" | while read -r cr; do
      echo "    - ${cr}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil ClusterRoles found"
  fi
  
  # Check for leftover ClusterRoleBindings
  echo ""
  echo "Checking ClusterRoleBindings..."
  VOXEIL_CLUSTERROLEBINDINGS="$(kubectl get clusterrolebinding -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E 'controller-bootstrap-binding' || true)"
  if [ -n "${VOXEIL_CLUSTERROLEBINDINGS}" ]; then
    echo "  ⚠ Found Voxeil ClusterRoleBindings:"
    echo "${VOXEIL_CLUSTERROLEBINDINGS}" | while read -r crb; do
      echo "    - ${crb}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil ClusterRoleBindings found"
  fi
  
  # Check for leftover webhooks
  echo ""
  echo "Checking webhooks..."
  VOXEIL_WEBHOOKS="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE '(kyverno|cert-manager|flux)' || true)"
  if [ -n "${VOXEIL_WEBHOOKS}" ]; then
    echo "  ⚠ Found Voxeil webhooks:"
    echo "${VOXEIL_WEBHOOKS}" | while read -r wh; do
      echo "    - ${wh}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil webhooks found"
  fi
  
  # Check for leftover PVCs
  echo ""
  echo "Checking PVCs..."
  VOXEIL_PVCS="$(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '^(platform|infra-db|dns-zone|mail-zone|backup-system|user-|tenant-)/' || true)"
  if [ -n "${VOXEIL_PVCS}" ]; then
    echo "  ⚠ Found Voxeil PVCs:"
    echo "${VOXEIL_PVCS}" | while read -r pvc; do
      echo "    - ${pvc}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil PVCs found"
  fi
  
  # Check for leftover filesystem files
  echo ""
  echo "Checking filesystem files..."
  FILES_FOUND=0
  if [ -d /etc/voxeil ]; then
    echo "  ⚠ Found /etc/voxeil directory"
    FILES_FOUND=1
  fi
  if [ -f /usr/local/bin/voxeil-ufw-apply ]; then
    echo "  ⚠ Found /usr/local/bin/voxeil-ufw-apply"
    FILES_FOUND=1
  fi
  if [ -f /var/lib/voxeil/install.state ]; then
    echo "  ⚠ Found /var/lib/voxeil/install.state"
    FILES_FOUND=1
  fi
  if [ ${FILES_FOUND} -eq 0 ]; then
    echo "  ✓ No Voxeil filesystem files found"
  else
    EXIT_CODE=1
  fi
  
  echo ""
  if [ ${EXIT_CODE} -eq 0 ]; then
    echo "✓ System is clean - no Voxeil resources found"
  else
    echo "⚠ System has leftover Voxeil resources"
  fi
  
  exit ${EXIT_CODE}
fi

# ========= Main uninstaller =========
echo "== Voxeil Panel Uninstaller =="
echo ""

# Check if state file exists
if [ ! -f "${STATE_FILE}" ]; then
  echo "⚠ Warning: State file not found at ${STATE_FILE}"
  echo "  This may indicate a partial installation or manual cleanup."
  echo "  Proceeding with uninstall based on detected resources..."
  echo ""
fi

# Confirmation (unless --force)
if [ "${FORCE}" != "true" ] && [ "${DRY_RUN}" != "true" ]; then
  echo "This will remove all Voxeil Panel components."
  echo "Press Enter to continue or Ctrl+C to cancel..."
  read -r
fi

# Dry run mode
if [ "${DRY_RUN}" = "true" ]; then
  echo "=== DRY RUN MODE - No changes will be made ==="
  echo ""
fi

# Helper to execute or print command
execute_or_print() {
  local cmd="$1"
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY RUN] ${cmd}"
  else
    eval "${cmd}"
  fi
}

# Delete namespace and wait for termination
delete_namespace() {
  local namespace="$1"
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    echo "  Namespace ${namespace} does not exist, skipping"
    return 0
  fi
  
  echo "  Deleting namespace: ${namespace}..."
  
  # Delete all PVCs first
  pvcs="$(kubectl get pvc -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pvcs}" ]; then
    for pvc in ${pvcs}; do
      execute_or_print "kubectl patch pvc \"${pvc}\" -n \"${namespace}\" -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge >/dev/null 2>&1 || true"
      execute_or_print "kubectl delete pvc \"${pvc}\" -n \"${namespace}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
  fi
  
  # Delete all resources
  execute_or_print "kubectl delete all --all -n \"${namespace}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  execute_or_print "kubectl delete pvc,configmap,secret,serviceaccount,role,rolebinding,networkpolicy,resourcequota,limitrange --all -n \"${namespace}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Delete namespace
  execute_or_print "kubectl delete namespace \"${namespace}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Wait for namespace deletion (if not dry run)
  if [ "${DRY_RUN}" != "true" ]; then
    local max_wait=60
    local waited=0
    while [ ${waited} -lt ${max_wait} ]; do
      if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        echo "    ✓ Namespace ${namespace} deleted"
        return 0
      fi
      sleep 1
      waited=$((waited + 1))
      if [ $((waited % 10)) -eq 0 ]; then
        echo "    Waiting for namespace ${namespace} to be deleted... (${waited}/${max_wait}s)"
        if [ $((waited % 20)) -eq 0 ]; then
          execute_or_print "kubectl patch namespace \"${namespace}\" -p '{\"spec\":{\"finalizers\":[]}}' --type=merge >/dev/null 2>&1 || true"
        fi
      fi
    done
    
    # Force remove finalizers
    execute_or_print "kubectl patch namespace \"${namespace}\" -p '{\"spec\":{\"finalizers\":[]}}' --type=merge >/dev/null 2>&1 || true"
  fi
}

# Check kubectl availability
if ! command -v kubectl >/dev/null 2>&1 || ! kubectl cluster-info >/dev/null 2>&1; then
  echo "⚠ kubectl not available or cluster not accessible"
  echo "  Proceeding with filesystem cleanup only..."
  KUBECTL_AVAILABLE=false
else
  KUBECTL_AVAILABLE=true
fi

# ========= Deletion Order (Reverse of Installation) =========

if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  # 1. Delete workloads and namespace-scoped resources (handled by namespace deletion)
  echo "=== Step 1: Deleting namespace-scoped resources ==="
  
  # Delete Voxeil Panel namespaces
  delete_namespace "platform"
  delete_namespace "infra-db"
  delete_namespace "dns-zone"
  delete_namespace "mail-zone"
  delete_namespace "backup-system"
  
  # Delete user and tenant namespaces
  echo ""
  echo "=== Deleting user namespaces ==="
  user_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^user-' || true)"
  if [ -n "${user_namespaces}" ]; then
    for ns in ${user_namespaces}; do
      delete_namespace "${ns}"
    done
  fi
  
  echo ""
  echo "=== Deleting tenant namespaces ==="
  tenant_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^tenant-' || true)"
  if [ -n "${tenant_namespaces}" ]; then
    for ns in ${tenant_namespaces}; do
      delete_namespace "${ns}"
    done
  fi
  
  # 2. Delete webhooks
  echo ""
  echo "=== Step 2: Deleting webhooks ==="
  if is_installed "KYVERNO_INSTALLED" || kubectl get namespace kyverno >/dev/null 2>&1; then
    echo "  Deleting Kyverno webhooks..."
    orphaned_webhooks="$(kubectl get validatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i kyverno || true)"
    orphaned_mutating="$(kubectl get mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i kyverno || true)"
    for webhook in ${orphaned_webhooks}; do
      execute_or_print "kubectl delete validatingwebhookconfiguration \"${webhook}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
    for webhook in ${orphaned_mutating}; do
      execute_or_print "kubectl delete mutatingwebhookconfiguration \"${webhook}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
  fi
  
  if is_installed "CERT_MANAGER_INSTALLED" || kubectl get namespace cert-manager >/dev/null 2>&1; then
    echo "  Deleting cert-manager webhooks..."
    cert_webhooks="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i cert-manager || true)"
    for webhook in ${cert_webhooks}; do
      execute_or_print "kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \"${webhook}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
  fi
  
  # 3. Delete cluster-wide resources
  echo ""
  echo "=== Step 3: Deleting cluster-wide resources ==="
  
  # ClusterIssuers
  if is_installed "CERT_MANAGER_INSTALLED"; then
    echo "  Deleting ClusterIssuers..."
    execute_or_print "kubectl delete clusterissuer --all --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  # ClusterRoles and ClusterRoleBindings
  echo "  Deleting ClusterRoles and ClusterRoleBindings..."
  execute_or_print "kubectl delete clusterrole controller-bootstrap user-operator --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  execute_or_print "kubectl delete clusterrolebinding controller-bootstrap-binding --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # HelmChartConfig
  echo "  Deleting HelmChartConfig..."
  execute_or_print "kubectl delete helmchartconfig traefik -n kube-system --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Kyverno and Flux namespaces
  if is_installed "KYVERNO_INSTALLED" || kubectl get namespace kyverno >/dev/null 2>&1; then
    delete_namespace "kyverno"
  fi
  
  if is_installed "FLUX_INSTALLED" || kubectl get namespace flux-system >/dev/null 2>&1; then
    delete_namespace "flux-system"
  fi
  
  if is_installed "CERT_MANAGER_INSTALLED" || kubectl get namespace cert-manager >/dev/null 2>&1; then
    delete_namespace "cert-manager"
  fi
  
  # 4. Delete CRDs (last)
  echo ""
  echo "=== Step 4: Deleting CRDs ==="
  
  if is_installed "CERT_MANAGER_INSTALLED"; then
    echo "  Deleting cert-manager CRDs..."
    execute_or_print "kubectl delete crd -l app.kubernetes.io/name=cert-manager --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    execute_or_print "kubectl delete crd certificates.cert-manager.io certificaterequests.cert-manager.io challenges.acme.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io orders.acme.cert-manager.io --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  if is_installed "KYVERNO_INSTALLED"; then
    echo "  Deleting Kyverno CRDs..."
    execute_or_print "kubectl delete crd -l app.kubernetes.io/name=kyverno --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    execute_or_print "kubectl delete crd policies.kyverno.io clusterpolicies.kyverno.io policyreports.wgpolicyk8s.io clusterpolicyreports.wgpolicyk8s.io --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  if is_installed "FLUX_INSTALLED"; then
    echo "  Deleting Flux CRDs..."
    execute_or_print "kubectl delete crd -l app.kubernetes.io/name=flux --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
fi

# 5. Delete filesystem files
echo ""
echo "=== Step 5: Deleting filesystem files ==="
execute_or_print "rm -rf /etc/voxeil 2>/dev/null || true"
execute_or_print "rm -f /usr/local/bin/voxeil-ufw-apply 2>/dev/null || true"
execute_or_print "rm -f /etc/systemd/system/voxeil-ufw-apply.service 2>/dev/null || true"
execute_or_print "rm -f /etc/systemd/system/voxeil-ufw-apply.path 2>/dev/null || true"
execute_or_print "rm -f /etc/fail2ban/jail.d/voxeil.conf 2>/dev/null || true"
execute_or_print "rm -f /etc/ssh/sshd_config.voxeil-backup.* 2>/dev/null || true"
execute_or_print "rm -rf /var/lib/voxeil 2>/dev/null || true"

if [ "${DRY_RUN}" != "true" ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload 2>/dev/null || true
fi

# 6. Delete k3s (if installed)
if is_installed "K3S_INSTALLED"; then
  echo ""
  echo "=== Step 6: Removing k3s ==="
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY RUN] Would remove k3s"
  else
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop k3s 2>/dev/null || true
      systemctl disable k3s 2>/dev/null || true
    fi
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
      /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 || true
    fi
    rm -f /usr/local/bin/k3s /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr 2>/dev/null || true
    rm -rf /var/lib/rancher/k3s /etc/rancher/k3s /var/log/k3s 2>/dev/null || true
    rm -f /etc/systemd/system/k3s.service 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload 2>/dev/null || true
    fi
  fi
fi

echo ""
echo "=== Uninstall Complete ==="
if [ "${DRY_RUN}" = "true" ]; then
  echo "  (Dry run - no changes were made)"
else
  echo "  ✓ All Voxeil Panel components removed"
fi
