#!/usr/bin/env bash
set -euo pipefail

# ========= error handling and logging =========
LAST_COMMAND=""
STEP_COUNTER=0

log_step() {
  STEP_COUNTER=$((STEP_COUNTER + 1))
  echo ""
  echo "=== [STEP] ${STEP_COUNTER}: $1 ==="
}

log_info() {
  echo "=== [INFO] $1 ==="
}

log_warn() {
  echo "=== [WARN] $1 ==="
}

log_ok() {
  echo "=== [OK]   $1 ==="
}

log_error() {
  echo "=== [ERROR] $1 ===" >&2
}

# Trap to log failed commands
trap 'LAST_COMMAND="${BASH_COMMAND}"; LAST_LINE="${LINENO}"' DEBUG
trap 'if [ $? -ne 0 ]; then
  log_error "Command failed at line ${LAST_LINE}: ${LAST_COMMAND}"
  exit 1
fi' ERR

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
PURGE_NODE=false
KEEP_VOLUMES=false
KUBECONFIG=""

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
    --purge-node)
      PURGE_NODE=true
      shift
      ;;
    --keep-volumes)
      KEEP_VOLUMES=true
      shift
      ;;
    --kubeconfig)
      KUBECONFIG="$2"
      export KUBECONFIG
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--doctor] [--dry-run] [--force] [--purge-node] [--keep-volumes] [--kubeconfig <path>]"
      exit 1
      ;;
  esac
done

# ========= Doctor mode =========
if [ "${DOCTOR}" = "true" ]; then
  echo ""
  echo "=== Voxeil Panel Uninstaller - Doctor Mode ==="
  echo ""
  log_info "Scanning for installed components and leftover resources..."
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

# ===== VOXEIL logo =====
ORANGE="\033[38;5;208m"
GRAY="\033[38;5;252m"
NC="\033[0m"

INNER=72
strip_ansi() { echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g'; }

box_line_center() {
  local line="$1"
  local plain len pad_left pad_right
  plain="$(strip_ansi "$line")"
  len=${#plain}
  if (( len > INNER )); then
    plain="${plain:0:INNER}"
    line="$plain"
    len=$INNER
  fi
  pad_left=$(( (INNER - len) / 2 ))
  pad_right=$(( INNER - len - pad_left ))
  printf "║%*s%b%*s║\n" "$pad_left" "" "$line" "$pad_right" ""
}

echo
echo "╔════════════════════════════════════════════════════════════════════════╗"
printf "║%*s║\n" "$INNER" ""
printf "║%*s║\n" "$INNER" ""

box_line_center "${ORANGE}██╗   ██╗${GRAY}  ██████╗   ██╗  ██╗  ███████╗  ██╗  ██╗${NC}"
box_line_center "${ORANGE}██║   ██║${GRAY} ██╔═══██╗  ╚██╗██╔╝  ██╔════╝  ██║  ██║${NC}"
box_line_center "${ORANGE}██║   ██║${GRAY} ██║   ██║   ╚███╔╝   █████╗    ██║  ██║${NC}"
box_line_center "${ORANGE}╚██╗ ██╔╝${GRAY} ██║   ██║   ██╔██╗   ██╔══╝    ██║  ██║${NC}"
box_line_center "${ORANGE} ╚████╔╝ ${GRAY} ╚██████╔╝  ██╔╝ ██╗  ███████╗  ██║   ███████╗${NC}"
box_line_center "${ORANGE}  ╚═══╝  ${GRAY}  ╚═════╝   ╚═╝  ╚═╝  ╚══════╝  ╚═╝   ╚══════╝${NC}"

printf "║%*s║\n" "$INNER" ""
box_line_center "${GRAY}VOXEIL PANEL${NC}"
box_line_center "${GRAY}Uninstaller${NC}"
printf "║%*s║\n" "$INNER" ""
box_line_center "${GRAY}Safe • Production-Grade Cleanup${NC}"
printf "║%*s║\n" "$INNER" ""
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo
echo "== Voxeil Panel Uninstaller =="
echo ""

# ========= Main uninstaller =========
# Load state
state_load

# Check if state file exists
if [ ! -f "${STATE_FILE}" ]; then
  log_warn "State file not found at ${STATE_FILE}"
  echo "  This may indicate a partial installation or manual cleanup."
  if [ "${FORCE}" != "true" ]; then
    echo "  Use --force to proceed with cleanup based on detected resources."
    echo ""
    log_info "Safe default: exiting without changes."
    exit 0
  fi
  log_info "Proceeding with uninstall based on detected resources (--force)..."
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

# Disable admission webhooks (Kyverno and cert-manager) to prevent API lock
disable_admission_webhooks_preflight() {
  echo ""
  log_info "Preflight: disabling Kyverno/cert-manager admission webhooks (to prevent API lock)"

  # Kyverno: delete any webhook configs named kyverno-*
  kubectl get validatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^kyverno-' | xargs -r kubectl delete validatingwebhookconfiguration --ignore-not-found >/dev/null 2>&1 || true

  kubectl get mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^kyverno-' | xargs -r kubectl delete mutatingwebhookconfiguration --ignore-not-found >/dev/null 2>&1 || true

  # cert-manager: there can be BOTH validating and mutating configs called cert-manager-webhook
  kubectl delete validatingwebhookconfiguration cert-manager-webhook --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete mutatingwebhookconfiguration cert-manager-webhook --ignore-not-found >/dev/null 2>&1 || true

  # Also delete labeled webhooks
  kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
    -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true >/dev/null 2>&1 || true
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
      log_ok "Namespace ${namespace} deleted"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
    if [ $((waited % 10)) -eq 0 ]; then
      log_info "Waiting for namespace ${namespace} to be deleted... (${waited}/${timeout}s)"
    fi
    # Force remove finalizers if stuck
    if [ $((waited % 30)) -eq 0 ] && [ ${waited} -gt 0 ]; then
      log_info "Attempting to force remove finalizers..."
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
  
  log_warn "Namespace ${namespace} still exists after ${timeout}s, forcing deletion..."
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
  
  log_info "Deleting namespace: ${namespace}..."
  
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
    # Capture both stdout and stderr
    err="$(kubectl delete namespace "${namespace}" --ignore-not-found=true --grace-period=0 --force 2>&1 || true)"
    # Check for webhook errors in stderr
    if echo "$err" | grep -qiE 'failed calling webhook|context deadline exceeded' && echo "$err" | grep -qiE 'kyverno|cert-manager'; then
      log_warn "Admission webhook blockage detected while deleting ${namespace}. Disabling webhooks and retrying..."
      disable_admission_webhooks_preflight
      # Retry deletion after disabling webhooks
      kubectl delete namespace "${namespace}" --ignore-not-found=true --grace-period=0 --force 2>&1 || true
    fi
  fi
  
  # Wait for namespace deletion
  wait_ns_deleted "${namespace}" 300
}

# Set KUBECONFIG if provided
if [ -n "${KUBECONFIG}" ]; then
  export KUBECONFIG
  log_info "Using kubeconfig: ${KUBECONFIG}"
fi

# Check kubectl availability
if ! command -v kubectl >/dev/null 2>&1 || ! kubectl cluster-info >/dev/null 2>&1; then
  log_warn "kubectl not available or cluster not accessible"
  echo "  Proceeding with filesystem cleanup only..."
  KUBECTL_AVAILABLE=false
else
  KUBECTL_AVAILABLE=true
fi

# ========= Deletion Order (Reverse of Installation) =========

if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  # Preflight: Disable admission webhooks BEFORE any deletions to prevent API lock
  # Call if FORCE=true OR if webhookconfigs exist (self-heal)
  if [ "${FORCE}" = "true" ]; then
    disable_admission_webhooks_preflight
  elif kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -qiE 'kyverno|cert-manager'; then
    disable_admission_webhooks_preflight
  fi
  
  # A) Workloads first - delete all resources by label
  log_step "Deleting workloads and namespace-scoped resources"
  log_info "Deleting all resources labeled app.kubernetes.io/part-of=voxeil..."
  run "kubectl delete all,cm,secret,sa,role,rolebinding,ingress,networkpolicy -A -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete PVCs explicitly
  log_info "Deleting PVCs..."
  run "kubectl delete pvc -A -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # B) Namespaces next (reverse order), and WAIT
  log_step "Deleting namespaces (reverse order)"
  
  # Delete user and tenant namespaces first (dynamically created)
  log_info "Deleting user namespaces..."
  user_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^user-' || true)"
  if [ -n "${user_namespaces}" ]; then
    for ns in ${user_namespaces}; do
      if [ "${FORCE}" = "true" ] || kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -q voxeil; then
        delete_namespace "${ns}"
      fi
    done
  fi
  
  log_info "Deleting tenant namespaces..."
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
  log_step "Deleting remaining webhooks"
  run "kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete by name patterns if not labeled (backward compatibility - cert-manager, Flux, etc.)
  if [ "${FORCE}" = "true" ] || is_installed "CERT_MANAGER_INSTALLED"; then
    log_info "Deleting cert-manager webhooks (by name pattern)..."
    cert_webhooks="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i cert-manager || true)"
    for webhook in ${cert_webhooks}; do
      run "kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \"${webhook}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
  fi
  
  if [ "${FORCE}" = "true" ] || is_installed "FLUX_INSTALLED"; then
    log_info "Deleting Flux webhooks (by name pattern)..."
    flux_webhooks="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i flux || true)"
    for webhook in ${flux_webhooks}; do
      run "kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \"${webhook}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
  fi
  
  # D) ClusterRoles / ClusterRoleBindings by label
  log_step "Deleting ClusterRoles and ClusterRoleBindings"
  run "kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete by name (backward compatibility)
  run "kubectl delete clusterrole controller-bootstrap user-operator --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  run "kubectl delete clusterrolebinding controller-bootstrap-binding --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Delete ClusterIssuers and HelmChartConfig
  if [ "${FORCE}" = "true" ] || is_installed "CERT_MANAGER_INSTALLED"; then
    log_info "Deleting ClusterIssuers..."
    run "kubectl delete clusterissuer --all --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  log_info "Deleting HelmChartConfig..."
  run "kubectl delete helmchartconfig traefik -n kube-system --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # E) CRDs LAST by label
  log_step "Deleting CRDs"
  run "kubectl delete crd -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete by name patterns (backward compatibility)
  # Note: FORCE=true CRD deletions are deferred to Step F (after namespace deletion)
  if [ "${FORCE}" != "true" ] && is_installed "CERT_MANAGER_INSTALLED"; then
    log_info "Deleting cert-manager CRDs (by name pattern)..."
    run "kubectl delete crd -l app.kubernetes.io/name=cert-manager --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd certificates.cert-manager.io certificaterequests.cert-manager.io challenges.acme.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io orders.acme.cert-manager.io --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  if [ "${FORCE}" != "true" ] && is_installed "KYVERNO_INSTALLED"; then
    log_info "Deleting Kyverno CRDs (by name pattern)..."
    run "kubectl delete crd -l app.kubernetes.io/name=kyverno --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd policies.kyverno.io clusterpolicies.kyverno.io policyreports.wgpolicyk8s.io clusterpolicyreports.wgpolicyk8s.io --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  if [ "${FORCE}" != "true" ] && is_installed "FLUX_INSTALLED"; then
    log_info "Deleting Flux CRDs (by name pattern)..."
    run "kubectl delete crd -l app.kubernetes.io/name=flux --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  # F) Force-mode fallback cleanup for unlabeled leftovers (state missing)
  if [ "${FORCE}" = "true" ]; then
    log_step "Force-mode fallback cleanup (unlabeled leftovers)"
    
    # Delete unlabeled namespaces
    log_info "Cleaning up unlabeled namespaces..."
    for ns in platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager; do
      if kubectl get namespace "${ns}" >/dev/null 2>&1; then
        if ! kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -q voxeil; then
          log_info "Deleting unlabeled namespace: ${ns}"
          delete_namespace "${ns}"
        fi
      fi
    done
    
    # Delete user-* and tenant-* namespaces
    user_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^user-' || true)"
    if [ -n "${user_namespaces}" ]; then
      for ns in ${user_namespaces}; do
        if ! kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -q voxeil; then
          log_info "Deleting unlabeled namespace: ${ns}"
          delete_namespace "${ns}"
        fi
      done
    fi
    
    tenant_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^tenant-' || true)"
    if [ -n "${tenant_namespaces}" ]; then
      for ns in ${tenant_namespaces}; do
        if ! kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -q voxeil; then
          log_info "Deleting unlabeled namespace: ${ns}"
          delete_namespace "${ns}"
        fi
      done
    fi
    
    # Delete remaining cluster resources
    log_info "Cleaning up cluster roles and bindings..."
    run "kubectl delete clusterrole controller-bootstrap user-operator --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete clusterrolebinding controller-bootstrap-binding --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    
    # Remove lingering webhookconfigs again (idempotent)
    log_info "Cleaning up remaining webhookconfigs..."
    disable_admission_webhooks_preflight
    
    # Delete CRDs by patterns (name match, not labels) - LAST, after namespaces and webhooks
    log_info "Cleaning up CRDs by name pattern (kyverno/cert-manager/flux/toolkit)..."
    crds="$(kubectl get crd -o name 2>/dev/null | grep -E '(kyverno|cert-manager|fluxcd|toolkit)' || true)"
    if [ -n "${crds}" ]; then
      echo "${crds}" | xargs -r kubectl delete --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    fi
    
    # Also delete CRDs by name patterns (from Step E, deferred here for FORCE=true case)
    log_info "Cleaning up CRDs by component patterns..."
    run "kubectl delete crd -l app.kubernetes.io/name=cert-manager --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd certificates.cert-manager.io certificaterequests.cert-manager.io challenges.acme.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io orders.acme.cert-manager.io --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd -l app.kubernetes.io/name=kyverno --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd policies.kyverno.io clusterpolicies.kyverno.io policyreports.wgpolicyk8s.io clusterpolicyreports.wgpolicyk8s.io --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd -l app.kubernetes.io/name=flux --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  # G) Storage cleanup - PVs (unless --keep-volumes)
  if [ "${KEEP_VOLUMES}" != "true" ]; then
    log_step "Cleaning up PersistentVolumes"
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
        log_info "Deleting PVs for namespace ${ns}..."
        for pv in ${PVS}; do
            run "kubectl delete pv \"${pv}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
          done
        fi
      fi
    done
  else
    log_step "Skipping PersistentVolume cleanup (--keep-volumes)"
  fi
fi

# H) Node purge (--purge-node AND --force required)
if [ "${PURGE_NODE}" = "true" ]; then
  if [ "${FORCE}" != "true" ]; then
    log_error "--purge-node requires --force flag"
    echo "  This is a safety measure to prevent accidental node wipe."
    exit 1
  fi
  
  log_step "Node Purge Mode (--purge-node --force)"
  log_warn "This will remove k3s and rancher directories from the node."
  echo ""
  
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY RUN] Would remove k3s and rancher directories"
  else
    # Stop and disable k3s service
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop k3s 2>/dev/null || true
      systemctl disable k3s 2>/dev/null || true
    fi
    
    # Run k3s uninstall script if available
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
      log_info "Running k3s-uninstall.sh..."
      /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 || true
    fi
    
    # Remove k3s binaries and directories
    log_info "Removing k3s binaries and directories..."
    rm -f /usr/local/bin/k3s /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr 2>/dev/null || true
    rm -rf /var/lib/rancher /etc/rancher /var/log/k3s 2>/dev/null || true
    rm -f /etc/systemd/system/k3s.service 2>/dev/null || true
    
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload 2>/dev/null || true
    fi
    
    # Remove /var/lib/voxeil (state registry)
    log_info "Removing /var/lib/voxeil..."
    rm -rf /var/lib/voxeil 2>/dev/null || true
    
    log_ok "Node purge complete"
  fi
fi

# I) Clean up filesystem files (unless --purge-node, which handles /var/lib/voxeil)
log_step "Cleaning up filesystem files"
run "rm -rf /etc/voxeil 2>/dev/null || true"
run "rm -f /usr/local/bin/voxeil-ufw-apply 2>/dev/null || true"
run "rm -f /etc/systemd/system/voxeil-ufw-apply.service 2>/dev/null || true"
run "rm -f /etc/systemd/system/voxeil-ufw-apply.path 2>/dev/null || true"
run "rm -f /etc/fail2ban/jail.d/voxeil.conf 2>/dev/null || true"
run "rm -f /etc/ssh/sshd_config.voxeil-backup.* 2>/dev/null || true"
# Only remove /var/lib/voxeil if not doing node purge (purge handles it)
if [ "${PURGE_NODE}" != "true" ]; then
  run "rm -rf /var/lib/voxeil 2>/dev/null || true"
fi

if [ "${DRY_RUN}" != "true" ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload 2>/dev/null || true
fi

echo ""
echo "=== Uninstall Complete ==="
if [ "${DRY_RUN}" = "true" ]; then
  log_info "Dry run - no changes were made"
else
  log_ok "All Voxeil Panel components removed"
fi
