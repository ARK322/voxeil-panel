#!/usr/bin/env bash
# Voxeil Panel Smoke Test Script
# Tests basic functionality after installation

set -euo pipefail

echo "=== VOXEIL PANEL SMOKE TEST ==="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"

test_count=0
pass_count=0
fail_count=0

test_pass() {
    test_count=$((test_count + 1))
    pass_count=$((pass_count + 1))
    echo -e "${PASS} $1"
}

test_fail() {
    test_count=$((test_count + 1))
    fail_count=$((fail_count + 1))
    echo -e "${FAIL} $1"
    if [ -n "${2:-}" ]; then
        echo "   ${2}"
    fi
}

test_warn() {
    echo -e "${WARN} $1"
}

# Check kubectl access
echo "1. Checking kubectl access..."
if kubectl cluster-info >/dev/null 2>&1; then
    test_pass "kubectl can access cluster"
else
    test_fail "kubectl cannot access cluster"
    exit 1
fi

# Check namespaces
echo ""
echo "2. Checking required namespaces..."
REQUIRED_NS=("platform" "infra-db" "backup-system" "dns-zone" "mail-zone" "cert-manager" "kyverno" "flux-system")
for ns in "${REQUIRED_NS[@]}"; do
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
        test_pass "Namespace ${ns} exists"
    else
        test_fail "Namespace ${ns} missing"
    fi
done

# Check platform deployments
echo ""
echo "3. Checking platform deployments..."
if kubectl get deployment controller -n platform >/dev/null 2>&1; then
    if kubectl wait --for=condition=Available deployment/controller -n platform --timeout=10s >/dev/null 2>&1; then
        test_pass "Controller deployment is available"
    else
        test_fail "Controller deployment is not available"
    fi
else
    test_fail "Controller deployment not found"
fi

if kubectl get deployment panel -n platform >/dev/null 2>&1; then
    if kubectl wait --for=condition=Available deployment/panel -n platform --timeout=10s >/dev/null 2>&1; then
        test_pass "Panel deployment is available"
    else
        test_fail "Panel deployment is not available"
    fi
else
    test_fail "Panel deployment not found"
fi

# Check infra-db
echo ""
echo "4. Checking infra-db..."
if kubectl get statefulset postgres -n infra-db >/dev/null 2>&1; then
    if kubectl wait --for=condition=Ready pod -l app=postgres -n infra-db --timeout=10s >/dev/null 2>&1; then
        test_pass "Postgres StatefulSet is ready"
    else
        test_fail "Postgres StatefulSet is not ready"
    fi
else
    test_fail "Postgres StatefulSet not found"
fi

# Check NetworkPolicy
echo ""
echo "5. Checking NetworkPolicy configuration..."
if kubectl get networkpolicy postgres-ingress -n infra-db >/dev/null 2>&1; then
    test_pass "infra-db NetworkPolicy exists"
    
    # Check if it allows tenant namespaces
    if kubectl get networkpolicy postgres-ingress -n infra-db -o yaml | grep -q "voxeil.io/tenant"; then
        test_pass "infra-db NetworkPolicy allows tenant namespaces"
    else
        test_warn "infra-db NetworkPolicy may not allow tenant namespaces (check manually)"
    fi
else
    test_fail "infra-db NetworkPolicy not found"
fi

# Check RBAC
echo ""
echo "6. Checking RBAC configuration..."
if kubectl get clusterrole user-operator >/dev/null 2>&1; then
    test_pass "user-operator ClusterRole exists"
    
    # Check if edit role is NOT used
    if kubectl get clusterrole edit >/dev/null 2>&1; then
        test_warn "edit ClusterRole still exists (should not be used in RoleBindings)"
    fi
else
    test_fail "user-operator ClusterRole not found"
fi

if kubectl get serviceaccount controller-sa -n platform >/dev/null 2>&1; then
    test_pass "controller-sa ServiceAccount exists"
else
    test_fail "controller-sa ServiceAccount not found"
fi

# Check template directories
echo ""
echo "7. Checking template structure..."
if [ -d "apps/controller/templates/user" ]; then
    test_pass "User templates directory exists (apps/controller/templates/user)"
    
    REQUIRED_USER_TEMPLATES=("namespace.yaml.tpl" "resourcequota.yaml.tpl" "limitrange.yaml.tpl" "networkpolicy-deny-all.yaml.tpl" "controller-rolebinding.yaml.tpl")
    for tpl in "${REQUIRED_USER_TEMPLATES[@]}"; do
        if [ -f "apps/controller/templates/user/${tpl}" ]; then
            test_pass "User template ${tpl} exists"
        else
            test_fail "User template ${tpl} missing"
        fi
    done
else
    test_fail "User templates directory not found"
fi

if [ -d "infra/k8s/templates/tenant" ]; then
    test_pass "Tenant templates directory exists (infra/k8s/templates/tenant)"
    
    REQUIRED_TENANT_TEMPLATES=("resourcequota.yaml" "limitrange.yaml" "networkpolicy-deny-all.yaml" "networkpolicy-allow-ingress.yaml" "networkpolicy-allow-egress.yaml")
    for tpl in "${REQUIRED_TENANT_TEMPLATES[@]}"; do
        if [ -f "infra/k8s/templates/tenant/${tpl}" ]; then
            test_pass "Tenant template ${tpl} exists"
        else
            test_fail "Tenant template ${tpl} missing"
        fi
    done
else
    test_fail "Tenant templates directory not found"
fi

# Check for template duplication (should NOT exist)
if [ -d "infra/k8s/templates/user" ]; then
    test_fail "Template duplication: infra/k8s/templates/user should not exist"
else
    test_pass "No template duplication (infra/k8s/templates/user removed)"
fi

# Summary
echo ""
echo "=== TEST SUMMARY ==="
echo "Total tests: ${test_count}"
echo -e "${GREEN}Passed: ${pass_count}${NC}"
if [ ${fail_count} -gt 0 ]; then
    echo -e "${RED}Failed: ${fail_count}${NC}"
    exit 1
else
    echo -e "${GREEN}Failed: ${fail_count}${NC}"
    echo ""
    echo "All smoke tests passed! ✓"
    exit 0
fi
