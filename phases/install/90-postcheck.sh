#!/usr/bin/env bash
# Install phase: Post-installation checks
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "install/90-postcheck"

# Ensure kubectl is available
ensure_kubectl || exit 1
check_kubectl_context || exit 1

# Use configurable timeout
TIMEOUT="${VOXEIL_WAIT_TIMEOUT}"

# Track results
FAILED=0
RESULTS=()

# Helper to check and record result
check_component() {
  local component="$1"
  local namespace="$2"
  local resource_type="$3"  # deployment or statefulset
  local resource_name="$4"
  local result=""
  local error_msg=""
  
  log_info "Checking ${component} (${resource_type}/${resource_name} in ${namespace})..."
  
  # Check if resource exists
  if ! run_kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" >/dev/null 2>&1; then
    result="SKIP"
    log_warn "  ${component}: Resource not found (may not be deployed)"
    RESULTS+=("${component}|SKIP|Resource not found")
    return 0
  fi
  
  # Wait for rollout
  if wait_rollout_status "${namespace}" "${resource_type}" "${resource_name}" "${TIMEOUT}"; then
    result="OK"
    RESULTS+=("${component}|OK|Ready")
  else
    result="FAIL"
    FAILED=$((FAILED + 1))
    error_msg=$(run_kubectl describe "${resource_type}" "${resource_name}" -n "${namespace}" 2>&1 | tail -20 || echo "Unable to describe resource")
    RESULTS+=("${component}|FAIL|${error_msg}")
  fi
}

# Check nodes
log_info "Checking cluster nodes..."
if run_kubectl get nodes >/dev/null 2>&1; then
  node_count=$(run_kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
  ready_count=$(run_kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
  
  if [ "${node_count}" -gt 0 ] && [ "${ready_count}" -eq "${node_count}" ]; then
    log_ok "All ${node_count} node(s) are Ready"
    RESULTS+=("Nodes|OK|${ready_count}/${node_count} Ready")
  else
    log_error "Nodes not ready: ${ready_count}/${node_count}"
    FAILED=$((FAILED + 1))
    RESULTS+=("Nodes|FAIL|${ready_count}/${node_count} Ready")
  fi
else
  log_error "Cannot get nodes"
  FAILED=$((FAILED + 1))
  RESULTS+=("Nodes|FAIL|Cannot access cluster")
fi

# Check platform deployments
check_component "Platform-Controller" "platform" "deployment" "controller"
check_component "Platform-Panel" "platform" "deployment" "panel"

# Check cert-manager deployments
check_component "CertManager" "cert-manager" "deployment" "cert-manager"
check_component "CertManager-Webhook" "cert-manager" "deployment" "cert-manager-webhook"
check_component "CertManager-CAInjector" "cert-manager" "deployment" "cert-manager-cainjector"

# Check kyverno deployments
check_component "Kyverno-Admission" "kyverno" "deployment" "kyverno-admission-controller"
check_component "Kyverno-Background" "kyverno" "deployment" "kyverno-background-controller"
check_component "Kyverno-Cleanup" "kyverno" "deployment" "kyverno-cleanup-controller"
check_component "Kyverno-Reports" "kyverno" "deployment" "kyverno-reports-controller"

# Check infra-db (if deployed)
check_component "InfraDB-Postgres" "infra-db" "statefulset" "postgres"
check_component "InfraDB-PGAdmin" "infra-db" "deployment" "pgadmin"

# Check dns-zone (if deployed)
check_component "DNS-Bind9" "dns-zone" "deployment" "bind9"

# Print summary table
echo ""
echo "=== Post-Installation Check Summary ==="
printf "%-30s %-6s %s\n" "Component" "Status" "Details"
printf "%-30s %-6s %s\n" "------------------------------" "------" "----------------------------------------"

for result in "${RESULTS[@]}"; do
  IFS='|' read -r component status details <<< "${result}"
  if [ "${status}" = "FAIL" ]; then
    printf "%-30s ${RED}%-6s${NC} %s\n" "${component}" "${status}" "${details:0:40}..."
  elif [ "${status}" = "OK" ]; then
    printf "%-30s ${GREEN}%-6s${NC} %s\n" "${component}" "${status}" "${details}"
  else
    printf "%-30s ${YELLOW}%-6s${NC} %s\n" "${component}" "${status}" "${details}"
  fi
done

echo ""

# Show detailed errors for failed components
if [ ${FAILED} -gt 0 ]; then
  echo "=== Failed Component Details ==="
  for result in "${RESULTS[@]}"; do
    IFS='|' read -r component status details <<< "${result}"
    if [ "${status}" = "FAIL" ]; then
      echo ""
      echo "--- ${component} ---"
      echo "${details}"
    fi
  done
  echo ""
  log_error "Post-installation check failed: ${FAILED} component(s) failed"
  exit 1
fi

log_ok "Post-installation checks complete - all components healthy"
exit 0
