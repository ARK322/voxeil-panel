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
    
    # Check if pods permission exists (NEW)
    if kubectl get clusterrole user-operator -o yaml | grep -q "pods"; then
        test_pass "user-operator ClusterRole has pods permission"
    else
        test_fail "user-operator ClusterRole missing pods permission"
    fi
    
    # Check if update verb is NOT used (should be removed)
    if kubectl get clusterrole user-operator -o yaml | grep -q "update"; then
        test_warn "user-operator ClusterRole still has 'update' verb (should be removed)"
    else
        test_pass "user-operator ClusterRole does not use 'update' verb"
    fi
    
    # Check if watch verb is NOT used (should be removed)
    if kubectl get clusterrole user-operator -o yaml | grep -q "watch"; then
        test_warn "user-operator ClusterRole still has 'watch' verb (should be removed)"
    else
        test_pass "user-operator ClusterRole does not use 'watch' verb"
    fi
    
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

# Check template directories (NEW STRUCTURE: All templates in infra/k8s/templates/)
echo ""
echo "7. Checking template structure..."
if [ -d "infra/k8s/templates/user" ]; then
    test_pass "User templates directory exists (infra/k8s/templates/user)"
    
    REQUIRED_USER_TEMPLATES=("namespace.yaml" "resourcequota.yaml" "limitrange.yaml" "networkpolicy-deny-all.yaml" "controller-rolebinding.yaml")
    for tpl in "${REQUIRED_USER_TEMPLATES[@]}"; do
        if [ -f "infra/k8s/templates/user/${tpl}" ]; then
            test_pass "User template ${tpl} exists"
        else
            test_fail "User template ${tpl} missing"
        fi
    done
else
    test_fail "User templates directory not found (infra/k8s/templates/user)"
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

# Check for template duplication (old location should NOT exist)
if [ -d "apps/controller/templates/user" ]; then
    test_warn "Old user templates directory still exists (apps/controller/templates/user) - can be removed"
else
    test_pass "No old template duplication (apps/controller/templates/user removed)"
fi

# Check controller health
echo ""
echo "8. Checking controller health..."
CONTROLLER_POD="$(kubectl get pod -n platform -l app=controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "${CONTROLLER_POD}" ]; then
    if kubectl exec -n platform "${CONTROLLER_POD}" -- wget -q -O- http://localhost:8080/health 2>/dev/null | grep -q '"ok":true'; then
        test_pass "Controller health endpoint is OK"
    else
        test_fail "Controller health endpoint check failed"
    fi
else
    test_fail "Controller pod not found"
fi

# Test user create -> ns+pvc+netpol+db secret
echo ""
echo "9. Testing user create (namespace + PVC + NetPol + DB secret)..."
CONTROLLER_SVC="controller.platform.svc.cluster.local:8080"
CONTROLLER_TOKEN="${CONTROLLER_TOKEN:-}"
if [ -z "${CONTROLLER_TOKEN}" ]; then
    # Try to get token from platform-secrets
    CONTROLLER_TOKEN="$(kubectl get secret platform-secrets -n platform -o jsonpath='{.data.ADMIN_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"
fi

if [ -z "${CONTROLLER_TOKEN}" ]; then
    test_warn "CONTROLLER_TOKEN not set, skipping user create test"
else
    # Create test user
    TEST_USERNAME="smoketest-$(date +%s)"
    TEST_PASSWORD="Test123!Smoke"
    TEST_EMAIL="smoketest@example.com"
    
    USER_RESPONSE="$(kubectl run -it --rm --restart=Never curl-test --image=curlimages/curl:latest -n platform -- \
        curl -s -X POST "http://${CONTROLLER_SVC}/admin/users" \
        -H "Authorization: Bearer ${CONTROLLER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${TEST_USERNAME}\",\"password\":\"${TEST_PASSWORD}\",\"email\":\"${TEST_EMAIL}\",\"role\":\"user\"}" 2>/dev/null || echo '{"ok":false}')"
    
    if echo "${USER_RESPONSE}" | grep -q '"ok":true'; then
        test_pass "User created successfully"
        
        # Extract user ID
        USER_ID="$(echo "${USER_RESPONSE}" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 || true)"
        if [ -n "${USER_ID}" ]; then
            USER_NS="user-${USER_ID}"
            
            # Check namespace
            if kubectl get namespace "${USER_NS}" >/dev/null 2>&1; then
                test_pass "User namespace ${USER_NS} created"
            else
                test_fail "User namespace ${USER_NS} not found"
            fi
            
            # Check PVC
            if kubectl get pvc pvc-user-home -n "${USER_NS}" >/dev/null 2>&1; then
                test_pass "User home PVC created"
            else
                test_fail "User home PVC not found"
            fi
            
            # Check NetPol
            if kubectl get networkpolicy deny-all -n "${USER_NS}" >/dev/null 2>&1; then
                test_pass "User NetworkPolicy created"
            else
                test_fail "User NetworkPolicy not found"
            fi
            
            # Check DB secret
            if kubectl get secret db-conn -n "${USER_NS}" >/dev/null 2>&1; then
                test_pass "DB secret created in user namespace"
            else
                test_fail "DB secret not found in user namespace"
            fi
            
            # Test 2 site create -> ingress ok
            echo ""
            echo "10. Testing site create (2 sites, ingress check)..."
            
            # Create first site
            SITE1_DOMAIN="test1-${TEST_USERNAME}.example.com"
            SITE1_RESPONSE="$(kubectl run -it --rm --restart=Never curl-test1 --image=curlimages/curl:latest -n platform -- \
                curl -s -X POST "http://${CONTROLLER_SVC}/sites" \
                -H "Authorization: Bearer ${CONTROLLER_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"domain\":\"${SITE1_DOMAIN}\",\"cpu\":1,\"ramGi\":1,\"diskGi\":5}" 2>/dev/null || echo '{"ok":false}')"
            
            if echo "${SITE1_RESPONSE}" | grep -q '"slug"'; then
                test_pass "First site created successfully"
                SITE1_SLUG="$(echo "${SITE1_RESPONSE}" | grep -o '"slug":"[^"]*"' | cut -d'"' -f4 || true)"
                
                # Check deployment
                if kubectl get deployment "app-${SITE1_SLUG}" -n "${USER_NS}" >/dev/null 2>&1; then
                    test_pass "First site deployment created"
                else
                    test_fail "First site deployment not found"
                fi
                
                # Check ingress
                if kubectl get ingress "web-${SITE1_SLUG}" -n "${USER_NS}" >/dev/null 2>&1; then
                    INGRESS_HOST="$(kubectl get ingress "web-${SITE1_SLUG}" -n "${USER_NS}" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
                    if [ "${INGRESS_HOST}" = "${SITE1_DOMAIN}" ]; then
                        test_pass "First site ingress created with correct host"
                    else
                        test_fail "First site ingress host mismatch (expected: ${SITE1_DOMAIN}, got: ${INGRESS_HOST})"
                    fi
                else
                    test_fail "First site ingress not found"
                fi
            else
                test_fail "First site creation failed"
            fi
            
            # Create second site
            SITE2_DOMAIN="test2-${TEST_USERNAME}.example.com"
            SITE2_RESPONSE="$(kubectl run -it --rm --restart=Never curl-test2 --image=curlimages/curl:latest -n platform -- \
                curl -s -X POST "http://${CONTROLLER_SVC}/sites" \
                -H "Authorization: Bearer ${CONTROLLER_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"domain\":\"${SITE2_DOMAIN}\",\"cpu\":1,\"ramGi\":1,\"diskGi\":5}" 2>/dev/null || echo '{"ok":false}')"
            
            if echo "${SITE2_RESPONSE}" | grep -q '"slug"'; then
                test_pass "Second site created successfully"
                SITE2_SLUG="$(echo "${SITE2_RESPONSE}" | grep -o '"slug":"[^"]*"' | cut -d'"' -f4 || true)"
                
                # Check deployment
                if kubectl get deployment "app-${SITE2_SLUG}" -n "${USER_NS}" >/dev/null 2>&1; then
                    test_pass "Second site deployment created"
                else
                    test_fail "Second site deployment not found"
                fi
                
                # Check ingress
                if kubectl get ingress "web-${SITE2_SLUG}" -n "${USER_NS}" >/dev/null 2>&1; then
                    INGRESS_HOST="$(kubectl get ingress "web-${SITE2_SLUG}" -n "${USER_NS}" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
                    if [ "${INGRESS_HOST}" = "${SITE2_DOMAIN}" ]; then
                        test_pass "Second site ingress created with correct host"
                    else
                        test_fail "Second site ingress host mismatch (expected: ${SITE2_DOMAIN}, got: ${INGRESS_HOST})"
                    fi
                else
                    test_fail "Second site ingress not found"
                fi
                
                # Check both sites in same namespace
                DEPLOYMENTS="$(kubectl get deployment -n "${USER_NS}" -l voxeil.io/site=true --no-headers 2>/dev/null | wc -l || echo "0")"
                if [ "${DEPLOYMENTS}" -ge 2 ]; then
                    test_pass "Both sites in same user namespace"
                else
                    test_fail "Sites not in same user namespace (found ${DEPLOYMENTS} deployments)"
                fi
            else
                test_fail "Second site creation failed"
            fi
        else
            test_warn "Could not extract user ID from response"
        fi
    else
        test_fail "User creation failed"
        echo "   Response: ${USER_RESPONSE}"
    fi
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
