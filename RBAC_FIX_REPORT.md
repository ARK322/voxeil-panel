# RBAC_FIX_REPORT

## Summary
Controller RBAC was expanded to cover missing verbs (`patch`/`delete`) and to scope secret access so the controller only has `get` in the `platform` namespace while retaining CRUD in tenant namespaces via per-tenant Role/RoleBinding.

## Changes (before -> after)

### Namespaces
- Before: `get,list,create,delete`
- After: `get,list,create,patch,delete`
- Reason: controller patches namespace annotations.

### PVC / ResourceQuota / LimitRange / NetworkPolicy
- Before: `get,list,create,patch,update`
- After: `get,list,create,patch,update,delete`
- Reason: align with required minimum verbs and avoid failures on cleanup flows.

### Deployments / Services / Ingresses
- Before: `get,list,create,patch,update`
- After: `get,list,create,patch,update,delete`
- Reason: allow cleanup during future lifecycle operations.

### Secrets
- Before: ClusterRole had `get,list,create,patch,update,delete` for all namespaces.
- After: ClusterRole has no secret verbs; tenant namespaces get a Role with `get,create,patch,delete` and a RoleBinding to `controller-sa`. Platform namespace keeps `get` only via `controller-platform-secrets` Role.
- Reason: enforce “tenant CRUD, platform get-only” boundary.

### RBAC resources
- Added `roles` / `rolebindings` CRUD in ClusterRole.
- Reason: controller now ensures per-tenant Role/RoleBinding on demand.

### Batch resources (backup jobs)
- Added `cronjobs` / `jobs` verbs (`get,list,create,patch,update,delete`).
- Reason: controller creates/replaces backup CronJobs and Jobs.

## Files touched
- `infra/k8s/platform/rbac.yaml`
- `apps/controller/src/k8s/client.ts`
- `apps/controller/src/k8s/rbac.ts`
- `apps/controller/src/k8s/secrets.ts`

## Notes
- Secret CRUD in tenant namespaces is created on-demand the first time the controller touches a secret.
