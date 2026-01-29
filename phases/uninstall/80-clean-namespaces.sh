#!/usr/bin/env bash
# Uninstall phase: Clean namespaces
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/../../lib/kube.sh"

log_phase "uninstall/80-clean-namespaces"

# Ensure kubectl is available
ensure_kubectl || exit 1

# Use configurable timeout
TIMEOUT="${VOXEIL_WAIT_TIMEOUT}"

# List of voxeil-owned namespaces (must have voxeil.io/owned=true label)
VOXEIL_NAMESPACES=(
  "platform"
  "cert-manager"
  "kyverno"
  "infra-db"
  "dns-zone"
  "mail-zone"
  "flux-system"
)

log_info "Waiting for namespaces to terminate (timeout: ${TIMEOUT}s)..."

# Wait for each namespace to be deleted
STUCK_NAMESPACES=()
for ns in "${VOXEIL_NAMESPACES[@]}"; do
  if ! run_kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log_info "Namespace ${ns} already deleted"
    continue
  fi
  
  log_info "Waiting for namespace ${ns} to terminate..."
  if ! wait_ns_deleted "${ns}" "${TIMEOUT}"; then
    STUCK_NAMESPACES+=("${ns}")
    log_warn "Namespace ${ns} is stuck in Terminating state"
  fi
done

# Handle stuck namespaces
if [ ${#STUCK_NAMESPACES[@]} -gt 0 ]; then
  log_warn "Found ${#STUCK_NAMESPACES[@]} stuck namespace(s), attempting safe cleanup..."
  
  for ns in "${STUCK_NAMESPACES[@]}"; do
    log_info "Investigating stuck namespace: ${ns}"
    
    # Verify ownership label
    local owned
    owned=$(run_kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.voxeil\.io/owned}' 2>/dev/null || echo "")
    if [ "${owned}" != "true" ]; then
      log_warn "Namespace ${ns} does not have voxeil.io/owned=true label, skipping force cleanup"
      continue
    fi
    
    # List remaining resources
    log_info "Checking remaining resources in namespace ${ns}..."
    
    # Get all resource types
    local resource_types
    resource_types=$(run_kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null | grep -v "events" || echo "")
    
    local has_resources=false
    for resource_type in ${resource_types}; do
      local count
      count=$(run_kubectl get "${resource_type}" -n "${ns}" --no-headers 2>/dev/null | wc -l || echo "0")
      if [ "${count}" -gt 0 ]; then
        has_resources=true
        log_info "Found ${count} ${resource_type} resource(s) in ${ns}"
        
        # Try to delete them
        log_info "Deleting remaining ${resource_type} resources in ${ns}..."
        run_kubectl delete "${resource_type}" --all -n "${ns}" --timeout=30s --ignore-not-found >/dev/null 2>&1 || true
      fi
    done
    
    # Wait a bit for deletions to propagate
    sleep 5
    
    # Check if namespace still exists
    if ! run_kubectl get namespace "${ns}" >/dev/null 2>&1; then
      log_ok "Namespace ${ns} deleted after resource cleanup"
      continue
    fi
    
    # Check for finalizers
    log_info "Checking finalizers on namespace ${ns}..."
    local finalizers
    finalizers=$(run_kubectl get namespace "${ns}" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
    
    if [ -n "${finalizers}" ]; then
      log_warn "Namespace ${ns} has finalizers: ${finalizers}"
      
      # Only remove finalizers if we own this namespace
      if [ "${owned}" = "true" ]; then
        log_info "Removing finalizers from owned namespace ${ns}..."
        
        # Patch namespace to remove finalizers
        run_kubectl patch namespace "${ns}" \
          --type=json \
          -p='[{"op": "remove", "path": "/metadata/finalizers"}]' \
          --timeout=30s >/dev/null 2>&1 || {
          log_warn "Failed to remove finalizers from ${ns}, may require manual intervention"
          continue
        }
        
        log_ok "Finalizers removed from ${ns}"
        
        # Wait a bit more
        sleep 3
        
        # Check again
        if ! run_kubectl get namespace "${ns}" >/dev/null 2>&1; then
          log_ok "Namespace ${ns} deleted after finalizer removal"
        else
          log_warn "Namespace ${ns} still exists after finalizer removal"
        fi
      else
        log_warn "Skipping finalizer removal for ${ns} (not owned by voxeil)"
      fi
    else
      log_warn "Namespace ${ns} has no finalizers but still exists"
    fi
  done
  
  # Final check for any remaining stuck namespaces
  REMAINING_STUCK=()
  for ns in "${STUCK_NAMESPACES[@]}"; do
    if run_kubectl get namespace "${ns}" >/dev/null 2>&1; then
      REMAINING_STUCK+=("${ns}")
    fi
  done
  
  if [ ${#REMAINING_STUCK[@]} -gt 0 ]; then
    log_error "The following namespaces are still stuck: ${REMAINING_STUCK[*]}"
    log_error "Manual intervention may be required"
    for ns in "${REMAINING_STUCK[@]}"; do
      log_info "Namespace ${ns} status:"
      run_kubectl get namespace "${ns}" -o yaml | grep -A 10 "status:" || true
    done
    # Don't fail here - let post-check handle it
  fi
else
  log_ok "All namespaces terminated successfully"
fi

log_ok "Namespace cleanup phase complete"
