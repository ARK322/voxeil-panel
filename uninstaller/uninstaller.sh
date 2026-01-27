#!/usr/bin/env bash
# Use set -u for undefined variables, but allow commands to fail (we handle errors manually)
set -uo pipefail

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

# Trap to log failed commands (but don't exit - we handle errors manually with || true)
trap 'LAST_COMMAND="${BASH_COMMAND}"; LAST_LINE="${LINENO}"' DEBUG

# ========= Timeout Management =========
# Track overall time spent (in seconds)
OVERALL_START_TIME=$(date +%s)
OVERALL_TIMEOUT_UNINSTALL=600  # 10 minutes max for uninstall
# Purge-node includes uninstall first, so needs more time
# Uninstall can take up to 10 min, k3s cleanup can take up to 5 min
OVERALL_TIMEOUT_PURGE_NODE=900  # 15 minutes max for purge-node (includes uninstall + k3s cleanup)

# Check if overall timeout exceeded
check_overall_timeout() {
  local max_time="${1:-600}"
  local elapsed=$(($(date +%s) - OVERALL_START_TIME))
  if [ ${elapsed} -ge ${max_time} ]; then
    log_warn "Overall timeout reached (${elapsed}s >= ${max_time}s), proceeding to fallback cleanup..."
    return 1
  fi
  return 0
}

# Run command with timeout
run_with_timeout() {
  local timeout="${1}"
  shift
  local cmd="$*"
  local start_time=$(date +%s)
  
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY-RUN] ${cmd}"
    return 0
  fi
  
  # Use timeout command if available
  if command -v timeout >/dev/null 2>&1; then
    if timeout "${timeout}" bash -c "${cmd}" 2>/dev/null; then
      return 0
    else
      local elapsed=$(($(date +%s) - start_time))
      if [ ${elapsed} -ge ${timeout} ]; then
        log_warn "Command timed out after ${timeout}s: ${cmd}"
        return 1
      fi
      return $?
    fi
  else
    # Fallback: run in background and kill after timeout
    bash -c "${cmd}" &
    local pid=$!
    local waited=0
    while kill -0 ${pid} 2>/dev/null && [ ${waited} -lt ${timeout} ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 ${pid} 2>/dev/null; then
      log_warn "Command timed out after ${timeout}s, killing: ${cmd}"
      kill -9 ${pid} 2>/dev/null || true
      return 1
    fi
    wait ${pid} 2>/dev/null || true
    return $?
  fi
}

# ========= kubectl safe wrapper =========
# Ensures kubectl calls never hang indefinitely (common during terminating PVC/PV or API webhook issues).
kubectl_safe() {
  local timeout_s="${1:-10}"
  shift || true
  run_with_timeout "${timeout_s}" "kubectl $*"
}

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
    # Also check by name pattern (backward compatibility)
    VOXEIL_CLUSTER_BY_NAME="$(kubectl get clusterrole,clusterrolebinding -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '(controller-bootstrap|user-operator|controller-bootstrap-binding)' || true)"
    if [ -n "${VOXEIL_CLUSTER_BY_NAME}" ]; then
      echo "${VOXEIL_CLUSTER_BY_NAME}" | while read -r name; do
        if kubectl get clusterrole "${name}" >/dev/null 2>&1; then
          kubectl get clusterrole "${name}" 2>/dev/null || true
        elif kubectl get clusterrolebinding "${name}" >/dev/null 2>&1; then
          kubectl get clusterrolebinding "${name}" 2>/dev/null || true
        fi
      done
      EXIT_CODE=1
    else
      echo "  ✓ None found"
    fi
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
  
  # Check for stuck Terminating namespaces
  echo ""
  echo "=== Stuck Terminating Namespaces ==="
  TERMINATING_NS="$(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -E '\tTerminating$' | cut -f1 || true)"
  if [ -n "${TERMINATING_NS}" ]; then
    echo "${TERMINATING_NS}" | while read -r ns; do
      echo "  ⚠ ${ns} (stuck in Terminating)"
      EXIT_CODE=1
    done
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
  
  # Check PVs tied to voxeil namespaces (by claimRef)
  echo ""
  echo "=== PersistentVolumes (checking claimRef) ==="
  VOXEIL_PVS=0
  VOXEIL_NS_LIST="platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager"
  for ns in ${VOXEIL_NS_LIST}; do
    # Check PVs even if namespace doesn't exist (leftover PVs)
    if command -v python3 >/dev/null 2>&1; then
      PVS="$(kubectl get pv -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); [print(pv['metadata']['name'] + '\t' + pv.get('spec', {}).get('claimRef', {}).get('namespace', '')) for pv in data.get('items', []) if pv.get('spec', {}).get('claimRef', {}).get('namespace') == '${ns}']" 2>/dev/null || true)"
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
  done
  if [ ${VOXEIL_PVS} -eq 0 ]; then
    echo "  ✓ None found"
  fi
  
  # Check for leftover CRDs
  echo ""
  echo "=== CRDs (Custom Resource Definitions) ==="
  VOXEIL_CRDS="$(kubectl get crd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '(cert-manager|kyverno|fluxcd|toolkit)' || true)"
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
  echo "=== Webhook Configurations ==="
  VOXEIL_WEBHOOKS="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE '(kyverno|cert-manager|flux|toolkit)' || true)"
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
  if [ -f /etc/fail2ban/jail.d/voxeil.conf ]; then
    echo "  ⚠ Found /etc/fail2ban/jail.d/voxeil.conf"
    FILES_FOUND=1
  fi
  if [ -f /etc/fail2ban/filter.d/traefik-http.conf ] || [ -f /etc/fail2ban/filter.d/traefik-auth.conf ] || [ -f /etc/fail2ban/filter.d/mailcow-auth.conf ] || [ -f /etc/fail2ban/filter.d/bind9.conf ]; then
    echo "  ⚠ Found fail2ban filter files"
    FILES_FOUND=1
  fi
  if [ ${FILES_FOUND} -eq 0 ]; then
    echo "  ✓ No Voxeil filesystem files found"
  else
    EXIT_CODE=1
  fi
  
  # Check for Traefik middlewares
  echo ""
  echo "Checking Traefik middlewares..."
  TRAEFIK_MIDDLEWARES="$(kubectl get middleware -n kube-system -l app.kubernetes.io/part-of=voxeil -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '(security-headers|rate-limit|sql-injection-protection|request-size-limit)' || true)"
  if [ -n "${TRAEFIK_MIDDLEWARES}" ]; then
    echo "  ⚠ Found Traefik security middlewares:"
    echo "${TRAEFIK_MIDDLEWARES}" | while read -r mw; do
      echo "    - ${mw}"
    done
    EXIT_CODE=1
  else
    echo "  ✓ No Traefik security middlewares found"
  fi
  
  echo ""
  echo "=== Summary ==="
  if [ ${EXIT_CODE} -eq 0 ]; then
    echo "[OK] System is clean - no Voxeil resources found"
  else
    echo "[WARN] System has leftover Voxeil resources"
    echo ""
    echo "Recommended next steps:"
    echo "  bash /tmp/voxeil.sh uninstall --force"
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

# Scale down controllers before deleting namespaces to prevent webhook recreation
scale_down_controllers() {
  log_info "Scaling down controllers to prevent webhook recreation..."
  
  # Scale down Kyverno deployments
  for ns in kyverno; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      deployments="$(kubectl get deployments -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
      if [ -n "${deployments}" ]; then
        for deploy in ${deployments}; do
          run "kubectl scale deployment \"${deploy}\" -n \"${ns}\" --replicas=0 --ignore-not-found=true >/dev/null 2>&1 || true"
        done
      fi
    fi
  done
  
  # Scale down cert-manager deployments
  for ns in cert-manager; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      deployments="$(kubectl get deployments -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
      if [ -n "${deployments}" ]; then
        for deploy in ${deployments}; do
          run "kubectl scale deployment \"${deploy}\" -n \"${ns}\" --replicas=0 --ignore-not-found=true >/dev/null 2>&1 || true"
        done
      fi
    fi
  done
  
  # Scale down Flux controllers
  for ns in flux-system; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      deployments="$(kubectl get deployments -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
      if [ -n "${deployments}" ]; then
        for deploy in ${deployments}; do
          run "kubectl scale deployment \"${deploy}\" -n \"${ns}\" --replicas=0 --ignore-not-found=true >/dev/null 2>&1 || true"
        done
      fi
    fi
  done
  
  # Wait a moment for controllers to stop
  sleep 2
}

# Disable admission webhooks (Kyverno and cert-manager) to prevent API lock
# This function patches ALL webhooks entries (not just index 0) to fail-open
# Uses request-timeouts to prevent hanging on unreachable webhooks
disable_admission_webhooks_preflight() {
  echo ""
  log_info "Preflight: disabling Kyverno/cert-manager/flux admission webhooks (to prevent API lock)"

  # First, scale down controllers to prevent webhook recreation
  scale_down_controllers

  # Then, try to patch failurePolicy to Ignore (safer than immediate delete)
  # This prevents API lock while still allowing graceful cleanup
  # IMPORTANT: Patch ALL webhooks entries, not just index 0 (webhook configs have multiple webhooks)
  webhook_patterns="kyverno cert-manager flux toolkit"
  for pattern in ${webhook_patterns}; do
    # ValidatingWebhookConfigurations - use request-timeout to prevent hanging
    validating_webhooks="$(kubectl get validatingwebhookconfigurations --request-timeout=10s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE "${pattern}" || true)"
    if [ -n "${validating_webhooks}" ]; then
      for wh in ${validating_webhooks}; do
        log_info "Patching validating webhook: ${wh} (setting fail-open)"
        # Use python3 or jq to properly patch ALL webhooks entries
        if command -v python3 >/dev/null 2>&1; then
          kubectl get validatingwebhookconfiguration "${wh}" --request-timeout=10s -o json 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'webhooks' in data:
    for webhook in data['webhooks']:
        webhook['failurePolicy'] = 'Ignore'
        webhook['timeoutSeconds'] = 5
print(json.dumps(data))
" 2>/dev/null | kubectl apply --request-timeout=20s -f - >/dev/null 2>&1 || true
        elif command -v jq >/dev/null 2>&1; then
          kubectl get validatingwebhookconfiguration "${wh}" --request-timeout=10s -o json 2>/dev/null | \
            jq '.webhooks[] |= . + {"failurePolicy": "Ignore", "timeoutSeconds": 5}' 2>/dev/null | \
            kubectl apply --request-timeout=20s -f - >/dev/null 2>&1 || true
        else
          # Fallback: try patch with type=json (may only patch first webhook, but better than nothing)
          kubectl patch validatingwebhookconfiguration "${wh}" --request-timeout=20s \
            -p '{"webhooks":[{"failurePolicy":"Ignore","timeoutSeconds":5}]}' \
            --type=json 2>/dev/null || \
          kubectl patch validatingwebhookconfiguration "${wh}" --request-timeout=20s \
            -p '{"webhooks":[{"failurePolicy":"Ignore","timeoutSeconds":5}]}' \
            --type=merge 2>/dev/null || true
        fi
      done
    fi
    
    # MutatingWebhookConfigurations - use request-timeout to prevent hanging
    mutating_webhooks="$(kubectl get mutatingwebhookconfigurations --request-timeout=10s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE "${pattern}" || true)"
    if [ -n "${mutating_webhooks}" ]; then
      for wh in ${mutating_webhooks}; do
        log_info "Patching mutating webhook: ${wh} (setting fail-open)"
        # Use python3 or jq to properly patch ALL webhooks entries
        if command -v python3 >/dev/null 2>&1; then
          kubectl get mutatingwebhookconfiguration "${wh}" --request-timeout=10s -o json 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'webhooks' in data:
    for webhook in data['webhooks']:
        webhook['failurePolicy'] = 'Ignore'
        webhook['timeoutSeconds'] = 5
print(json.dumps(data))
" 2>/dev/null | kubectl apply --request-timeout=20s -f - >/dev/null 2>&1 || true
        elif command -v jq >/dev/null 2>&1; then
          kubectl get mutatingwebhookconfiguration "${wh}" --request-timeout=10s -o json 2>/dev/null | \
            jq '.webhooks[] |= . + {"failurePolicy": "Ignore", "timeoutSeconds": 5}' 2>/dev/null | \
            kubectl apply --request-timeout=20s -f - >/dev/null 2>&1 || true
        else
          # Fallback: try patch with type=json
          kubectl patch mutatingwebhookconfiguration "${wh}" --request-timeout=20s \
            -p '{"webhooks":[{"failurePolicy":"Ignore","timeoutSeconds":5}]}' \
            --type=json 2>/dev/null || \
          kubectl patch mutatingwebhookconfiguration "${wh}" --request-timeout=20s \
            -p '{"webhooks":[{"failurePolicy":"Ignore","timeoutSeconds":5}]}' \
            --type=merge 2>/dev/null || true
        fi
      done
    fi
  done

  # If patch fails (webhook unreachable), try direct delete with request-timeout
  # Kyverno: delete any webhook configs named kyverno-*
  kubectl get validatingwebhookconfigurations --request-timeout=10s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^kyverno-' | xargs -r -I {} kubectl delete validatingwebhookconfiguration {} --request-timeout=20s --ignore-not-found >/dev/null 2>&1 || true

  kubectl get mutatingwebhookconfigurations --request-timeout=10s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^kyverno-' | xargs -r -I {} kubectl delete mutatingwebhookconfiguration {} --request-timeout=20s --ignore-not-found >/dev/null 2>&1 || true

  # cert-manager: there can be BOTH validating and mutating configs called cert-manager-webhook
  kubectl delete validatingwebhookconfiguration cert-manager-webhook --request-timeout=20s --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete mutatingwebhookconfiguration cert-manager-webhook --request-timeout=20s --ignore-not-found >/dev/null 2>&1 || true

  # Flux webhooks
  kubectl get validatingwebhookconfigurations --request-timeout=10s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -iE 'flux' | xargs -r -I {} kubectl delete validatingwebhookconfiguration {} --request-timeout=20s --ignore-not-found >/dev/null 2>&1 || true

  kubectl get mutatingwebhookconfigurations --request-timeout=10s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -iE 'flux' | xargs -r -I {} kubectl delete mutatingwebhookconfiguration {} --request-timeout=20s --ignore-not-found >/dev/null 2>&1 || true

  # Also delete labeled webhooks (with request-timeout)
  kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
    -l app.kubernetes.io/part-of=voxeil --request-timeout=20s --ignore-not-found=true >/dev/null 2>&1 || true
  
  log_ok "Admission webhooks disabled (fail-open mode)"
}

# Wait for namespace deletion with timeout (simplified - finalizer removal handled in delete_namespace)
wait_ns_deleted() {
  local namespace="$1"
  local timeout="${2:-90}"
  local waited=0
  
  if [ "${DRY_RUN}" = "true" ]; then
    return 0
  fi
  
  while [ ${waited} -lt ${timeout} ]; do
    # Check overall timeout every 10 seconds
    if [ $((waited % 10)) -eq 0 ] && [ ${waited} -gt 0 ]; then
      if [ "${PURGE_NODE}" = "true" ]; then
        if ! check_overall_timeout ${OVERALL_TIMEOUT_PURGE_NODE}; then
          log_warn "Overall timeout reached, applying force cleanup..."
          return 1
        fi
      else
        if ! check_overall_timeout ${OVERALL_TIMEOUT_UNINSTALL}; then
          log_warn "Overall timeout reached, applying force cleanup..."
          return 1
        fi
      fi
    fi
    
    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      log_ok "Namespace ${namespace} deleted"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
    if [ $((waited % 10)) -eq 0 ]; then
      log_info "Waiting for namespace ${namespace} to be deleted... (${waited}/${timeout}s)"
    fi
  done
  
  log_warn "Namespace ${namespace} still exists after ${timeout}s, applying force cleanup..."
  return 1
}

# Aggressively remove finalizers from namespace (with quick timeout)
force_remove_namespace_finalizers() {
  local namespace="$1"
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    return 0
  fi
  
  log_info "Force removing finalizers from namespace ${namespace}..."
  
  # Quick method: Try patch first (fastest, use request-timeout)
  kubectl patch namespace "${namespace}" --request-timeout=10s -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
  
  # If still exists, try /finalize endpoint (more aggressive, but can be slow)
  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    # Use the fastest available tool
    if command -v jq >/dev/null 2>&1; then
      kubectl get namespace "${namespace}" --request-timeout=10s -o json 2>/dev/null | jq '.spec.finalizers=[]' 2>/dev/null | kubectl replace --raw "/api/v1/namespaces/${namespace}/finalize" --request-timeout=15s -f - >/dev/null 2>&1 || true
    elif command -v python3 >/dev/null 2>&1; then
      kubectl get namespace "${namespace}" --request-timeout=10s -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); data['spec']['finalizers']=[]; print(json.dumps(data))" 2>/dev/null | kubectl replace --raw "/api/v1/namespaces/${namespace}/finalize" --request-timeout=15s -f - >/dev/null 2>&1 || true
    elif command -v sed >/dev/null 2>&1; then
      # Fallback: use sed to remove finalizers array
      kubectl get namespace "${namespace}" --request-timeout=10s -o json 2>/dev/null | sed 's/"finalizers":\[[^]]*\]/"finalizers":[]/g' 2>/dev/null | kubectl replace --raw "/api/v1/namespaces/${namespace}/finalize" --request-timeout=15s -f - >/dev/null 2>&1 || true
    fi
  fi
}

# Delete namespace and wait for termination
delete_namespace() {
  local namespace="$1"
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    echo "  Namespace ${namespace} does not exist, skipping"
    return 0
  fi
  
  log_info "Deleting namespace: ${namespace}..."
  
  # In force mode, immediately remove finalizers to prevent stuck deletion
  if [ "${FORCE}" = "true" ]; then
    echo "  Removing finalizers before deletion..."
    force_remove_namespace_finalizers "${namespace}"
  fi
  
  # Delete all PVCs first (they block namespace deletion) - quick and aggressive
  pvcs="$(kubectl get pvc -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pvcs}" ]; then
    log_info "Deleting PVCs in ${namespace} (quick cleanup, max 5s per PVC)..."
    for pvc in ${pvcs}; do
      # Check overall timeout
      if [ "${PURGE_NODE}" = "true" ]; then
        if ! check_overall_timeout ${OVERALL_TIMEOUT_PURGE_NODE}; then
          log_warn "Overall timeout reached, skipping remaining PVCs..."
          break
        fi
      else
        if ! check_overall_timeout ${OVERALL_TIMEOUT_UNINSTALL}; then
          log_warn "Overall timeout reached, skipping remaining PVCs..."
          break
        fi
      fi
      
      echo "  Processing PVC: ${pvc}..."

      # Capture the bound PV name early (helps when PVC is stuck in Terminating)
      volume_name="$(kubectl_safe 5 get pvc "${pvc}" -n "${namespace}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"

      # Quick attempt: remove finalizers and delete (never hang, use request-timeout)
      kubectl_safe 5 patch pvc "${pvc}" -n "${namespace}" --request-timeout=10s -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      kubectl_safe 8 delete pvc "${pvc}" -n "${namespace}" --request-timeout=15s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

      # One quick check after 1 second, then move on
      sleep 1
      if kubectl_safe 3 get pvc "${pvc}" -n "${namespace}" >/dev/null 2>&1; then
        echo "  PVC ${pvc} still exists, trying aggressive removal once..."

        # Try one aggressive removal attempt (and still avoid hangs)
        if command -v jq >/dev/null 2>&1; then
          kubectl_safe 8 get pvc "${pvc}" -n "${namespace}" -o json 2>/dev/null | jq 'del(.metadata.finalizers)' 2>/dev/null | kubectl_safe 8 replace -f - >/dev/null 2>&1 || true
        elif command -v python3 >/dev/null 2>&1; then
          kubectl_safe 8 get pvc "${pvc}" -n "${namespace}" -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); data['metadata']['finalizers']=[]; print(json.dumps(data))" 2>/dev/null | kubectl_safe 8 replace -f - >/dev/null 2>&1 || true
        fi

        kubectl_safe 8 delete pvc "${pvc}" -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

        # If still present and we know the PV, delete PV immediately (this often unblocks Terminating PVCs)
        if [ "${KEEP_VOLUMES}" != "true" ] && [ -n "${volume_name}" ]; then
          echo "  PVC ${pvc} still exists; attempting to delete bound PV: ${volume_name}..."
          kubectl_safe 5 patch pv "${volume_name}" -p '{"metadata":{"finalizers":[]},"spec":{"claimRef":null}}' --type=merge >/dev/null 2>&1 || true
          kubectl_safe 8 delete pv "${volume_name}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
        fi

        echo "  Continuing - PVC ${pvc} will be cleaned up during namespace deletion"
      fi
    done
    # Don't wait for PVCs - namespace deletion will handle it
  fi
  
  # Delete PVs associated with this namespace (they also block namespace deletion) - quick and aggressive
  if [ "${KEEP_VOLUMES}" != "true" ]; then
    log_info "Deleting PVs for namespace ${namespace} (quick cleanup, max 5s per PV)..."
    # Find PVs for this namespace
    if command -v python3 >/dev/null 2>&1; then
      PVS="$(kubectl get pv -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); [print(pv['metadata']['name']) for pv in data.get('items', []) if pv.get('spec', {}).get('claimRef', {}).get('namespace') == '${namespace}']" 2>/dev/null || true)"
    elif command -v jq >/dev/null 2>&1; then
      PVS="$(kubectl get pv -o json 2>/dev/null | jq -r '.items[] | select(.spec.claimRef.namespace == "'${namespace}'") | .metadata.name' 2>/dev/null || true)"
    else
      # Fallback: get all PVs and check claimRef manually
      PVS="$(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null | grep -E "^[^\t]+\t${namespace}$" | cut -f1 || true)"
    fi
    if [ -n "${PVS}" ]; then
      for pv in ${PVS}; do
        # Check overall timeout
        if [ "${PURGE_NODE}" = "true" ]; then
          if ! check_overall_timeout ${OVERALL_TIMEOUT_PURGE_NODE}; then
            log_warn "Overall timeout reached, skipping remaining PVs..."
            break
          fi
        else
          if ! check_overall_timeout ${OVERALL_TIMEOUT_UNINSTALL}; then
            log_warn "Overall timeout reached, skipping remaining PVs..."
            break
          fi
        fi
        
        echo "  Processing PV: ${pv}..."
        # Quick attempt: remove finalizers and claimRef, then delete (fire and forget, no wait, use request-timeout)
        kubectl patch pv "${pv}" --request-timeout=10s -p '{"metadata":{"finalizers":[]},"spec":{"claimRef":null}}' --type=merge >/dev/null 2>&1 || true
        kubectl delete pv "${pv}" --request-timeout=15s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
        
        # One quick check after 1 second, then move on
        sleep 1
        if kubectl get pv "${pv}" >/dev/null 2>&1; then
          echo "  PV ${pv} still exists, trying aggressive removal once..."
          # Try one aggressive removal attempt
          if command -v jq >/dev/null 2>&1; then
            kubectl get pv "${pv}" -o json 2>/dev/null | jq 'del(.metadata.finalizers) | del(.spec.claimRef)' 2>/dev/null | kubectl replace -f - >/dev/null 2>&1 || true
          elif command -v python3 >/dev/null 2>&1; then
            kubectl get pv "${pv}" -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); data['metadata']['finalizers']=[]; data['spec']['claimRef']=None; print(json.dumps(data))" 2>/dev/null | kubectl replace -f - >/dev/null 2>&1 || true
          fi
          kubectl delete pv "${pv}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
          echo "  Continuing - PV ${pv} will be cleaned up separately"
        fi
      done
      # Don't wait for PVs - proceed to namespace deletion
    fi
  fi
  
  # In --force mode, aggressively delete any remaining resources that might block deletion (with timeout)
  if [ "${FORCE}" = "true" ]; then
    log_info "Force mode: deleting all resources in ${namespace} (timeout: 30s)..."
    local force_start_time=$(date +%s)
    local force_timeout=30
    
    # Scale down StatefulSets and Deployments first (quick, no wait)
    statefulsets="$(kubectl get statefulsets -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    if [ -n "${statefulsets}" ]; then
      for sts in ${statefulsets}; do
        kubectl scale statefulset "${sts}" -n "${namespace}" --replicas=0 --ignore-not-found=true >/dev/null 2>&1 || true
      done
    fi
    deployments="$(kubectl get deployments -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    if [ -n "${deployments}" ]; then
      for deploy in ${deployments}; do
        kubectl scale deployment "${deploy}" -n "${namespace}" --replicas=0 --ignore-not-found=true >/dev/null 2>&1 || true
      done
    fi
    
    # Delete any remaining resources with finalizers (quick, no wait, with timeout check)
    for resource in deployments statefulsets daemonsets jobs cronjobs services ingress networkpolicies configmaps secrets; do
      # Check timeout before processing each resource type
      local elapsed=$(($(date +%s) - force_start_time))
      if [ ${elapsed} -ge ${force_timeout} ]; then
        log_warn "Force cleanup timeout reached (${elapsed}s), proceeding to namespace deletion..."
        break
      fi
      
      resources="$(kubectl get "${resource}" -n "${namespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
      if [ -n "${resources}" ]; then
        # Process resources quickly without waiting
        for res in ${resources}; do
          # Check timeout before each resource
          local elapsed=$(($(date +%s) - force_start_time))
          if [ ${elapsed} -ge ${force_timeout} ]; then
            log_warn "Force cleanup timeout reached, proceeding to namespace deletion..."
            break 2  # Break out of both loops
          fi
          # Quick patch and delete (no wait)
          kubectl patch "${resource}" "${res}" -n "${namespace}" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
          kubectl delete "${resource}" "${res}" -n "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
        done
      fi
    done
    log_info "Force cleanup completed, proceeding to namespace deletion..."
  fi
  
  # Delete namespace (capture stderr to detect webhook failures)
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[DRY-RUN] kubectl delete namespace \"${namespace}\" --ignore-not-found=true --grace-period=0 --force"
  else
    # In force mode, remove finalizers BEFORE deletion to prevent stuck state
    if [ "${FORCE}" = "true" ]; then
      force_remove_namespace_finalizers "${namespace}"
    fi
    
    # Delete namespace (with request-timeout to prevent hanging on webhook calls)
    log_info "Deleting namespace ${namespace}..."
    err="$(run_with_timeout 30 "kubectl delete namespace \"${namespace}\" --request-timeout=20s --ignore-not-found=true --grace-period=0 --force" 2>&1 || echo "timeout_or_error")"
    
    # Check for webhook errors in stderr
    if echo "$err" | grep -qiE 'failed calling webhook|context deadline exceeded' && echo "$err" | grep -qiE 'kyverno|cert-manager'; then
      log_warn "Admission webhook blockage detected while deleting ${namespace}. Disabling webhooks and retrying..."
      disable_admission_webhooks_preflight
      # Retry deletion after disabling webhooks (with request-timeout)
      run_with_timeout 30 "kubectl delete namespace \"${namespace}\" --request-timeout=20s --ignore-not-found=true --grace-period=0 --force" >/dev/null 2>&1 || true
    fi
    
    # Immediately check if namespace is stuck in Terminating and remove finalizers
    sleep 1
    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      ns_phase="$(kubectl get namespace "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
      if [ "${ns_phase}" = "Terminating" ] || [ -z "${ns_phase}" ]; then
        log_info "Namespace ${namespace} is in Terminating state, proceeding to wait loop..."
        # Don't call force_remove_namespace_finalizers here - let the wait loop handle it
      fi
    fi
  fi
  
  # Wait for namespace deletion with timeout (90 seconds default, then force cleanup)
  local waited=0
  local timeout=90
  while [ ${waited} -lt ${timeout} ]; do
    # Check overall timeout every 10 seconds
    if [ $((waited % 10)) -eq 0 ] && [ ${waited} -gt 0 ]; then
      if [ "${PURGE_NODE}" = "true" ]; then
        if ! check_overall_timeout ${OVERALL_TIMEOUT_PURGE_NODE}; then
          log_warn "Overall timeout reached during namespace deletion, proceeding to force cleanup..."
          break
        fi
      else
        if ! check_overall_timeout ${OVERALL_TIMEOUT_UNINSTALL}; then
          log_warn "Overall timeout reached during namespace deletion, proceeding to force cleanup..."
          break
        fi
      fi
    fi
    
    if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      log_ok "Namespace ${namespace} deleted"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
    if [ $((waited % 10)) -eq 0 ]; then
      log_info "Waiting for namespace ${namespace} to be deleted... (${waited}/${timeout}s)"
    fi
  done
  
  # Timeout reached - apply force cleanup
  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    log_warn "Namespace stuck terminating, removing finalizers..."
    force_remove_namespace_finalizers "${namespace}"
    kubectl delete namespace "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    
    # Wait additional 30 seconds with aggressive finalizer removal
    local final_waited=0
    local final_timeout=30
    while [ ${final_waited} -lt ${final_timeout} ]; do
      # Check overall timeout every 5 seconds
      if [ $((final_waited % 5)) -eq 0 ] && [ ${final_waited} -gt 0 ]; then
        if [ "${PURGE_NODE}" = "true" ]; then
          if ! check_overall_timeout ${OVERALL_TIMEOUT_PURGE_NODE}; then
            log_warn "Overall timeout reached during final cleanup, continuing..."
            break
          fi
        else
          if ! check_overall_timeout ${OVERALL_TIMEOUT_UNINSTALL}; then
            log_warn "Overall timeout reached during final cleanup, continuing..."
            break
          fi
        fi
        force_remove_namespace_finalizers "${namespace}"
        kubectl delete namespace "${namespace}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
      fi
      
      if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        log_ok "Namespace ${namespace} deleted after force cleanup"
        return 0
      fi
      sleep 1
      final_waited=$((final_waited + 1))
    done
    
    # Final check - if still exists, log warning but continue (use request-timeout)
    if kubectl get namespace "${namespace}" --request-timeout=5s >/dev/null 2>&1; then
      log_warn "Namespace ${namespace} may still exist - continuing with cleanup"
      echo "  Manual cleanup may be required: kubectl get namespace ${namespace} -o json | jq '.spec.finalizers=[]' | kubectl replace --raw \"/api/v1/namespaces/${namespace}/finalize\" -f -"
    else
      log_ok "Namespace ${namespace} deleted"
    fi
  fi
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
  # Check overall timeout for uninstall
  if ! check_overall_timeout ${OVERALL_TIMEOUT_UNINSTALL}; then
    log_warn "Overall timeout reached, proceeding to fallback cleanup..."
  fi
  
  # Preflight: Disable admission webhooks BEFORE any deletions to prevent API lock
  # Call if FORCE=true OR if webhookconfigs exist (self-heal)
  if [ "${FORCE}" = "true" ]; then
    disable_admission_webhooks_preflight
  elif kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -qiE 'kyverno|cert-manager'; then
    disable_admission_webhooks_preflight
  fi
  
  # A) Delete ingresses/services/deployments/statefulsets in voxeil namespaces first
  log_step "Deleting ingresses, services, and workloads"
  log_info "Deleting ingresses..."
  run "kubectl delete ingress -A -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  # Also delete by name patterns (backward compatibility)
  run "kubectl delete ingress panel -n platform --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  run "kubectl delete ingress pgadmin -n infra-db --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  run "kubectl delete ingress mailcow -n mail-zone --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  # Delete Traefik TCP routes (IngressRouteTCP)
  run "kubectl delete ingressroutetcp -A -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  log_info "Deleting services..."
  run "kubectl delete svc -A -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  log_info "Scaling down deployments and statefulsets..."
  for ns in platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      run "kubectl scale deployment --all -n \"${ns}\" --replicas=0 --ignore-not-found=true >/dev/null 2>&1 || true"
      run "kubectl scale statefulset --all -n \"${ns}\" --replicas=0 --ignore-not-found=true >/dev/null 2>&1 || true"
    fi
  done
  sleep 2
  
  log_info "Deleting deployments and statefulsets..."
  run "kubectl delete deployment,statefulset -A -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # B) Delete webhook configurations for kyverno/cert-manager/flux if they exist
  log_step "Deleting webhook configurations"
  log_info "Deleting validating/mutating webhook configurations for kyverno/cert-manager/flux..."
  # This is idempotent and safe to run even if webhooks are already deleted
  disable_admission_webhooks_preflight
  
  # C) Workloads - delete all remaining resources by label
  log_step "Deleting remaining namespace-scoped resources"
  log_info "Deleting all resources labeled app.kubernetes.io/part-of=voxeil..."
  run "kubectl delete all,cm,secret,sa,role,rolebinding,networkpolicy -A -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete PVCs explicitly
  log_info "Deleting PVCs..."
  run "kubectl delete pvc -A -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # D) Namespaces next (REVERSE order of installation), and WAIT
  log_step "Deleting namespaces (reverse order of installation)"
  
  # Check timeout before starting namespace deletion
  if ! check_overall_timeout ${OVERALL_TIMEOUT_UNINSTALL}; then
    log_warn "Overall timeout reached, applying force cleanup for namespaces..."
  fi
  
  # Delete user and tenant namespaces first (dynamically created, depend on platform)
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
  
  # Delete main namespaces in REVERSE order of installation:
  # Installer order: platform -> infra-db -> (dns-zone) -> (mail-zone) -> backup-system
  # Uninstaller order: backup-system -> (mail-zone) -> (dns-zone) -> infra-db -> platform
  if [ "${FORCE}" = "true" ] || is_installed "BACKUP_SYSTEM_INSTALLED"; then
    delete_namespace "backup-system"
  fi
  if [ "${FORCE}" = "true" ] || kubectl get namespace mail-zone >/dev/null 2>&1; then
    delete_namespace "mail-zone"
  fi
  if [ "${FORCE}" = "true" ] || kubectl get namespace dns-zone >/dev/null 2>&1; then
    delete_namespace "dns-zone"
  fi
  if [ "${FORCE}" = "true" ] || is_installed "INFRA_DB_INSTALLED"; then
    delete_namespace "infra-db"
  fi
  if [ "${FORCE}" = "true" ] || is_installed "PLATFORM_INSTALLED"; then
    delete_namespace "platform"
  fi
  
  # Delete system namespaces in REVERSE order of installation:
  # Installer order: cert-manager -> Kyverno -> Flux
  # Uninstaller order: Flux -> Kyverno -> cert-manager
  if [ "${FORCE}" = "true" ] || is_installed "FLUX_INSTALLED"; then
    delete_namespace "flux-system"
  fi
  if [ "${FORCE}" = "true" ] || is_installed "KYVERNO_INSTALLED"; then
    delete_namespace "kyverno"
  fi
  if [ "${FORCE}" = "true" ] || is_installed "CERT_MANAGER_INSTALLED"; then
    delete_namespace "cert-manager"
  fi
  
  # E) Traefik middlewares and HelmChartConfig (reverse of installer: Traefik config is applied first)
  log_step "Deleting Traefik resources"
  log_info "Deleting Traefik security middlewares..."
  run "kubectl delete middleware security-headers rate-limit sql-injection-protection request-size-limit -n kube-system -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  log_info "Deleting HelmChartConfig (Traefik entrypoints)..."
  run "kubectl delete helmchartconfig traefik -n kube-system --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # F) ClusterIssuers (reverse of installer: ClusterIssuers are applied after cert-manager)
  if [ "${FORCE}" = "true" ] || is_installed "CERT_MANAGER_INSTALLED"; then
    log_info "Deleting ClusterIssuers..."
    run "kubectl delete clusterissuer --all --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  # G) Remaining webhooks (cluster-scoped) by label (cert-manager, Flux, etc.)
  # Note: Kyverno webhooks are handled in preflight to prevent API lock
  log_step "Deleting remaining webhooks"
  run "kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration -l app.kubernetes.io/part-of=voxeil --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete by name patterns if not labeled (backward compatibility - cert-manager, Flux, etc.)
  if [ "${FORCE}" = "true" ] || is_installed "CERT_MANAGER_INSTALLED"; then
    log_info "Deleting cert-manager webhooks (by name pattern)..."
    cert_webhooks="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations --request-timeout=10s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i cert-manager || true)"
    for webhook in ${cert_webhooks}; do
      run "kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \"${webhook}\" --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
  fi
  
  if [ "${FORCE}" = "true" ] || is_installed "FLUX_INSTALLED"; then
    log_info "Deleting Flux webhooks (by name pattern)..."
    flux_webhooks="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations --request-timeout=10s -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i flux || true)"
    for webhook in ${flux_webhooks}; do
      run "kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \"${webhook}\" --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    done
  fi
  
  # H) ClusterRoles / ClusterRoleBindings by label (reverse of installer: RBAC is applied in platform base)
  log_step "Deleting ClusterRoles and ClusterRoleBindings"
  run "kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/part-of=voxeil --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete by name (backward compatibility) - try multiple times if needed
  log_info "Deleting ClusterRoles by name..."
  for cr in controller-bootstrap user-operator; do
    if kubectl get clusterrole "${cr}" >/dev/null 2>&1; then
      run "kubectl delete clusterrole \"${cr}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
      # If still exists, try removing finalizers
      if kubectl get clusterrole "${cr}" >/dev/null 2>&1; then
        run "kubectl patch clusterrole \"${cr}\" -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge >/dev/null 2>&1 || true"
        run "kubectl delete clusterrole \"${cr}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
      fi
    fi
  done
  
  log_info "Deleting ClusterRoleBindings by name..."
  for crb in controller-bootstrap-binding; do
    if kubectl get clusterrolebinding "${crb}" >/dev/null 2>&1; then
      run "kubectl delete clusterrolebinding \"${crb}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
      # If still exists, try removing finalizers
      if kubectl get clusterrolebinding "${crb}" >/dev/null 2>&1; then
        run "kubectl patch clusterrolebinding \"${crb}\" -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge >/dev/null 2>&1 || true"
        run "kubectl delete clusterrolebinding \"${crb}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
      fi
    fi
  done
  
  # I) CRDs LAST by label (reverse of installer: CRDs are installed first for cert-manager/Kyverno/Flux)
  log_step "Deleting CRDs"
  run "kubectl delete crd -l app.kubernetes.io/part-of=voxeil --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  
  # Also delete by name patterns (backward compatibility)
  # Note: FORCE=true CRD deletions are deferred to Step F (after namespace deletion)
  if [ "${FORCE}" != "true" ] && is_installed "CERT_MANAGER_INSTALLED"; then
    log_info "Deleting cert-manager CRDs (by name pattern)..."
    run "kubectl delete crd -l app.kubernetes.io/name=cert-manager --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd certificates.cert-manager.io certificaterequests.cert-manager.io challenges.acme.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io orders.acme.cert-manager.io --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  if [ "${FORCE}" != "true" ] && is_installed "KYVERNO_INSTALLED"; then
    log_info "Deleting Kyverno CRDs (by name pattern)..."
    run "kubectl delete crd -l app.kubernetes.io/name=kyverno --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd policies.kyverno.io clusterpolicies.kyverno.io policyreports.wgpolicyk8s.io clusterpolicyreports.wgpolicyk8s.io --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  if [ "${FORCE}" != "true" ] && is_installed "FLUX_INSTALLED"; then
    log_info "Deleting Flux CRDs (by name pattern)..."
    run "kubectl delete crd -l app.kubernetes.io/name=flux --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  # J) Force-mode fallback cleanup for unlabeled leftovers (state missing)
  if [ "${FORCE}" = "true" ]; then
    log_step "Force-mode fallback cleanup (unlabeled leftovers)"
    
    # Delete unlabeled namespaces - try all voxeil namespaces regardless of label
    log_info "Cleaning up unlabeled namespaces..."
    for ns in platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager; do
      if kubectl get namespace "${ns}" >/dev/null 2>&1; then
        log_info "Deleting namespace: ${ns} (force mode)"
        delete_namespace "${ns}"
      fi
    done
    
    # Delete user-* and tenant-* namespaces - in force mode, delete all regardless of label
    user_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^user-' || true)"
    if [ -n "${user_namespaces}" ]; then
      for ns in ${user_namespaces}; do
        log_info "Deleting namespace: ${ns} (force mode)"
        delete_namespace "${ns}"
      done
    fi
    
    tenant_namespaces="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^tenant-' || true)"
    if [ -n "${tenant_namespaces}" ]; then
      for ns in ${tenant_namespaces}; do
        log_info "Deleting namespace: ${ns} (force mode)"
        delete_namespace "${ns}"
      done
    fi
    
    # Delete remaining cluster resources
    log_info "Cleaning up cluster roles and bindings..."
    for cr in controller-bootstrap user-operator; do
      if kubectl get clusterrole "${cr}" >/dev/null 2>&1; then
        run "kubectl patch clusterrole \"${cr}\" -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge >/dev/null 2>&1 || true"
        run "kubectl delete clusterrole \"${cr}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
      fi
    done
    for crb in controller-bootstrap-binding; do
      if kubectl get clusterrolebinding "${crb}" >/dev/null 2>&1; then
        run "kubectl patch clusterrolebinding \"${crb}\" -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge >/dev/null 2>&1 || true"
        run "kubectl delete clusterrolebinding \"${crb}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
      fi
    done
    
    # Remove lingering webhookconfigs again (idempotent)
    log_info "Cleaning up remaining webhookconfigs..."
    disable_admission_webhooks_preflight
    
    # Delete CRDs by patterns (name match, not labels) - LAST, after namespaces and webhooks
    log_info "Cleaning up CRDs by name pattern (kyverno/cert-manager/flux/toolkit)..."
    crds="$(kubectl get crd --request-timeout=10s -o name 2>/dev/null | grep -E '(kyverno|cert-manager|fluxcd|toolkit)' || true)"
    if [ -n "${crds}" ]; then
      echo "${crds}" | xargs -r -I {} kubectl delete {} --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    fi
    
    # Also delete CRDs by name patterns (from Step E, deferred here for FORCE=true case)
    log_info "Cleaning up CRDs by component patterns..."
    run "kubectl delete crd -l app.kubernetes.io/name=cert-manager --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd certificates.cert-manager.io certificaterequests.cert-manager.io challenges.acme.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io orders.acme.cert-manager.io --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd -l app.kubernetes.io/name=kyverno --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd policies.kyverno.io clusterpolicies.kyverno.io policyreports.wgpolicyk8s.io clusterpolicyreports.wgpolicyk8s.io --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
    run "kubectl delete crd -l app.kubernetes.io/name=flux --request-timeout=20s --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
  fi
  
  # K) Storage cleanup - PVs (unless --keep-volumes)
  # This is a final cleanup pass for any PVs that might have been missed
  if [ "${KEEP_VOLUMES}" != "true" ]; then
    log_step "Final cleanup: PersistentVolumes (leftover check)"
    # PVs might not have labels. Detect PVs whose claimRef.namespace is one of voxeil namespaces
    VOXEIL_NS_LIST="platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager"
    for ns in ${VOXEIL_NS_LIST}; do
      # Check PVs even if namespace doesn't exist (leftover PVs)
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
        log_info "Deleting leftover PVs for namespace ${ns}..."
        for pv in ${PVS}; do
          log_info "Processing PV ${pv}..."
          # Remove finalizers from PV first
          run "kubectl patch pv \"${pv}\" -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge >/dev/null 2>&1 || true"
          # Also remove claimRef to release the PV
          run "kubectl patch pv \"${pv}\" -p '{\"spec\":{\"claimRef\":null}}' --type=merge >/dev/null 2>&1 || true"
          # Wait a moment for patches to apply
          sleep 1
          # Delete PV
          run "kubectl delete pv \"${pv}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
          # If still exists after a moment, try again with more aggressive cleanup
          sleep 2
          if kubectl get pv "${pv}" >/dev/null 2>&1; then
            log_info "PV ${pv} still exists, forcing removal..."
            run "kubectl patch pv \"${pv}\" -p '{\"metadata\":{\"finalizers\":[]},\"spec\":{\"claimRef\":null}}' --type=merge >/dev/null 2>&1 || true"
            run "kubectl delete pv \"${pv}\" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true"
          fi
        done
      fi
    done
  else
    log_step "Skipping PersistentVolume cleanup (--keep-volumes)"
  fi
fi

# L) Node purge (--purge-node AND --force required)
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
    # Reset timeout check for purge-node phase (uninstall already completed)
    # Purge-node phase itself should be quick (k3s cleanup only)
    PURGE_NODE_PHASE_START=$(date +%s)
    PURGE_NODE_PHASE_TIMEOUT=300  # 5 minutes for k3s cleanup phase only
    
    # Stop and disable k3s service with timeout
    if command -v systemctl >/dev/null 2>&1; then
      log_info "Stopping k3s service..."
      run_with_timeout 30 "systemctl stop k3s" 2>/dev/null || {
        log_warn "k3s service stop timed out or failed, continuing..."
        # Try to kill k3s processes directly
        pkill -9 k3s 2>/dev/null || true
      }
      systemctl disable k3s 2>/dev/null || true
    fi
    
    # Run k3s uninstall script if available (with timeout)
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
      log_info "Running k3s-uninstall.sh (timeout: 120s)..."
      run_with_timeout 120 "/usr/local/bin/k3s-uninstall.sh" >/dev/null 2>&1 || {
        log_warn "k3s-uninstall.sh timed out or failed, continuing with filesystem cleanup..."
      }
    fi
    
    # Run k3s-killall.sh if available (with timeout)
    if [ -f /usr/local/bin/k3s-killall.sh ]; then
      log_info "Running k3s-killall.sh (timeout: 60s)..."
      run_with_timeout 60 "/usr/local/bin/k3s-killall.sh" >/dev/null 2>&1 || {
        log_warn "k3s-killall.sh timed out or failed, continuing with filesystem cleanup..."
      }
    fi
    
    # Remove k3s binaries and directories (fallback if scripts hang)
    log_info "Removing k3s binaries and directories..."
    rm -f /usr/local/bin/k3s /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr 2>/dev/null || true
    rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet /var/lib/cni /opt/cni /run/flannel /var/log/k3s 2>/dev/null || true
    rm -f /etc/systemd/system/k3s.service 2>/dev/null || true
    
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload 2>/dev/null || true
    fi
    
    # Remove /var/lib/voxeil (state registry)
    log_info "Removing /var/lib/voxeil..."
    rm -rf /var/lib/voxeil 2>/dev/null || true
    
    # Clean up Docker images if Docker is available
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      log_info "Cleaning up Voxeil Docker images..."
      # Remove voxeil images
      docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "(voxeil|ghcr.io/.*/voxeil)" | while read -r image; do
        log_info "Removing Docker image: ${image}"
        docker rmi "${image}" 2>/dev/null || true
      done
      # Also remove by pattern (in case of different naming)
      docker images | grep -E "voxeil|backup-runner|backup-service" | awk '{print $3}' | xargs -r docker rmi 2>/dev/null || true
      # Clean up dangling images
      docker image prune -f 2>/dev/null || true
    fi
    
    echo ""
    log_ok "Node purge complete - k3s and all Voxeil files removed"
    echo ""
  fi
fi

# M) Clean up filesystem files (unless --purge-node, which handles /var/lib/voxeil)
# NOTE: /tmp/voxeil.sh is NOT deleted - it is ephemeral and user-managed
log_step "Cleaning up filesystem files"
run "rm -rf /etc/voxeil 2>/dev/null || true"
run "rm -f /usr/local/bin/voxeil-ufw-apply 2>/dev/null || true"
run "rm -f /etc/systemd/system/voxeil-ufw-apply.service 2>/dev/null || true"
run "rm -f /etc/systemd/system/voxeil-ufw-apply.path 2>/dev/null || true"
run "rm -f /etc/fail2ban/jail.d/voxeil.conf 2>/dev/null || true"
run "rm -f /etc/fail2ban/filter.d/traefik-http.conf 2>/dev/null || true"
run "rm -f /etc/fail2ban/filter.d/traefik-auth.conf 2>/dev/null || true"
run "rm -f /etc/fail2ban/filter.d/mailcow-auth.conf 2>/dev/null || true"
run "rm -f /etc/fail2ban/filter.d/bind9.conf 2>/dev/null || true"
run "rm -f /etc/ssh/sshd_config.voxeil-backup.* 2>/dev/null || true"
# Note: Log directories (/var/log/traefik, /var/log/mailcow, /var/log/bind9) are kept
# to preserve logs. Remove manually if needed: rm -rf /var/log/{traefik,mailcow,bind9}
# Only remove /var/lib/voxeil if not doing node purge (purge handles it)
if [ "${PURGE_NODE}" != "true" ]; then
  run "rm -rf /var/lib/voxeil 2>/dev/null || true"
fi

# N) Clean up Docker images (optional, only if Docker is available)
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  log_step "Cleaning up Voxeil Docker images (optional)"
  log_info "Removing Voxeil-related Docker images..."
  # Remove voxeil images by pattern
  VOXEIL_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "(voxeil|ghcr.io/.*/voxeil|backup-runner|backup-service)" || true)
  if [ -n "${VOXEIL_IMAGES}" ]; then
    echo "${VOXEIL_IMAGES}" | while read -r image; do
      if [ -n "${image}" ]; then
        log_info "Removing Docker image: ${image}"
        docker rmi "${image}" 2>/dev/null || true
      fi
    done
  else
    log_info "No Voxeil Docker images found to remove"
  fi
  # Clean up dangling images (optional)
  log_info "Cleaning up dangling images..."
  docker image prune -f 2>/dev/null || true
else
  log_info "Docker not available, skipping image cleanup"
fi

if [ "${DRY_RUN}" != "true" ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload 2>/dev/null || true
fi

# Final verification pass (only if not dry-run)
if [ "${DRY_RUN}" != "true" ] && [ "${KUBECTL_AVAILABLE}" = "true" ]; then
  log_step "Final verification pass"
  
  # Check for any remaining namespaces
  REMAINING_NS="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^(platform|infra-db|dns-zone|mail-zone|backup-system|kyverno|flux-system|cert-manager|user-|tenant-)' || true)"
  if [ -n "${REMAINING_NS}" ]; then
    log_warn "Some namespaces still exist, attempting final cleanup..."
    for ns in ${REMAINING_NS}; do
      if kubectl get namespace "${ns}" >/dev/null 2>&1; then
        log_info "Final cleanup attempt for namespace: ${ns}"
        # Try to remove finalizers and delete one more time
        kubectl patch namespace "${ns}" -p '{"spec":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
        if command -v python3 >/dev/null 2>&1; then
          kubectl get namespace "${ns}" -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); data['spec']['finalizers']=[]; print(json.dumps(data))" | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
        elif command -v jq >/dev/null 2>&1; then
          kubectl get namespace "${ns}" -o json 2>/dev/null | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
        elif command -v sed >/dev/null 2>&1; then
          kubectl get namespace "${ns}" -o json 2>/dev/null | sed 's/"finalizers":\[[^]]*\]/"finalizers":[]/g' | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
        fi
        kubectl delete namespace "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
      fi
    done
  fi
  
  # Final check for ClusterRoles and ClusterRoleBindings
  for cr in controller-bootstrap user-operator; do
    if kubectl get clusterrole "${cr}" >/dev/null 2>&1; then
      log_info "Final cleanup: removing ClusterRole ${cr}..."
      kubectl patch clusterrole "${cr}" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      kubectl delete clusterrole "${cr}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    fi
  done
  for crb in controller-bootstrap-binding; do
    if kubectl get clusterrolebinding "${crb}" >/dev/null 2>&1; then
      log_info "Final cleanup: removing ClusterRoleBinding ${crb}..."
      kubectl patch clusterrolebinding "${crb}" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
      kubectl delete clusterrolebinding "${crb}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    fi
  done
  
  # Final check for leftover PVs
  if [ "${KEEP_VOLUMES}" != "true" ]; then
    VOXEIL_NS_LIST="platform infra-db dns-zone mail-zone backup-system kyverno flux-system cert-manager"
    for ns in ${VOXEIL_NS_LIST}; do
      if command -v python3 >/dev/null 2>&1; then
        PVS="$(kubectl get pv -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); [print(pv['metadata']['name']) for pv in data.get('items', []) if pv.get('spec', {}).get('claimRef', {}).get('namespace') == '${ns}']" 2>/dev/null || true)"
      elif command -v jq >/dev/null 2>&1; then
        PVS="$(kubectl get pv -o json 2>/dev/null | jq -r '.items[] | select(.spec.claimRef.namespace == "'${ns}'") | .metadata.name' 2>/dev/null || true)"
      else
        PVS="$(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null | grep -E "^[^\t]+\t${ns}$" | cut -f1 || true)"
      fi
      if [ -n "${PVS}" ]; then
        log_info "Final cleanup: removing leftover PVs for namespace ${ns}..."
        for pv in ${PVS}; do
          kubectl patch pv "${pv}" -p '{"metadata":{"finalizers":[]},"spec":{"claimRef":null}}' --type=merge >/dev/null 2>&1 || true
          kubectl delete pv "${pv}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
        done
      fi
    done
  fi
fi

echo ""
echo "=== Uninstall Complete ==="
if [ "${DRY_RUN}" = "true" ]; then
  log_info "Dry run - no changes were made"
else
  log_ok "All Voxeil Panel components removed"
  if [ "${KUBECTL_AVAILABLE}" = "true" ]; then
    echo ""
    log_info "Run 'bash /tmp/voxeil.sh doctor' to verify cleanup"
  fi
fi
