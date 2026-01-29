# YAML/Kubernetes Manifest Fix Plan

**Date:** 2024-12-19  
**Source:** Extracted from `docs/architecture-audit.md`  
**Scope:** Only YAML/Kubernetes manifest fixes that are safe and non-breaking

---

## Summary

After reviewing the architectural audit and examining all YAML manifests, **no critical YAML bugs were identified**. The audit primarily focuses on architectural decisions (shared DB, single node, etc.) and application code issues (retry logic, operation tracking), not YAML correctness.

However, a few **minor best-practice improvements** were identified that are safe to apply.

---

## Classification

### A) SAFE TO FIX NOW

Minor best-practice improvements that don't change behavior:

1. **Add labels to StatefulSet metadata** (consistency)
   - File: `infra/k8s/components/infra-db/postgres-statefulset.yaml`
   - Issue: StatefulSet metadata lacks labels (only pod template has labels)
   - Risk: Low
   - Action: FIX

2. **Add labels to Service metadata** (consistency)
   - File: `infra/k8s/components/infra-db/postgres-service.yaml`
   - Issue: Service metadata lacks labels (selector works, but labels improve consistency)
   - Risk: Low
   - Action: FIX

### B) NOT SAFE (DOCUMENT ONLY)

Architectural decisions that are intentionally left as-is:

1. **Shared PostgreSQL Database**
   - Finding: Single PostgreSQL instance shared by all tenants
   - Why not safe: This is an architectural decision, not a YAML bug
   - Action: DOCUMENT (already documented in audit)

2. **Controller Cluster-Wide RBAC**
   - Finding: Controller has cluster-wide namespace permissions
   - Why not safe: This is intentional and mitigated by Kyverno policies
   - Action: DOCUMENT (audit confirms this is correct)

3. **NetworkPolicy Allows Egress to Shared DB**
   - Finding: All user namespaces can reach PostgreSQL
   - Why not safe: This is necessary for functionality (architectural decision)
   - Action: DOCUMENT (audit confirms this is acceptable)

4. **local-path Storage Class**
   - Finding: All PVCs use `local-path` (node-local storage)
   - Why not safe: This is an intentional architectural decision for single-node k3s
   - Action: DOCUMENT (audit confirms this is acceptable)

5. **No Finalizers on Controller-Managed Resources**
   - Finding: Resources created by controller don't have finalizers
   - Why not safe: This requires controller code changes, not YAML changes
   - Action: DOCUMENT (uninstall script handles this reactively)

6. **pgAdmin Runs as Root**
   - Finding: pgAdmin deployment has `runAsUser: 0`
   - Why not safe: This is intentional (documented in comments, required for pgAdmin)
   - Action: DOCUMENT (already has inline comments explaining why)

### C) ACCEPTABLE TRADE-OFF (NO ACTION)

These are intentional architectural decisions that work for the target scale:

1. **Single PostgreSQL Instance** - ✅ Acceptable for single-node, <100 tenants
2. **Single Controller Instance** - ✅ Acceptable for single-node deployment
3. **local-path Storage** - ✅ Acceptable for single-node k3s
4. **No Multi-Region/HA** - ✅ Acceptable for current target

---

## Detailed Findings

### Finding 1: PostgreSQL StatefulSet Missing Labels

**File:** `infra/k8s/components/infra-db/postgres-statefulset.yaml`

**Problem:**
- StatefulSet metadata (line 3-5) has no labels
- Only pod template (line 14-15) has `app: postgres` label
- Best practice: StatefulSet metadata should have labels for consistency and selector matching

**Current State:**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: infra-db
spec:
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
```

**Why Safe:**
- Adding labels to StatefulSet metadata doesn't change behavior
- Labels are purely for organization/selection
- No functional impact

**Risk Level:** Low

**Action:** FIX

**Proposed Change:**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: infra-db
  labels:
    app: postgres
    app.kubernetes.io/part-of: voxeil
    app.kubernetes.io/component: database
spec:
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
```

---

### Finding 2: PostgreSQL Service Missing Labels

**File:** `infra/k8s/components/infra-db/postgres-service.yaml`

**Problem:**
- Service metadata (line 3-5) has no labels
- Selector works correctly (matches pod labels), but labels improve consistency

**Current State:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: infra-db
spec:
  type: ClusterIP
  selector:
    app: postgres
```

**Why Safe:**
- Adding labels to Service metadata doesn't change behavior
- Labels are purely for organization
- No functional impact

**Risk Level:** Low

**Action:** FIX

**Proposed Change:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: infra-db
  labels:
    app: postgres
    app.kubernetes.io/part-of: voxeil
    app.kubernetes.io/component: database
spec:
  type: ClusterIP
  selector:
    app: postgres
```

---

## Items NOT Included (Why)

### Why Not Fix NetworkPolicy Selectors?

**Finding:** NetworkPolicy for PostgreSQL has multiple namespaceSelector rules

**Why Not Safe:**
- The multiple selectors are intentional (support legacy and new label formats)
- Changing this could break existing namespaces
- This is a compatibility feature, not a bug

**Action:** DOCUMENT (already correct)

---

### Why Not Fix RBAC Permissions?

**Finding:** Controller has cluster-wide namespace permissions

**Why Not Safe:**
- This is intentional and mitigated by Kyverno
- The audit explicitly confirms this is correct
- Changing RBAC would break functionality

**Action:** DOCUMENT (audit confirms this is correct)

---

### Why Not Fix Storage Class?

**Finding:** All PVCs use `local-path`

**Why Not Safe:**
- This is an intentional architectural decision for single-node k3s
- The audit confirms this is acceptable
- Changing would require architectural redesign

**Action:** DOCUMENT (audit confirms this is acceptable)

---

### Why Not Add Finalizers?

**Finding:** Controller-created resources don't have finalizers

**Why Not Safe:**
- This requires controller code changes, not YAML changes
- Resources are created dynamically by controller
- YAML templates can't add finalizers (controller must manage them)

**Action:** DOCUMENT (requires code changes, not YAML)

---

## Verification Checklist

After applying fixes:

- [ ] Run YAML syntax validation: `python3 -c "import yaml; yaml.safe_load_all(open('file.yaml'))"`
- [ ] Run kubeconform on fixed files (exclude cert-manager, kyverno)
- [ ] Run `kubectl apply --dry-run=client` on fixed manifests
- [ ] Verify labels are consistent across related resources
- [ ] Verify no breaking changes (selectors still match, services still work)

---

## Summary

**Total Safe Fixes:** 2 (both low risk, best-practice improvements)

**Total Items to Document:** 6 (architectural decisions, already documented in audit)

**Total Items to Skip:** 4 (acceptable trade-offs, no action needed)

**Conclusion:**
The YAML manifests are **correct and well-structured**. The two identified fixes are minor best-practice improvements (adding labels for consistency) that don't change functionality. All other findings from the audit are either architectural decisions (not YAML bugs) or require code changes (not YAML changes).

---

**End of Plan**
