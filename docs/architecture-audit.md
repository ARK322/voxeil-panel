# Voxeil Panel - Architectural Audit Report

**Date:** 2024-12-19  
**Auditor:** Principal Platform Architect  
**Scope:** Infrastructure (Kubernetes), Controller Backend, Panel Frontend  
**Methodology:** Code review, manifest analysis, architectural pattern evaluation

---

## 0. Executive Summary

Voxeil Panel is a Kubernetes-based hosting control panel that provides multi-tenant site/app deployment. The architecture follows a **single-node k3s deployment model** with a **shared PostgreSQL database** and **namespace-based tenant isolation**.

**Architecture Overview:**
- **Infrastructure:** k3s cluster with Traefik ingress, cert-manager, Kyverno, single PostgreSQL instance
- **Controller:** Fastify-based API service with cluster-wide namespace management and tenant-scoped resource operations
- **Panel:** Next.js frontend that proxies requests to the controller API
- **Tenant Model:** Each user gets a `user-{userId}` namespace with ResourceQuota, LimitRange, NetworkPolicy, and RBAC restrictions

**Overall Assessment:**
The architecture is **sound for small-to-medium scale deployments** (single node, <100 tenants). The design prioritizes simplicity and operational ease over high availability. Several architectural decisions are appropriate for the target scale but will require evolution as the system grows.

**Key Strengths:**
- Strong tenant isolation via NetworkPolicies and RBAC
- Kyverno admission policies prevent controller privilege escalation
- Idempotent resource operations (upsert pattern)
- Proper uninstall safety mechanisms (finalizer handling)

**Key Concerns:**
- Shared database with no tenant-level isolation (security and scalability risk)
- Single PostgreSQL instance (no HA, single point of failure)
- No retry/backoff for partial operation failures
- Storage uses `local-path` (node-local, not portable)

---

## 1. Critical Architectural Risks

### 1.1 Shared PostgreSQL Database with No Tenant Isolation

**Risk Level:** 🔴 **CRITICAL**

**Finding:**
All tenants share a single PostgreSQL instance in the `infra-db` namespace. Each tenant gets their own database (`db_{userId}`) and role (`u_{userId}`), but there is **no network-level or connection-level isolation**. All tenant applications connect to the same PostgreSQL service endpoint.

**Evidence:**
- `infra/k8s/components/infra-db/postgres-statefulset.yaml`: Single StatefulSet with 1 replica
- `apps/controller/users/user.bootstrap.js:145-152`: Creates per-tenant database and role, but all connect to same host
- `infra/k8s/templates/user/networkpolicy-base.yaml:39-49`: NetworkPolicy allows egress to `infra-db` namespace from all user namespaces

**Impact:**
1. **Security:** A compromised tenant application could potentially access other tenants' databases if PostgreSQL role permissions are misconfigured
2. **Scalability:** Single PostgreSQL instance becomes a bottleneck as tenant count grows
3. **Availability:** Database failure affects all tenants
4. **Compliance:** Difficult to meet data residency requirements (all tenant data in one database)

**When It Breaks:**
- At ~50-100 active tenants (PostgreSQL connection pool exhaustion)
- If a tenant application is compromised and exploits PostgreSQL privilege escalation
- During database maintenance (all tenants affected)

**Recommendation:**
- **Short-term:** Document the shared database risk and ensure PostgreSQL roles have strict `GRANT` permissions (verify `REVOKE ALL ON DATABASE` for non-owners)
- **Medium-term:** Consider per-tenant PostgreSQL instances or database sharding
- **Long-term:** Evaluate managed database services (RDS, Cloud SQL) with tenant isolation

---

### 1.2 Controller Has Cluster-Wide Namespace Creation/Deletion Authority

**Risk Level:** 🔴 **CRITICAL** (Mitigated by Kyverno)

**Finding:**
The controller service account has a `ClusterRole` (`controller-bootstrap`) that grants `create`, `patch`, and `delete` permissions on all namespaces cluster-wide.

**Evidence:**
- `infra/k8s/components/platform/rbac.yaml:9-18`: `controller-bootstrap` ClusterRole with namespace verbs
- `infra/k8s/components/platform/rbac.yaml:76-89`: ClusterRoleBinding grants this to `controller-sa`

**Mitigation:**
Kyverno admission policies (`infra/k8s/components/kyverno/policies.yaml:7-61`) restrict the controller to only manage `user-*` namespaces. This is a **good defense-in-depth** approach.

**Impact:**
- **If Kyverno fails or is bypassed:** Controller could create/delete any namespace (including `kube-system`, `platform`, etc.)
- **If controller is compromised:** Attacker gains cluster-wide namespace control (though Kyverno should block non-`user-*` operations)

**When It Breaks:**
- If Kyverno webhook is down during controller operations (admission denied, but controller may retry)
- If Kyverno policies are misconfigured or disabled
- If controller code has a bug that bypasses namespace validation

**Recommendation:**
- ✅ **Current state is acceptable** - Kyverno provides necessary guardrails
- **Enhancement:** Add controller-side validation to double-check namespace prefix before API calls
- **Monitoring:** Alert if Kyverno admission denials occur for controller operations

---

### 1.3 No Retry/Backoff for Partial Operation Failures

**Risk Level:** 🔴 **CRITICAL**

**Finding:**
Controller operations (site deployment, namespace bootstrap, etc.) perform multiple sequential Kubernetes API calls without retry logic or exponential backoff. If any intermediate step fails, the operation is left in a partial state.

**Evidence:**
- `apps/controller/k8s/apply.js`: All `upsert*` functions use try/catch with 404 → create, but no retry on transient errors (network timeouts, API rate limits)
- `apps/controller/users/user.bootstrap.js:93-200`: Sequential operations (namespace → quota → limitrange → networkpolicy → rolebinding → PVC → DB) with no retry
- `apps/controller/sites/site.service.js:346-393`: Site deployment creates deployment → service → ingress sequentially, no retry

**Impact:**
- **Partial deployments:** Site creation may succeed in DB but fail in Kubernetes (or vice versa)
- **Inconsistent state:** Controller DB says site exists, but Kubernetes resources are missing
- **Manual intervention required:** Operators must manually clean up partial states

**When It Breaks:**
- During Kubernetes API rate limiting (429 errors)
- During network transient failures
- During cluster node maintenance (API server temporarily unavailable)

**Recommendation:**
- **Short-term:** Add retry logic with exponential backoff to all `upsert*` functions (3 retries, 1s/2s/4s backoff)
- **Medium-term:** Implement operation state machine (pending → in-progress → completed/failed) with reconciliation loop
- **Long-term:** Consider Kubernetes controllers (operator pattern) for declarative resource management

---

### 1.4 Storage Uses `local-path` (Node-Local, Not Portable)

**Risk Level:** 🟡 **MEDIUM** (Critical for multi-node, acceptable for single-node)

**Finding:**
All PersistentVolumeClaims use `storageClassName: local-path`, which is k3s's default local storage provisioner. This storage is **node-local** and **not portable** across nodes.

**Evidence:**
- `infra/k8s/base/storage/platform-pvc.yaml:11`: `storageClassName: local-path`
- `infra/k8s/base/storage/infra-db-pvc.yaml:9,22`: `storageClassName: local-path`
- `infra/k8s/base/storage/dns-zone-pvc.yaml:9`: `storageClassName: local-path`

**Impact:**
- **Single-node only:** Cannot scale to multi-node cluster (PVCs bound to specific node)
- **No migration:** Cannot move PVCs to another node without data loss
- **Node failure:** If node fails, all PVC data is lost (no replication)

**When It Breaks:**
- When adding a second node to the cluster (PVCs won't schedule)
- During node replacement (data loss unless manually migrated)
- During node failure (data loss)

**Recommendation:**
- ✅ **Acceptable for single-node k3s deployment** (current target)
- **Document limitation:** Explicitly state that multi-node requires external storage (NFS, Ceph, cloud volumes)
- **Future:** Provide storage class configuration option (allow override to `nfs-client`, `longhorn`, etc.)

---

## 2. Medium-Term Risks

### 2.1 No Finalizers on Controller-Managed Resources

**Risk Level:** 🟡 **MEDIUM** (Mitigated by uninstall script)

**Finding:**
Controller-created resources (Deployments, Services, Ingresses, etc.) do not have finalizers. If a namespace is deleted directly (not via controller), resources may be orphaned or deleted before cleanup logic runs.

**Evidence:**
- `apps/controller/k8s/publish.js`: Resources created without finalizers
- `apps/controller/k8s/apply.js`: No finalizer management in upsert functions

**Mitigation:**
Uninstall script (`phases/uninstall/80-clean-namespaces.sh:90-123`) manually checks and removes finalizers before namespace deletion. This works but is **reactive** rather than **proactive**.

**Impact:**
- **Orphaned resources:** If namespace is deleted outside controller flow, resources may remain
- **Stuck namespaces:** If finalizers are added by other controllers (cert-manager, Kyverno), namespace deletion may hang

**When It Breaks:**
- If someone runs `kubectl delete namespace user-123` directly (bypasses controller cleanup)
- If cert-manager adds finalizers to Certificate resources (namespace deletion waits for cert cleanup)

**Recommendation:**
- **Short-term:** Document that namespace deletion should go through controller API
- **Medium-term:** Add finalizers to controller-managed resources (controller removes finalizer after cleanup)
- **Enhancement:** Controller should handle finalizer removal in delete operations

---

### 2.2 Panel Has No Optimistic UI Updates or Operation Tracking

**Risk Level:** 🟡 **MEDIUM**

**Finding:**
Panel frontend makes API calls to controller and waits for response. There is no optimistic UI updates, operation queuing, or long-running operation tracking.

**Evidence:**
- `apps/panel/app/lib/controller.ts`: Direct API client calls, no state management
- `apps/panel/app/page.tsx`: Server-side rendering, no client-side operation tracking
- No WebSocket or polling for operation status

**Impact:**
- **Poor UX:** User clicks "Deploy Site" and sees no feedback until operation completes (may take 30+ seconds)
- **Stale state:** If operation fails partially, UI may show incorrect state
- **No retry:** User must manually retry failed operations

**When It Breaks:**
- During slow Kubernetes API operations (site deployment takes 30+ seconds)
- During partial failures (UI shows success but deployment actually failed)
- During network timeouts (user doesn't know if operation succeeded)

**Recommendation:**
- **Short-term:** Add loading states and operation status polling
- **Medium-term:** Implement optimistic UI updates with reconciliation
- **Long-term:** Consider WebSocket or Server-Sent Events for real-time operation updates

---

### 2.3 Cert-Manager ClusterIssuers Are Cluster-Wide

**Risk Level:** 🟢 **LOW** (Acceptable, but worth noting)

**Finding:**
Cert-manager uses `ClusterIssuer` resources, which are cluster-wide. All tenants share the same Let's Encrypt issuer configuration.

**Evidence:**
- `infra/k8s/components/cert-manager/cluster-issuers.yaml`: `ClusterIssuer` resources (not namespace-scoped `Issuer`)

**Impact:**
- **No tenant isolation for cert issuance:** All tenants use same Let's Encrypt account
- **Rate limit sharing:** All tenants share Let's Encrypt rate limits (50 certs/week per domain)
- **No per-tenant cert configuration:** Cannot use different ACME providers per tenant

**When It Breaks:**
- If Let's Encrypt rate limits are exceeded (all tenants affected)
- If different tenants need different cert providers (e.g., internal CA vs Let's Encrypt)

**Recommendation:**
- ✅ **Acceptable for current scale** (ClusterIssuer is simpler and sufficient)
- **Document limitation:** Note that rate limits are shared
- **Future:** Consider per-tenant `Issuer` resources if needed

---

### 2.4 Network Policies Allow Egress to Shared Database

**Risk Level:** 🟡 **MEDIUM**

**Finding:**
All user namespaces have NetworkPolicies that allow egress to the `infra-db` namespace (PostgreSQL). This is necessary for functionality but means **all tenants can reach the shared database**.

**Evidence:**
- `infra/k8s/templates/user/networkpolicy-base.yaml:39-49`: Egress rule allows TCP:5432 to `infra-db` namespace

**Impact:**
- **Network-level access:** All tenant pods can reach PostgreSQL service (though PostgreSQL auth should restrict access)
- **No network isolation:** Cannot prevent tenant A from attempting connections to tenant B's database (PostgreSQL must enforce)

**When It Breaks:**
- If PostgreSQL authentication is misconfigured (tenant could access other tenants' databases)
- If tenant application is compromised and exploits PostgreSQL connection (brute force, privilege escalation)

**Recommendation:**
- ✅ **Acceptable** - NetworkPolicy + PostgreSQL auth provides defense-in-depth
- **Enhancement:** Consider PostgreSQL `pg_hba.conf` rules to restrict connections by namespace label (if supported)
- **Monitoring:** Alert on failed PostgreSQL authentication attempts

---

## 3. Acceptable Trade-Offs

### 3.1 Single PostgreSQL Instance

**Status:** ✅ **ACCEPTABLE** for single-node, small-scale deployment

**Rationale:**
- Simpler operations (no replication, no failover complexity)
- Lower resource usage (single database pod)
- Sufficient for <100 tenants

**When to Revisit:**
- At 50+ active tenants (connection pool pressure)
- When HA is required (99.9%+ uptime SLA)
- When data residency requires per-tenant databases

---

### 3.2 Single Controller Instance (No Leader Election)

**Status:** ✅ **ACCEPTABLE** for single-node deployment

**Rationale:**
- No race conditions (single instance)
- Simpler code (no distributed locking)
- Sufficient for current scale

**When to Revisit:**
- When scaling to multi-node (need leader election)
- When high availability is required (controller downtime = panel downtime)

---

### 3.3 local-path Storage

**Status:** ✅ **ACCEPTABLE** for single-node k3s

**Rationale:**
- Works out-of-the-box with k3s
- No external storage dependencies
- Sufficient for single-node deployment

**When to Revisit:**
- When adding second node (need shared storage)
- When data portability is required (migration scenarios)

---

### 3.4 No Multi-Region/HA

**Status:** ✅ **ACCEPTABLE** for current target (single VPS deployment)

**Rationale:**
- Simpler architecture
- Lower cost
- Sufficient for small-scale hosting

**When to Revisit:**
- When multi-region is required
- When 99.9%+ uptime SLA is needed

---

## 4. Explicit "This is OK" Confirmations

### 4.1 RBAC Model is Correct ✅

**Finding:**
Controller uses two ClusterRoles:
- `controller-bootstrap`: Namespace create/patch/delete (cluster-wide, but restricted by Kyverno to `user-*` namespaces)
- `user-operator`: Tenant resource management (deployments, services, ingresses, etc.) - granted via RoleBinding per namespace

**Assessment:** ✅ **This is correct and secure**
- Kyverno policies prevent controller from mutating non-`user-*` namespaces
- Per-namespace RoleBinding ensures controller only has tenant-scoped permissions within user namespaces
- Defense-in-depth: RBAC + Kyverno + controller-side validation

---

### 4.2 Network Policies Provide Proper Isolation ✅

**Finding:**
Each user namespace has NetworkPolicies that:
- Deny all ingress by default (except from Traefik)
- Deny all egress by default (except DNS and PostgreSQL)
- Prevent tenant-to-tenant communication

**Assessment:** ✅ **This is correct**
- Tenants cannot communicate with each other's pods
- Only allowed egress is DNS and shared database (necessary for functionality)
- Ingress only from Traefik (proper routing model)

---

### 4.3 Kyverno Admission Policies Prevent Privilege Escalation ✅

**Finding:**
Kyverno policies (`infra/k8s/components/kyverno/policies.yaml`) enforce:
- Controller can only create/update/delete `user-*` namespaces
- Controller can only mutate resources in `user-*` namespaces

**Assessment:** ✅ **This is correct**
- Prevents controller from accidentally or maliciously affecting system namespaces
- Provides admission-time validation (cannot be bypassed by controller code bugs)

---

### 4.4 Ingress Model is Safe (No Wildcard Risk) ✅

**Finding:**
Each site gets its own Ingress resource with a single `host` field (no wildcards). Ingresses are created per-site with explicit domain names.

**Evidence:**
- `apps/controller/k8s/publish.js:147-219`: `buildIngress` creates Ingress with single `spec.rules[0].host`
- No wildcard domains (`*.example.com`) in ingress creation

**Assessment:** ✅ **This is correct**
- No wildcard domain hijacking risk
- Each tenant controls their own domain (via Ingress host field)
- Traefik routes based on Host header (standard Kubernetes ingress behavior)

---

### 4.5 Idempotency Pattern is Sound ✅

**Finding:**
All resource operations use "upsert" pattern: try to patch, if 404 then create. This ensures operations are idempotent.

**Evidence:**
- `apps/controller/k8s/apply.js`: All `upsert*` functions follow patch-or-create pattern
- Uses server-side apply (`application/apply-patch+yaml`) for conflict resolution

**Assessment:** ✅ **This is correct**
- Operations can be safely retried
- No duplicate resource creation
- Handles concurrent updates via field manager

---

### 4.6 Uninstall Handles Finalizers ✅

**Finding:**
Uninstall script (`phases/uninstall/80-clean-namespaces.sh`) checks for finalizers and removes them before namespace deletion.

**Assessment:** ✅ **This is correct**
- Prevents stuck namespaces during uninstall
- Handles finalizers added by cert-manager, Kyverno, etc.
- Safe finalizer removal (only for voxeil-owned namespaces)

---

### 4.7 Database Per-Tenant Model is Correct ✅

**Finding:**
Each tenant gets their own PostgreSQL database (`db_{userId}`) and role (`u_{userId}`). Databases are created with `GRANT` permissions to the tenant role.

**Assessment:** ✅ **This is correct**
- Database-level isolation (tenant A cannot access tenant B's database)
- Role-based access control (each tenant has their own PostgreSQL role)
- Proper `GRANT`/`REVOKE` usage in `apps/controller/postgres/admin.js`

**Note:** Network-level access is shared (all tenants can reach PostgreSQL service), but PostgreSQL authentication enforces database-level isolation.

---

## 5. Recommendations

### 5.1 Short-Term (Next 3 Months)

1. **Add Retry Logic to Controller Operations**
   - Implement exponential backoff for all Kubernetes API calls
   - Retry on 429 (rate limit), 500 (server error), network timeouts
   - 3 retries with 1s/2s/4s backoff

2. **Document Shared Database Risk**
   - Add architecture documentation explaining shared PostgreSQL model
   - Document PostgreSQL role permissions and isolation guarantees
   - Add monitoring for failed authentication attempts

3. **Add Operation Status Tracking**
   - Implement operation state machine (pending → in-progress → completed/failed)
   - Store operation status in database
   - Add API endpoint to query operation status

4. **Enhance Panel UX**
   - Add loading states for long-running operations
   - Implement operation status polling
   - Show error messages for failed operations

### 5.2 Medium-Term (3-6 Months)

1. **Implement Reconciliation Loop**
   - Controller periodically reconciles desired state (DB) with actual state (Kubernetes)
   - Fixes partial failures automatically
   - Handles resource drift

2. **Add Finalizers to Controller-Managed Resources**
   - Controller adds finalizers to Deployments, Services, Ingresses
   - Controller removes finalizers after cleanup
   - Prevents orphaned resources

3. **Consider Per-Tenant PostgreSQL Instances**
   - Evaluate database sharding or per-tenant instances
   - Improves isolation and scalability
   - Enables per-tenant database configuration

4. **Add Storage Class Configuration**
   - Allow override of `storageClassName` via environment variable
   - Support external storage (NFS, Longhorn, cloud volumes)
   - Enables multi-node deployments

### 5.3 Long-Term (6-12 Months)

1. **Evaluate Kubernetes Operator Pattern**
   - Move resource management to Kubernetes controllers
   - Declarative resource management (desired state reconciliation)
   - Better handling of partial failures

2. **Consider High Availability**
   - Multi-node k3s cluster
   - PostgreSQL replication (primary/replica)
   - Controller leader election
   - Shared storage (NFS, Ceph, cloud volumes)

3. **Implement WebSocket/SSE for Real-Time Updates**
   - Panel receives real-time operation status updates
   - Better UX for long-running operations
   - Reduces polling overhead

4. **Add Multi-Region Support (If Needed)**
   - Evaluate geographic distribution requirements
   - Consider managed database services (RDS, Cloud SQL)
   - Implement data replication strategy

---

## 6. Conclusion

The Voxeil Panel architecture is **well-designed for its target use case** (single-node k3s, small-to-medium scale hosting). The system demonstrates:

- **Strong security:** NetworkPolicies, RBAC, Kyverno admission policies
- **Proper isolation:** Namespace-based tenant isolation with resource quotas
- **Idempotent operations:** Upsert pattern ensures safe retries
- **Uninstall safety:** Finalizer handling prevents stuck namespaces

**Critical areas for improvement:**
1. Add retry logic to handle transient failures
2. Document shared database risk and isolation guarantees
3. Implement operation status tracking for better UX

**The architecture will scale to ~50-100 tenants** on a single node before requiring significant changes (database sharding, multi-node cluster, external storage).

**Overall Grade: B+** (Solid foundation, needs operational resilience improvements)

---

**End of Report**
