#!/usr/bin/env bash
set -euo pipefail

# Verify that no Voxeil artifacts remain in the cluster
# Exit 0 only if NO voxeil artifacts remain

# CLI flags
TIMEOUT=180
INTERVAL=5
NO_WAIT=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --no-wait)
      NO_WAIT=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--timeout <seconds>] [--interval <seconds>] [--no-wait]"
      exit 1
      ;;
  esac
done

echo "=== Voxeil Clean Verification Script ==="
echo ""

# Check kubectl availability
if ! command -v kubectl >/dev/null 2>&1 || ! kubectl cluster-info >/dev/null 2>&1; then
  echo "⚠ kubectl not available or cluster not accessible"
  echo "  Cannot verify cluster resources"
  exit 1
fi

# Function to check and report resources
check_resources() {
  local resource_type="$1"
  local label_selector="${2:-app.kubernetes.io/part-of=voxeil}"
  local namespace_flag="${3:-}"
  
  local count
  count="$(kubectl get "${resource_type}" ${namespace_flag} -l "${label_selector}" --no-headers 2>/dev/null | wc -l || echo "0")"
  
  if [ "${count}" -gt 0 ]; then
    echo "  ⚠ Found ${count} ${resource_type} with label ${label_selector}:"
    kubectl get "${resource_type}" ${namespace_flag} -l "${label_selector}" 2>/dev/null || true
    echo ""
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
    return 1
  else
    echo "  ✓ No ${resource_type} found"
    return 0
  fi
}

# Function to run all checks once
run_checks_once() {
  EXIT_CODE=0
  ISSUES_FOUND=0
  
  echo "Checking for leftover Voxeil resources..."
  echo ""
  
  # 1) Check labeled resources
  echo "=== Checking resources labeled app.kubernetes.io/part-of=voxeil ==="
  
  check_resources "all" "app.kubernetes.io/part-of=voxeil" "-A" || EXIT_CODE=1
  check_resources "cm,secret,sa,role,rolebinding,ingress,networkpolicy" "app.kubernetes.io/part-of=voxeil" "-A" || EXIT_CODE=1
  check_resources "clusterrole,clusterrolebinding" "app.kubernetes.io/part-of=voxeil" "" || EXIT_CODE=1
  check_resources "validatingwebhookconfiguration,mutatingwebhookconfiguration" "app.kubernetes.io/part-of=voxeil" "" || EXIT_CODE=1
  check_resources "crd" "app.kubernetes.io/part-of=voxeil" "" || EXIT_CODE=1
  check_resources "pvc" "app.kubernetes.io/part-of=voxeil" "-A" || EXIT_CODE=1
  
  # 2) Check namespace leftovers
  echo ""
  echo "=== Checking for Voxeil namespaces ==="
  VOXEIL_NAMESPACES="$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^(platform|infra-db|dns-zone|mail-zone|kyverno|flux-system|cert-manager|user-|tenant-)' || true)"
  
  if [ -n "${VOXEIL_NAMESPACES}" ]; then
    echo "  ⚠ Found Voxeil-related namespaces:"
    echo "${VOXEIL_NAMESPACES}" | while read -r ns; do
      # Check if namespace is labeled
      if kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null | grep -q voxeil; then
        echo "    - ${ns} (labeled)"
      else
        echo "    - ${ns} (unlabeled - potential leftover)"
      fi
    done
    echo ""
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil namespaces found"
  fi
  
  # 3) Check PV leftovers
  echo ""
  echo "=== Checking PersistentVolumes ==="
  VOXEIL_PVS=0
  VOXEIL_NS_LIST="platform infra-db dns-zone mail-zone kyverno flux-system cert-manager"
  
  for ns in ${VOXEIL_NS_LIST}; do
    # Check if namespace exists
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      # Find PVs for this namespace
      pvs=""
      if command -v python3 >/dev/null 2>&1; then
        pvs="$(kubectl get pv -o json 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); [print(pv['metadata']['name']) for pv in data.get('items', []) if pv.get('spec', {}).get('claimRef', {}).get('namespace') == '${ns}']" 2>/dev/null || true)"
      elif command -v jq >/dev/null 2>&1; then
        pvs="$(kubectl get pv -o json 2>/dev/null | jq -r '.items[] | select(.spec.claimRef.namespace == "'${ns}'") | .metadata.name' 2>/dev/null || true)"
      else
        # Fallback: get all PVs and check claimRef manually
        pvs="$(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null | grep -E "^[^\t]+\t${ns}$" | cut -f1 || true)"
      fi
      
      if [ -n "${pvs}" ]; then
        echo "  ⚠ Found PVs for namespace ${ns}:"
        echo "${pvs}" | while read -r pv; do
          echo "    - ${pv}"
        done
        VOXEIL_PVS=1
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
        EXIT_CODE=1
      fi
    fi
  done
  
  if [ ${VOXEIL_PVS} -eq 0 ]; then
    echo "  ✓ No Voxeil-related PVs found"
  fi
  
  # 4) Check for webhook configs by pattern (kyverno, cert-manager, flux)
  echo ""
  echo "=== Checking webhook configurations (by pattern) ==="
  VOXEIL_WEBHOOKS_PATTERN="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -iE '(kyverno|cert-manager|flux|toolkit)' || true)"
  
  if [ -n "${VOXEIL_WEBHOOKS_PATTERN}" ]; then
    echo "  ⚠ Found Voxeil webhook configurations:"
    echo "${VOXEIL_WEBHOOKS_PATTERN}" | while read -r wh; do
      echo "    - ${wh}"
    done
    echo ""
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil webhook configurations found"
  fi
  
  # 5) Check for CRDs by pattern
  echo ""
  echo "=== Checking CRDs (by pattern) ==="
  VOXEIL_CRDS_PATTERN="$(kubectl get crd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '(kyverno|cert-manager|fluxcd|toolkit)' || true)"
  
  if [ -n "${VOXEIL_CRDS_PATTERN}" ]; then
    echo "  ⚠ Found Voxeil CRDs:"
    echo "${VOXEIL_CRDS_PATTERN}" | while read -r crd; do
      echo "    - ${crd}"
    done
    echo ""
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
    EXIT_CODE=1
  else
    echo "  ✓ No Voxeil CRDs found"
  fi
  
  # 6) Check for stuck Terminating namespaces
  echo ""
  echo "=== Checking for stuck Terminating namespaces ==="
  TERMINATING_NS="$(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -E '\tTerminating$' | cut -f1 || true)"
  
  if [ -n "${TERMINATING_NS}" ]; then
    echo "  ⚠ Found stuck Terminating namespaces:"
    echo "${TERMINATING_NS}" | while read -r ns; do
      echo "    - ${ns}"
    done
    echo ""
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
    EXIT_CODE=1
  else
    echo "  ✓ No stuck Terminating namespaces found"
  fi
  
  # 7) Check for state file
  echo ""
  echo "=== Checking filesystem state ==="
  if [ -f /var/lib/voxeil/install.state ]; then
    echo "  ⚠ State file found at /var/lib/voxeil/install.state"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
    EXIT_CODE=1
  else
    echo "  ✓ No state file found"
  fi
  
  return ${EXIT_CODE}
}

# Wait for resources to be cleaned up with timeout
wait_for_clean() {
  local timeout="${1:-180}"
  local interval="${2:-5}"
  local start_time=$(date +%s)
  local elapsed=0
  
  while [ ${elapsed} -lt ${timeout} ]; do
    if run_checks_once; then
      return 0
    fi
    
    elapsed=$(($(date +%s) - start_time))
    if [ ${elapsed} -lt ${timeout} ]; then
      echo ""
      echo "[INFO] Waiting for cluster to become clean... elapsed=${elapsed}s / timeout=${timeout}s"
      sleep ${interval}
      echo ""
    fi
  done
  
  return 1
}

# Main execution
if [ "${NO_WAIT}" = "true" ]; then
  # Run once and exit
  run_checks_once
  EXIT_CODE=$?
  
  echo ""
  echo "=== Summary ==="
  if [ ${EXIT_CODE} -eq 0 ]; then
    echo "✓ System is clean - no Voxeil resources found"
    echo ""
    exit 0
  else
    echo "⚠ System has leftover Voxeil resources"
    echo ""
    echo "To clean up, run:"
    echo "  bash voxeil.sh uninstall --force"
    echo "  or: bash cmd/uninstall.sh --force"
    echo ""
    exit 1
  fi
else
  # Wait loop with timeout
  if wait_for_clean "${TIMEOUT}" "${INTERVAL}"; then
    echo ""
    echo "=== Summary ==="
    echo "✓ System is clean - no Voxeil resources found"
    echo ""
    exit 0
  else
    # Timeout reached
    echo ""
    echo "=== Summary ==="
    echo "⚠ Timeout reached (${TIMEOUT}s) - system still has leftover Voxeil resources"
    echo ""
    echo "To clean up, run:"
    echo "  bash /tmp/voxeil.sh uninstall --force"
    echo ""
    exit 1
  fi
fi
