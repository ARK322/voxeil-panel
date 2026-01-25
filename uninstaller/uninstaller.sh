#!/usr/bin/env bash
set -euo pipefail

# ========= State Registry =========
STATE_FILE="/var/lib/voxeil/install.state"

# Ensure state directory exists
ensure_state_dir() {
  mkdir -p "$(dirname "${STATE_FILE}")"
}

# Set state key=value
state_set() {
  local key="$1"
  local value="$2"
  ensure_state_dir
  if [ ! -f "${STATE_FILE}" ]; then
    touch "${STATE_FILE}"
    chmod 644 "${STATE_FILE}"
  fi
  if ! grep -q "^${key}=" "${STATE_FILE}" 2>/dev/null; then
    echo "${key}=${value}" >> "${STATE_FILE}"
  else
    if command -v sed >/dev/null 2>&1; then
      sed -i "s/^${key}=.*/${key}=${value}/" "${STATE_FILE}"
    else
      # Fallback if sed -i not available
      local temp_file
      temp_file="$(mktemp)"
      grep -v "^${key}=" "${STATE_FILE}" > "${temp_file}" 2>/dev/null || true
      echo "${key}=${value}" >> "${temp_file}"
      mv "${temp_file}" "${STATE_FILE}"
    fi
  fi
}

# Get state key with default
state_get() {
  local key="$1"
  local default="${2:-0}"
  if [ -f "${STATE_FILE}" ]; then
    grep "^${key}=" "${STATE_FILE}" 2>/dev/null | cut -d'=' -f2- || echo "${default}"
  else
    echo "${default}"
  fi
}

# Load state file safely (source if exists)
state_load() {
  if [ -f "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    set +u
    source "${STATE_FILE}" 2>/dev/null || true
    set -u
  fi
}

# Read state flag (backward compatibility)
read_state_flag() {
  state_get "$1" "0"
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
  echo "Scanning for installed components and leftover resources..."
  echo ""
  
  EXIT_CODE=0
  
  # Check state file
  echo "=== State Registry ==="
  if [ -f "${STATE_FILE}" ]; then
    echo "State file found at ${STATE_FILE}:"
    cat "${STATE_FILE}" | sed 's/^/  /'
    echo ""
  else
    echo "  ⚠ No state file found"
    EXIT_CODE=1
    echo ""
  fi
  
  # Check kubectl availability
  if ! command -v kubectl >/dev/null 2>&1 || ! kubectl cluster-info >/dev/null 2>&1; then
    echo "⚠ kubectl not available or cluster not accessible"
    echo "  Skipping Kubernetes resource checks"
    echo ""
    exit ${EXIT_CODE}
  fi
  
  # Check labeled resources
  echo "=== Resources with app.kubernetes.io/part-of=voxeil ==="
  
  echo "Namespaces:"
  VOXEIL_NS="$(kubectl get namespaces -l app.kubernetes.io/part-of=voxeil -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' || true)"
  if [ -n "${VOXEIL_NS}" ]; then
    echo "${VOXEIL_NS}" | while read -r ns; do
      echo "  - ${ns}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "All resources (pods, services, etc.):"
  VOXEIL_ALL="$(kubectl get all -A -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_ALL}" -gt 0 ]; then
    kubectl get all -A -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "ConfigMaps, Secrets, ServiceAccounts, Roles, RoleBindings, Ingresses, NetworkPolicies:"
  VOXEIL_OTHER="$(kubectl get cm,secret,sa,role,rolebinding,ingress,networkpolicy -A -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_OTHER}" -gt 0 ]; then
    kubectl get cm,secret,sa,role,rolebinding,ingress,networkpolicy -A -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "ClusterRoles and ClusterRoleBindings:"
  VOXEIL_CLUSTER="$(kubectl get clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_CLUSTER}" -gt 0 ]; then
    kubectl get clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "Webhooks:"
  VOXEIL_WEBHOOKS="$(kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_WEBHOOKS}" -gt 0 ]; then
    kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "CRDs:"
  VOXEIL_CRDS="$(kubectl get crd -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_CRDS}" -gt 0 ]; then
    kubectl get crd -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  echo ""
  echo "PVCs:"
  VOXEIL_PVCS="$(kubectl get pvc -A -l app.kubernetes.io/part-of=voxeil --no-headers 2>/dev/null | wc -l || echo "0")"
  if [ "${VOXEIL_PVCS}" -gt 0 ]; then
    kubectl get pvc -A -l app.kubernetes.io/part-of=voxeil 2>/dev/null || true
    EXIT_CODE=1
  else
    echo "  ✓ None found"
  fi
  
  # Check for unlabeled namespaces that might be voxeil-related
  echo ""
  echo "=== Unlabeled Namespaces (potential leftovers) ==="
  UNLABELED_NS="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^(platform|infra-db|dns-zone|mail-zone|backup-system|kyverno|flux-system|cert-manager|user-|tenant-)' || true)"
  if [ -n "${UNLABELED_NS}" ]; then
    echo "${UNLABELED_NS}" | while read -r ns; do
      if ! kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -q voxeil; then
        echo "  ⚠ ${ns} (not labeled)"
        EXIT_CODE=1
      fi
    done
  else
    echo "  ✓ None found"
  fi
  
  # Check PVs tied to voxeil namespaces
  echo ""
  echo "=== PersistentVolumes (checking claimRef) ==="
  VOXEIL_PVS=0
  for ns in platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      if command -v python3 >/dev/null 2>&1; then
        PVS="$(kubectl get pv -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); [print(pv['metadata']['name']) for pv in data.get('items', []) if pv.get('spec', {}).get('claimRef', {}).get('namespace') == '${ns}']" 2>/dev/null || true)"
      elif command -v jq >/dev/null 2>&1; then
        PVS="$(kubectl get pv -o json 2>/dev/null | jq -r '.items[] | select(.spec.claimRef.namespace == "'${ns}'") | .metadata.name' 2>/dev/null || true)"
      else
        PVS="$(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null | grep -E "^[^\t]+\t${ns}$" | cut -f1 || true)"
      fi
      if [ -n "${PVS}" ]; then
        echo "  ⚠ PVs for namespace ${ns}:"
        echo "${PVS}" | while read -r pv; do
          echo "    - ${pv}"
        done
        VOXEIL_PVS=1
        EXIT_CODE=1
      fi
    fi
  done
  if [ ${VOXEIL_PVS} -eq 0 ]; then
    echo "  ✓ None found"
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

# Load state
state_load

# Check if state file exists
if [ ! -f "${STATE_FILE}" ]; then
  echo "⚠ Warning: State file not found at ${STATE_FILE}"
  echo "  This may indicate a partial installation or manual cleanup."
  if [ "${FORCE}" != "true" ]; then
    echo "  Use --force to proceed with cleanup based on detected resources."
    echo ""
    exit 1
  fi
  echo "  Proceeding with uninstall based on detected resources (--force)..."
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

# Run wrapper for dry-run support
run() {
  local cmd="$1"
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY-RUN] ${cmd}"
  else
    eval "${cmd}"
  fi
}

# Helper to execute or print command (backward compatibility)
execute_or_print() {
  run "$1"
}

# Disable Kyverno webhooks to prevent API lock
disable_kyverno_webhooks() {
  echo "=== Preflight: Disabling Kyverno webhooks to prevent API lock ==="
  # delete labeled first
  kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
    -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true >/dev/null 2>&1 || true

  # delete by name patterns (backward compatibility)
  kubectl get validatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -i '^kyverno-' | xargs -r kubectl delete validatingwebhookconfiguration --ignore-not-found >/dev/null 2>&1 || true

  kubectl get mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -i '^kyverno-' | xargs -r kubectl delete mutatingwebhookconfiguration --ignore-not-found >/dev/null 2>&1 || true
}

# Wait for namespace deletion with timeout
wait_ns_deleted() {
  local namespace="$1"
  local timeout="${2:-300}"
  local waited=0
  
  if [ "${DRY_RUN}" = "true" ]; then
    return 0
  fi
  
  while [ ${waited} -lt ${timeout} ]; do
    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      echo "    ✓ Namespace ${namespace} deleted"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
    if [ $((waited % 10)) -eq 0 ]; then
      echo "    Waiting for namespace ${namespace} to be deleted... (${waited}/${timeout}s)"
    fi
    # Force remove finalizers if stuck
    if [ $((waited % 30)) -eq 0 ] && [ ${waited} -gt 0 ]; then
      echo "    Attempting to force remove finalizers..."
      # Try kubectl patch first
      kubectl patch namespace "${namespace}" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      # If that doesn't work, use raw API
      if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        # Use python or jq to patch JSON if available
        if command -v python3 >/dev/null 2>&1; then
          kubectl get namespace "${namespace}" -o json | python3 -c "import sys, json; data=json.load(sys.stdin); data['spec']['finalizers']=[]; print(json.dumps(data))" | kubectl replace --raw "/api/v1/namespaces/${namespace}/finalize" -f - >/dev/null 2>&1 || true
        elif command -v jq >/dev/null 2>&1; then
          kubectl get namespace "${namespace}" -o json | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/${namespace}/finalize" -f - >/dev/null 2>&1 || true
        fi
      fi
    fi
  done
  
  echo "    ⚠ Namespace ${namespace} still exists after ${timeout}s, forcing deletion..."
  # Final attempt to force remove finalizers
  if command -v python3 >/dev/null 2>&1; then
    kubectl get namespace "${namespace}" -o json | python3 -c "import sys, json; data=json.load(sys.stdin); data['spec']['finalizers']=[]; print(json.dumps(data))" | kubectl replace --raw "/api/v1/namespaces/${namespace}/finalize" -f - >/dev/null 2>&1 || true
  elif command -v jq >/dev/null 2>&1; then
    kubectl get namespace "${namespace}" -o json | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/${namespace}/finalize" -f - >/dev/null 2>&1 || true
  else
    kubectl patch namespace "${namespace}" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
  fi
  return 1
}

# Delete namespace and wait for termination
delete_namespace() {
  local namespace="$1"
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    echo "  Namespace ${namespace} does not exist, skipping"
    return 0
  fi
  
  echo "  Deleting namespace: ${namespace}..."
  
  # Delete all PVCs first (they block namespace deletion)
  pvcs="$(kubectl get pvc -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pvcs}" ]; then
    for pvc in ${pvcs}; do
      run "kubectl patch pvc \"${pvc}\" -n \"${namespace}\" -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge >/dev/null 2>&1 || true"
      run "kubectl delete pvc \"${pvc}\" -n \"${namespace}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
  fi
  
  # Delete namespace (capture stderr to detect webhook failures)
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY-RUN] kubectl delete namespace \"${namespace}\" --ignore-not-found=true --grace-period=0 --force"
  else
    err="$(kubectl delete namespace "${namespace}" --ignore-not-found=true --grace-period=0 --force 2>&1 || true)"
    if echo "${err}" | grep -qiE 'failed calling webhook.*kyverno|kyverno-svc|context deadline exceeded'; then
      echo "    ⚠ Detected Kyverno webhook blockage, disabling Kyverno webhooks and retrying namespace delete..."
      disable_kyverno_webhooks
      kubectl delete namespace "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    fi
  fi
  
  # Wait for namespace deletion
  wait_ns_deleted "${namespace}" 300
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
  # Preflight: Disable Kyverno webhooks BEFORE any deletions to prevent API lock
  if [ "${FORCE}" = "true" ] || is_installed "KYVERNO_INSTALLED" || kubectl get validatingwebhookconfigurations 2>/dev/null | grep -qi kyverno; then
    disable_kyverno_webhooks
  fi
  
  # A) Workloads first - delete all resources by label
  echo "=== Step A: Deleting workloads and namespace-scoped resources ==="
  echo "  Deleting all resources labeled app.kubernetes.io/part-of=voxeil..."
  run "kubectl delete all,cm,secret,sa,role,rolebinding,ingress,networkpolicy -A -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete PVCs explicitly
  echo "  Deleting PVCs..."
  run "kubectl delete pvc -A -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # B) Namespaces next (reverse order), and WAIT
  echo ""
  echo "=== Step B: Deleting namespaces (reverse order) ==="
  
  # Delete user and tenant namespaces first (dynamically created)
  echo "  Deleting user namespaces..."
  user_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^user-' || true)"
  if [ -n "${user_namespaces}" ]; then
    for ns in ${user_namespaces}; do
      if [ "${FORCE}" = "true" ] || kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -q voxeil; then
        delete_namespace "${ns}"
      fi
    done
  fi
  
  echo "  Deleting tenant namespaces..."
  tenant_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^tenant-' || true)"
  if [ -n "${tenant_namespaces}" ]; then
    for ns in ${tenant_namespaces}; do
      if [ "${FORCE}" = "true" ] || kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -q voxeil; then
        delete_namespace "${ns}"
      fi
    done
  fi
  
  # Delete main namespaces (only if in state or --force)
  if [ "${FORCE}" = "true" ] || is_installed "PLATFORM_INSTALLED"; then
    delete_namespace "platform"
  fi
  if [ "${FORCE}" = "true" ] || is_installed "INFRA_DB_INSTALLED"; then
    delete_namespace "infra-db"
  fi
  if [ "${FORCE}" = "true" ] || kubectl get namespace dns-zone >/dev/null 2>&1; then
    delete_namespace "dns-zone"
  fi
  if [ "${FORCE}" = "true" ] || kubectl get namespace mail-zone >/dev/null 2>&1; then
    delete_namespace "mail-zone"
  fi
  if [ "${FORCE}" = "true" ] || is_installed "BACKUP_SYSTEM_INSTALLED"; then
    delete_namespace "backup-system"
  fi
  
  # Delete system namespaces
  if [ "${FORCE}" = "true" ] || is_installed "KYVERNO_INSTALLED"; then
    delete_namespace "kyverno"
  fi
  if [ "${FORCE}" = "true" ] || is_installed "FLUX_INSTALLED"; then
    delete_namespace "flux-system"
  fi
  if [ "${FORCE}" = "true" ] || is_installed "CERT_MANAGER_INSTALLED"; then
    delete_namespace "cert-manager"
  fi
  
  # C) Remaining webhooks (cluster-scoped) by label (cert-manager, Flux, etc.)
  # Note: Kyverno webhooks are handled in preflight to prevent API lock
  echo ""
  echo "=== Step C: Deleting remaining webhooks ==="
  run "kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete by name patterns if not labeled (backward compatibility - cert-manager, Flux, etc.)
  if [ "${FORCE}" = "true" ] || is_installed "CERT_MANAGER_INSTALLED"; then
    echo "  Deleting cert-manager webhooks (by name pattern)..."
    cert_webhooks="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i cert-manager || true)"
    for webhook in ${cert_webhooks}; do
      run "kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \"${webhook}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
  fi
  
  if [ "${FORCE}" = "true" ] || is_installed "FLUX_INSTALLED"; then
    echo "  Deleting Flux webhooks (by name pattern)..."
    flux_webhooks="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i flux || true)"
    for webhook in ${flux_webhooks}; do
      run "kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \"${webhook}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
  fi
  
  # D) ClusterRoles / ClusterRoleBindings by label
  echo ""
  echo "=== Step D: Deleting ClusterRoles and ClusterRoleBindings ==="
  run "kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete by name (backward compatibility)
  run "kubectl delete clusterrole controller-bootstrap user-operator --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  run "kubectl delete clusterrolebinding controller-bootstrap-binding --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Delete ClusterIssuers and HelmChartConfig
  if [ "${FORCE}" = "true" ] || is_installed "CERT_MANAGER_INSTALLED"; then
    echo "  Deleting ClusterIssuers..."
    run "kubectl delete clusterissuer --all --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  echo "  Deleting HelmChartConfig..."
  run "kubectl delete helmchartconfig traefik -n kube-system --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # E) CRDs LAST by label
  echo ""
  echo "=== Step E: Deleting CRDs ==="
  run "kubectl delete crd -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete by name patterns (backward compatibility)
  if [ "${FORCE}" = "true" ] || is_installed "CERT_MANAGER_INSTALLED"; then
    echo "  Deleting cert-manager CRDs (by name pattern)..."
    run "kubectl delete crd -l app.kubernetes.io/name=cert-manager --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd certificates.cert-manager.io certificaterequests.cert-manager.io challenges.acme.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io orders.acme.cert-manager.io --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  if [ "${FORCE}" = "true" ] || is_installed "KYVERNO_INSTALLED"; then
    echo "  Deleting Kyverno CRDs (by name pattern)..."
    run "kubectl delete crd -l app.kubernetes.io/name=kyverno --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd policies.kyverno.io clusterpolicies.kyverno.io policyreports.wgpolicyk8s.io clusterpolicyreports.wgpolicyk8s.io --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  if [ "${FORCE}" = "true" ] || is_installed "FLUX_INSTALLED"; then
    echo "  Deleting Flux CRDs (by name pattern)..."
    run "kubectl delete crd -l app.kubernetes.io/name=flux --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  # F) Storage cleanup - PVs
  echo ""
  echo "=== Step F: Cleaning up PersistentVolumes ==="
  # PVs might not have labels. Detect PVs whose claimRef.namespace is one of voxeil namespaces
  VOXEIL_NS_LIST="platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager"
  for ns in ${VOXEIL_NS_LIST}; do
    if [ "${FORCE}" = "true" ] || kubectl get namespace "${ns}" >/dev/null 2>&1 2>&1; then
      # Find PVs for this namespace
      if command -v python3 >/dev/null 2>&1; then
        PVS="$(kubectl get pv -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); [print(pv['metadata']['name']) for pv in data.get('items', []) if pv.get('spec', {}).get('claimRef', {}).get('namespace') == '${ns}']" 2>/dev/null || true)"
      elif command -v jq >/dev/null 2>&1; then
        PVS="$(kubectl get pv -o json 2>/dev/null | jq -r '.items[] | select(.spec.claimRef.namespace == "'${ns}'") | .metadata.name' 2>/dev/null || true)"
      else
        # Fallback: get all PVs and check claimRef manually
        PVS="$(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null | grep -E "^[^\t]+\t${ns}$" | cut -f1 || true)"
      fi
      if [ -n "${PVS}" ]; then
        echo "  Deleting PVs for namespace ${ns}..."
        for pv in ${PVS}; do
          run "kubectl delete pv \"${pv}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
        done
      fi
    fi
  done
fi

# G) k3s cleanup
if [ "${FORCE}" = "true" ] || is_installed "K3S_INSTALLED"; then
  echo ""
  echo "=== Step G: Removing k3s ==="
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

# H) Clean up filesystem files
echo ""
echo "=== Step H: Cleaning up filesystem files ==="
run "rm -rf /etc/voxeil 2>/dev/null || true"
run "rm -f /usr/local/bin/voxeil-ufw-apply 2>/dev/null || true"
run "rm -f /etc/systemd/system/voxeil-ufw-apply.service 2>/dev/null || true"
run "rm -f /etc/systemd/system/voxeil-ufw-apply.path 2>/dev/null || true"
run "rm -f /etc/fail2ban/jail.d/voxeil.conf 2>/dev/null || true"
run "rm -f /etc/ssh/sshd_config.voxeil-backup.* 2>/dev/null || true"
run "rm -rf /var/lib/voxeil 2>/dev/null || true"

if [ "${DRY_RUN}" != "true" ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload 2>/dev/null || true
fi

echo ""
echo "=== Uninstall Complete ==="
if [ "${DRY_RUN}" = "true" ]; then
  echo "  (Dry run - no changes were made)"
else
  echo "  ✓ All Voxeil Panel components removed"
fi
