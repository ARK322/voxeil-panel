#!/usr/bin/env bash
# Doctor phase: Health checks
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "doctor/20-health"

EXIT_CODE=0
TIMEOUT=60  # Shorter timeout for doctor checks

# Helper to check deployment/statefulset health
check_resource_health() {
  local namespace="$1"
  local resource_type="$2"  # deployment or statefulset
  local resource_name="$3"
  local component="$4"
  
  if ! run_kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" >/dev/null 2>&1; then
    log_warn "  ${component}: Not found (may not be deployed)"
    return 0
  fi
  
  local ready
  ready=$(run_kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  local desired
  desired=$(run_kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  
  if [ "${ready}" = "${desired}" ] && [ "${desired}" -gt 0 ]; then
    log_ok "  ${component}: Ready (${ready}/${desired})"
    return 0
  else
    log_error "  ${component}: Not ready (${ready}/${desired})"
    EXIT_CODE=1
    return 1
  fi
}

log_info "Checking critical deployments..."

# Check platform
check_resource_health "platform" "deployment" "controller" "Platform-Controller"
check_resource_health "platform" "deployment" "panel" "Platform-Panel"

# Check cert-manager
check_resource_health "cert-manager" "deployment" "cert-manager" "CertManager"
check_resource_health "cert-manager" "deployment" "cert-manager-webhook" "CertManager-Webhook"
check_resource_health "cert-manager" "deployment" "cert-manager-cainjector" "CertManager-CAInjector"

# Check kyverno
check_resource_health "kyverno" "deployment" "kyverno-admission-controller" "Kyverno-Admission"
check_resource_health "kyverno" "deployment" "kyverno-background-controller" "Kyverno-Background"
check_resource_health "kyverno" "deployment" "kyverno-cleanup-controller" "Kyverno-Cleanup"
check_resource_health "kyverno" "deployment" "kyverno-reports-controller" "Kyverno-Reports"

# Check infra-db (if deployed)
check_resource_health "infra-db" "statefulset" "postgres" "InfraDB-Postgres"
check_resource_health "infra-db" "deployment" "pgadmin" "InfraDB-PGAdmin"

# Check dns-zone (if deployed)
check_resource_health "dns-zone" "deployment" "bind9" "DNS-Bind9"

exit ${EXIT_CODE}
