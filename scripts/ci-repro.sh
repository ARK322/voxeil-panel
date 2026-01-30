#!/bin/bash
# CI Reproduction Script
# Runs the same checks as GitHub Actions workflows to identify failures

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILED=0
TOTAL_STEPS=0

# Function to run a step and capture output
run_step() {
    local step_name="$1"
    local command="$2"
    
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
    echo ""
    echo "=========================================="
    echo "STEP $TOTAL_STEPS: $step_name"
    echo "=========================================="
    echo "Command: $command"
    echo ""
    
    local output_file="/tmp/ci-repro-step-${TOTAL_STEPS}.log"
    local exit_code=0
    
    # Run command and capture output
    eval "$command" > "$output_file" 2>&1 || exit_code=$?
    
    # Show first 200 lines of output
    echo "--- Output (first 200 lines) ---"
    head -n 200 "$output_file" || true
    echo ""
    echo "--- Exit Code: $exit_code ---"
    
    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}✗ FAILED${NC}"
        FAILED=$((FAILED + 1))
        echo "Full output saved to: $output_file"
    else
        echo -e "${GREEN}✓ PASSED${NC}"
    fi
    
    return $exit_code
}

echo "=========================================="
echo "CI REPRODUCTION SCRIPT"
echo "=========================================="
echo "This script runs the same checks as GitHub Actions"
echo ""

# Check prerequisites
echo "Checking prerequisites..."
command -v node >/dev/null 2>&1 || { echo "Error: node is required"; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "Error: npm is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required"; exit 1; }
command -v shellcheck >/dev/null 2>&1 || { echo "Error: shellcheck is required"; exit 1; }
command -v kubeconform >/dev/null 2>&1 || { echo "Warning: kubeconform not found, will skip kubeconform checks"; }

# ==========================================
# FROM ci.yml - lint job
# ==========================================
run_step "Install dependencies (npm ci --workspaces)" \
    "npm ci --workspaces" || true

run_step "Run ESLint (apps/controller)" \
    "npm run lint --workspace=apps/controller" || true

# ==========================================
# FROM ci.yml - test job
# ==========================================
run_step "Run tests (apps/controller)" \
    "npm test --workspace=apps/controller" || true

# ==========================================
# FROM ci.yml - syntax-check job
# ==========================================
run_step "JavaScript syntax check" \
    "find apps/controller -name '*.js' -type f | while read file; do echo \"Checking \$file\"; node --check \"\$file\" || exit 1; done" || true

# ==========================================
# FROM ci.yml - yaml-validation job
# ==========================================
# Create Python validation scripts
cat > /tmp/validate_yaml.py << 'PYEOF'
import yaml
import sys
import os
file_path = sys.argv[1]
try:
    with open(file_path, 'r') as f:
        list(yaml.safe_load_all(f))
    print(f'  ✓ Valid: {file_path}')
except yaml.YAMLError as e:
    print(f'  ✗ YAML Error in {file_path}: {e}')
    sys.exit(1)
except Exception as e:
    print(f'  ✗ Error in {file_path}: {e}')
    sys.exit(1)
PYEOF

cat > /tmp/validate_yaml_single.py << 'PYEOF'
import yaml
import sys
file_path = sys.argv[1]
try:
    with open(file_path, 'r') as f:
        yaml.safe_load(f)
    print(f'  ✓ Valid: {file_path}')
except yaml.YAMLError as e:
    print(f'  ✗ YAML Error in {file_path}: {e}')
    sys.exit(1)
except Exception as e:
    print(f'  ✗ Error in {file_path}: {e}')
    sys.exit(1)
PYEOF

# Install PyYAML if needed
python3 -c "import yaml" 2>/dev/null || {
    echo "Installing PyYAML..."
    pip3 install PyYAML --quiet || {
        echo "Warning: Failed to install PyYAML, skipping YAML validation"
    }
}

run_step "Validate Kubernetes YAML syntax" \
    "find infra/k8s -name '*.yaml' -o -name '*.yml' | while read file; do echo \"Validating \$file\"; python3 /tmp/validate_yaml.py \"\$file\" || exit 1; done" || true

run_step "Validate GitHub Actions workflows YAML" \
    "find .github/workflows -name '*.yaml' -o -name '*.yml' | while read file; do echo \"Validating \$file\"; python3 /tmp/validate_yaml_single.py \"\$file\" || exit 1; done" || true

# kubeconform check
if command -v kubeconform >/dev/null 2>&1; then
    run_step "Validate Kubernetes schemas (kubeconform)" \
        "find infra/k8s -name '*.yaml' -o -name '*.yml' | while read file; do if grep -q 'PLACEHOLDER\\|REPLACE_' \"\$file\" 2>/dev/null; then echo \"Skipping template file: \$file\"; continue; fi; if echo \"\$file\" | grep -qE 'infra/k8s/components/(cert-manager|kyverno)'; then echo \"Skipping vendor YAML: \$file\"; continue; fi; if echo \"\$file\" | grep -qE 'kustomization\\.ya?ml\$'; then echo \"Skipping kustomization file: \$file\"; continue; fi; echo \"Validating schema: \$file\"; kubeconform -strict -summary \"\$file\" || exit 1; done" || true
else
    echo -e "${YELLOW}⚠ Skipping kubeconform (not installed)${NC}"
fi

# ==========================================
# FROM ci.yml - bash-validation job
# ==========================================
run_step "ShellCheck validation" \
    "find . -name '*.sh' -type f | while read file; do echo \"Validating \$file\"; shellcheck -e SC1091 \"\$file\" || exit 1; done" || true

# ==========================================
# FROM installer-check.yml - bash syntax
# ==========================================
run_step "Bash syntax validation (voxeil.sh)" \
    "bash -n voxeil.sh" || true

run_step "Bash syntax validation (cmd/*.sh)" \
    "find cmd -name '*.sh' -type f | while read -r f; do bash -n \"\$f\" || exit 1; done" || true

run_step "Bash syntax validation (lib/*.sh)" \
    "find lib -name '*.sh' -type f | while read -r f; do bash -n \"\$f\" || exit 1; done" || true

run_step "Bash syntax validation (phases/**/*.sh)" \
    "find phases -name '*.sh' -type f | while read -r f; do bash -n \"\$f\" || exit 1; done" || true

run_step "Bash syntax validation (tools/**/*.sh)" \
    "find tools -name '*.sh' -type f | while read -r f; do bash -n \"\$f\" || exit 1; done" || true

# ==========================================
# FROM installer-check.yml - safety checks
# ==========================================
run_step "Detect unsafe webhook patching" \
    "FILES=\"\$(git ls-files 'voxeil.sh' 'cmd/*.sh' 'lib/*.sh' 'phases/**/*.sh' 'tools/**/*.sh' || true)\"; if [ -z \"\$FILES\" ]; then echo '⚠️ No matching files found to scan'; exit 0; fi; if echo \"\$FILES\" | xargs -r grep -nE 'kubectl patch .*webhookconfiguration .*--type=json' | grep -v '^[^:]*:[^:]*:.*#' | grep -v 'echo.*kubectl patch' | grep -q . ; then echo '❌ Unsafe kubectl patch --type=json on webhookconfiguration'; exit 1; fi; if echo \"\$FILES\" | xargs -r grep -nE '\\{\"webhooks\":\\[\\{\"failurePolicy\"' | grep -v '^[^:]*:[^:]*:.*#' | grep -v 'echo.*webhooks' | grep -q . ; then echo '❌ Unsafe webhook array overwrite detected'; exit 1; fi" || true

run_step "Detect dangerous RBAC deletes" \
    "if grep -R --line-number --exclude-dir=.git --exclude-dir=.github -E 'kubectl delete (clusterrole|clusterrolebinding).*(system:|kube-|cluster-admin)' . | grep -v '^[^:]*:[^:]*:.*#' | grep -v 'echo.*kubectl delete' | grep -q . ; then echo '❌ Dangerous clusterrole/clusterrolebinding delete detected'; exit 1; fi" || true

run_step "Check kubectl delete safety" \
    "BAD=\$(grep -R --line-number 'kubectl delete' cmd phases lib | grep -v 'request-timeout' | grep -v '\\[DRY-RUN\\]' | grep -v '^[^:]*:[^:]*:.*#' | grep -v 'echo.*kubectl delete' || true); if [ -n \"\$BAD\" ]; then echo \"⚠️ kubectl delete without --request-timeout:\"; echo \"\$BAD\"; exit 1; fi" || true

run_step "Detect infinite loops" \
    "FILES=\"\$(git ls-files 'voxeil.sh' 'cmd/*.sh' 'lib/*.sh' 'phases/**/*.sh' 'tools/**/*.sh' || true)\"; if [ -z \"\$FILES\" ]; then exit 0; fi; if echo \"\$FILES\" | xargs -r grep -nE 'while true|while\\s+\\[\\s*1\\s*\\]' ; then echo '❌ Infinite loop detected'; exit 1; fi" || true

run_step "Check Kyverno webhook bootstrap logic" \
    "if ! grep -R 'kyverno' infra/k8s phases 2>/dev/null | grep -v '^Binary' | head -1; then echo '❌ Kyverno configuration not found'; exit 1; fi" || true

run_step "Check Traefik readiness verification" \
    "if ! grep -R 'traefik' infra/k8s/base/ingress tools/ops 2>/dev/null | grep -v '^Binary' | head -1; then echo '❌ Traefik configuration not found'; exit 1; fi" || true

run_step "Check uninstaller preflight webhook neutralization" \
    "if [ ! -f phases/uninstall/00-preflight.sh ]; then echo '❌ Uninstaller preflight script not found'; exit 1; fi" || true

# ==========================================
# Summary
# ==========================================
echo ""
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo "Total steps: $TOTAL_STEPS"
echo "Failed steps: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ $FAILED step(s) failed${NC}"
    echo ""
    echo "Review the output above for details."
    echo "Full logs are saved in /tmp/ci-repro-step-*.log"
    exit 1
fi
