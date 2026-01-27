#!/usr/bin/env bash
# Quick check script for image issues
# Usage: bash scripts/quick-check.sh

echo "=== Quick Pod Status Check ==="
echo ""

echo "1. All pods in platform namespace:"
kubectl get pods -n platform

echo ""
echo "2. Panel pods detailed:"
kubectl get pods -n platform -l app=panel -o wide

echo ""
echo "3. Controller pods detailed:"
kubectl get pods -n platform -l app=controller -o wide

echo ""
echo "4. Checking for image pull errors..."
PANEL_PODS=$(kubectl get pods -n platform -l app=panel -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "${PANEL_PODS}" ]; then
  for pod in ${PANEL_PODS}; do
    echo "--- Panel Pod: ${pod} ---"
    kubectl get pod "${pod}" -n platform -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null | python3 -m json.tool 2>/dev/null || kubectl describe pod "${pod}" -n platform | grep -A 5 "State:" || echo "  Status: $(kubectl get pod "${pod}" -n platform -o jsonpath='{.status.phase}')"
    echo ""
  done
fi

CONTROLLER_PODS=$(kubectl get pods -n platform -l app=controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "${CONTROLLER_PODS}" ]; then
  for pod in ${CONTROLLER_PODS}; do
    echo "--- Controller Pod: ${pod} ---"
    kubectl get pod "${pod}" -n platform -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null | python3 -m json.tool 2>/dev/null || kubectl describe pod "${pod}" -n platform | grep -A 5 "State:" || echo "  Status: $(kubectl get pod "${pod}" -n platform -o jsonpath='{.status.phase}')"
    echo ""
  done
fi

echo "5. Image pull errors (if any):"
kubectl get pods -n platform -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
errors = []
for item in data.get('items', []):
    for container in item.get('status', {}).get('containerStatuses', []):
        waiting = container.get('state', {}).get('waiting', {})
        if waiting:
            reason = waiting.get('reason', '')
            if 'ImagePull' in reason or 'ErrImage' in reason:
                errors.append({
                    'pod': item['metadata']['name'],
                    'reason': reason,
                    'message': waiting.get('message', '')
                })
if errors:
    for err in errors:
        print(f\"Pod: {err['pod']}\")
        print(f\"  Reason: {err['reason']}\")
        if err['message']:
            print(f\"  Message: {err['message']}\")
        print()
else:
    print('✓ No image pull errors found')
" 2>/dev/null || echo "Could not parse pod status"

echo ""
echo "6. Expected images:"
echo "Panel: $(kubectl get deployment panel -n platform -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo 'NOT FOUND')"
echo "Controller: $(kubectl get deployment controller -n platform -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo 'NOT FOUND')"
