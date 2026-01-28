#!/usr/bin/env bash
set -euo pipefail

# Quick script to fix Kyverno cleanup jobs
# This is the same logic as in installer.sh

NAMESPACE="kyverno"

echo "Checking Kyverno cleanup jobs for issues..."

# Check if kyverno namespace exists
if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Kyverno namespace not found, nothing to fix."
  exit 0
fi

# Find pods with ImagePullBackOff or ErrImagePull errors
failed_pods="$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/part-of=kyverno \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | \
  grep -E "(ImagePullBackOff|ErrImagePull)" | cut -f1 || true)"

fixed_count=0

# Get job names from failed pods and delete them
if [ -n "${failed_pods}" ]; then
  for pod in ${failed_pods}; do
    job_name="$(kubectl get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Job")].name}' 2>/dev/null || true)"
    if [ -n "${job_name}" ]; then
      echo "  Found failed cleanup job: ${job_name} (pod: ${pod})"
      if kubectl delete job "${job_name}" -n "${NAMESPACE}" --ignore-not-found=true 2>&1; then
        fixed_count=$((fixed_count + 1))
      fi
    fi
  done
  
  if [ ${fixed_count} -gt 0 ]; then
    echo "✓ Cleaned up ${fixed_count} failed cleanup job(s)."
  fi
else
  echo "No failed cleanup jobs found."
fi

# Update CronJobs with correct image
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KYVERNO_MANIFEST="${SCRIPT_DIR}/../infra/k8s/components/kyverno/install.yaml"

if [ -f "${KYVERNO_MANIFEST}" ]; then
  echo "Updating CronJobs with correct image..."
  if kubectl apply --server-side --force-conflicts -f "${KYVERNO_MANIFEST}" 2>&1; then
    echo "✓ CronJobs updated successfully."
    echo "New jobs will be created by CronJob with correct image (alpine/k8s:1.30.0)."
  else
    echo "⚠ Warning: Failed to update CronJobs, but this is non-critical."
  fi
else
  echo "⚠ Warning: Kyverno manifest not found at ${KYVERNO_MANIFEST}"
  echo "CronJobs will be updated on next installer run."
fi

if [ ${fixed_count} -eq 0 ] && [ -z "${failed_pods}" ]; then
  echo "✓ All cleanup jobs are healthy."
fi
