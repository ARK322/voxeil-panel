# Voxeil Panel Installer Resource Inventory

This document lists all Kubernetes resources, filesystem paths, and system components created by the installer. The uninstaller MUST remove all of these in reverse order.

## Resource Deletion Order (Reverse of Installation)

### 1. Workloads and Namespace-Scoped Resources
Delete in this order:
- Deployments
- StatefulSets
- DaemonSets
- Jobs
- CronJobs
- Pods
- Services
- Ingresses
- ConfigMaps
- Secrets
- PVCs
- NetworkPolicies
- ResourceQuotas
- LimitRanges
- Roles
- RoleBindings
- ServiceAccounts

### 2. Namespaces
Delete after all resources are removed:
- platform
- infra-db
- dns-zone
- mail-zone
- backup-system
- kyverno
- flux-system
- cert-manager
- user-* (dynamically created)
- tenant-* (dynamically created)

### 3. Webhooks
Delete webhook configurations:
- ValidatingWebhookConfigurations (Kyverno, cert-manager, Flux)
- MutatingWebhookConfigurations (Kyverno, cert-manager, Flux)

### 4. Cluster-Wide Resources
- ClusterRoles
- ClusterRoleBindings
- ClusterIssuers (cert-manager)
- ClusterPolicies (Kyverno)
- HelmChartConfig (Traefik)

### 5. CRDs
Delete CRDs last (after all instances are removed):
- cert-manager CRDs
- Kyverno CRDs
- Flux CRDs

### 6. Storage
- PVCs (already deleted with namespaces, but verify)
- PVs (orphaned volumes)

### 7. k3s Installation
- k3s service
- k3s binaries
- k3s data directories

### 8. Filesystem Paths
- /etc/voxeil/
- /usr/local/bin/voxeil-ufw-apply
- /etc/systemd/system/voxeil-ufw-apply.service
- /etc/systemd/system/voxeil-ufw-apply.path
- /etc/fail2ban/jail.d/voxeil.conf
- /etc/ssh/sshd_config.voxeil-backup.*
- /var/lib/voxeil/

## Detailed Resource Inventory

### Namespaces

| Namespace | Created By | Deletion Method |
|-----------|------------|-----------------|
| platform | installer | kubectl delete namespace |
| infra-db | installer | kubectl delete namespace |
| dns-zone | installer | kubectl delete namespace |
| mail-zone | installer | kubectl delete namespace |
| backup-system | installer | kubectl delete namespace |
| kyverno | installer | kubectl delete namespace |
| flux-system | installer | kubectl delete namespace |
| cert-manager | installer | kubectl delete namespace |
| user-* | controller (dynamic) | kubectl delete namespace |
| tenant-* | controller (dynamic) | kubectl delete namespace |

### CRDs

| CRD Name | Created By | Deletion Method |
|----------|------------|-----------------|
| certificates.cert-manager.io | cert-manager | kubectl delete crd |
| certificaterequests.cert-manager.io | cert-manager | kubectl delete crd |
| challenges.acme.cert-manager.io | cert-manager | kubectl delete crd |
| clusterissuers.cert-manager.io | cert-manager | kubectl delete crd |
| issuers.cert-manager.io | cert-manager | kubectl delete crd |
| orders.acme.cert-manager.io | cert-manager | kubectl delete crd |
| policies.kyverno.io | Kyverno | kubectl delete crd |
| clusterpolicies.kyverno.io | Kyverno | kubectl delete crd |
| policyreports.wgpolicyk8s.io | Kyverno | kubectl delete crd |
| clusterpolicyreports.wgpolicyk8s.io | Kyverno | kubectl delete crd |
| cleanupolicies.kyverno.io | Kyverno | kubectl delete crd |
| clustercleanuppolicies.kyverno.io | Kyverno | kubectl delete crd |
| admissionreports.kyverno.io | Kyverno | kubectl delete crd |
| clusteradmissionreports.kyverno.io | Kyverno | kubectl delete crd |
| backgroundscanreports.kyverno.io | Kyverno | kubectl delete crd |
| clusterbackgroundscanreports.kyverno.io | Kyverno | kubectl delete crd |
| policyexceptions.kyverno.io | Kyverno | kubectl delete crd |
| updaterequests.kyverno.io | Kyverno | kubectl delete crd |
| All Flux CRDs | Flux | kubectl delete crd (with label selector) |

### ClusterRoles

| Name | Created By | Deletion Method |
|------|------------|-----------------|
| controller-bootstrap | installer | kubectl delete clusterrole |
| user-operator | installer | kubectl delete clusterrole |

### ClusterRoleBindings

| Name | Created By | Deletion Method |
|------|------------|-----------------|
| controller-bootstrap-binding | installer | kubectl delete clusterrolebinding |

### Webhooks

| Type | Name Pattern | Created By | Deletion Method |
|------|-------------|------------|-----------------|
| ValidatingWebhookConfiguration | kyverno-* | Kyverno | kubectl delete validatingwebhookconfiguration |
| MutatingWebhookConfiguration | kyverno-* | Kyverno | kubectl delete mutatingwebhookconfiguration |
| ValidatingWebhookConfiguration | cert-manager-* | cert-manager | kubectl delete validatingwebhookconfiguration |
| MutatingWebhookConfiguration | cert-manager-* | cert-manager | kubectl delete mutatingwebhookconfiguration |
| ValidatingWebhookConfiguration | flux-* | Flux | kubectl delete validatingwebhookconfiguration |
| MutatingWebhookConfiguration | flux-* | Flux | kubectl delete mutatingwebhookconfiguration |

### Cluster-Wide Resources

| Type | Name | Created By | Deletion Method |
|------|------|------------|-----------------|
| ClusterIssuer | letsencrypt-prod | installer | kubectl delete clusterissuer |
| ClusterIssuer | letsencrypt-staging | installer | kubectl delete clusterissuer |
| ClusterPolicy | Various (from policies.yaml) | installer | kubectl delete clusterpolicy |
| HelmChartConfig | traefik | installer | kubectl delete helmchartconfig |

### StorageClasses

| Name | Created By | Notes |
|------|------------|-------|
| local-path | k3s (default) | DO NOT DELETE - k3s default |

### PVCs

| Namespace | PVC Name | Created By | Deletion Method |
|-----------|----------|------------|-----------------|
| platform | controller-pvc | installer | kubectl delete pvc |
| platform | panel-pvc | installer | kubectl delete pvc |
| infra-db | postgres-pvc | installer | kubectl delete pvc |
| infra-db | pgadmin-pvc | installer | kubectl delete pvc |
| dns-zone | bind9-pvc | installer | kubectl delete pvc |
| mail-zone | mailcow-mysql-pvc | installer | kubectl delete pvc |
| user-* | pvc-user-backup | controller (dynamic) | kubectl delete pvc |
| tenant-* | Various | controller (dynamic) | kubectl delete pvc |

### Platform Namespace Resources

| Type | Name | Created By |
|------|------|------------|
| Deployment | controller | installer |
| Deployment | panel | installer |
| Service | controller | installer |
| Service | panel | installer |
| Ingress | panel | installer |
| Secret | platform-secrets | installer |
| Secret | panel-auth | installer |
| Secret | ghcr-pull-secret | installer (if GHCR credentials provided) |
| ServiceAccount | controller-sa | installer |
| Role | controller-platform-secrets | installer |
| RoleBinding | controller-platform-secrets-binding | installer |
| PVC | controller-pvc | installer |
| PVC | panel-pvc | installer |

### Infra-DB Namespace Resources

| Type | Name | Created By |
|------|------|------------|
| StatefulSet | postgres | installer |
| Deployment | pgadmin | installer |
| Service | postgres | installer |
| Service | pgadmin | installer |
| Ingress | pgadmin | installer |
| Secret | postgres-secret | installer |
| Secret | pgadmin-secret | installer |
| Secret | pgadmin-auth | installer |
| NetworkPolicy | postgres-networkpolicy | installer |
| PVC | postgres-pvc | installer |
| PVC | pgadmin-pvc | installer |

### DNS-Zone Namespace Resources

| Type | Name | Created By |
|------|------|------------|
| Deployment | bind9 | installer |
| Secret | tsig-secret | installer |
| PVC | bind9-pvc | installer |
| IngressRouteTCP | dns-tcp-* | installer |

### Mail-Zone Namespace Resources

| Type | Name | Created By |
|------|------|------------|
| StatefulSet | mailcow-mysql | installer |
| Deployment | mailcow-php-fpm | installer |
| Deployment | mailcow-postfix | installer |
| Deployment | mailcow-dovecot | installer |
| Service | mailcow-mysql | installer |
| Service | mailcow-php-fpm | installer |
| Service | mailcow-postfix | installer |
| Service | mailcow-dovecot | installer |
| Service | mailcow-api | installer |
| Ingress | mailcow | installer |
| ConfigMap | mailcow-config | installer |
| Secret | mailcow-secrets | installer |
| Secret | mailcow-auth | installer |
| NetworkPolicy | Various | installer |
| PVC | mailcow-mysql-pvc | installer |
| IngressRouteTCP | mail-* | installer |

### Backup-System Namespace Resources

| Type | Name | Created By |
|------|------|------------|
| Deployment | backup-service | installer |
| Service | backup-service | installer |
| Secret | backup-service-secret | installer |
| ConfigMap | backup-scripts | installer |
| ConfigMap | backup-job-templates | installer |
| ServiceAccount | backup-runner | installer |
| Role | backup-runner | installer |
| RoleBinding | backup-runner | installer |

### Kyverno Namespace Resources

| Type | Name | Created By |
|------|------|------------|
| Deployment | kyverno-admission-controller | Kyverno |
| Deployment | kyverno-background-controller | Kyverno |
| Deployment | kyverno-cleanup-controller | Kyverno |
| Deployment | kyverno-reports-controller | Kyverno |
| Service | kyverno-svc-metrics | Kyverno |
| Service | kyverno-svc | Kyverno |
| ConfigMap | kyverno | Kyverno |
| CronJob | kyverno-cleanup-* | Kyverno |
| ServiceAccount | Various | Kyverno |

### Cert-Manager Namespace Resources

| Type | Name | Created By |
|------|------|------------|
| Deployment | cert-manager | cert-manager |
| Deployment | cert-manager-webhook | cert-manager |
| Deployment | cert-manager-cainjector | cert-manager |
| Service | cert-manager | cert-manager |
| Service | cert-manager-webhook | cert-manager |
| ServiceAccount | Various | cert-manager |

### Flux-System Namespace Resources

| Type | Name | Created By |
|------|------|------------|
| Deployment | Various (from Flux install.yaml) | Flux |
| ServiceAccount | Various | Flux |

### User Namespace Resources (Dynamic)

Created by controller via templates in `infra/k8s/templates/user/`:
- Namespace (user-{userId})
- ResourceQuota
- LimitRange
- NetworkPolicy (base, allow-ingress, allow-egress)
- ServiceAccount (backup-runner)
- Role (backup-runner)
- RoleBinding (backup-runner, controller)
- PVC (pvc-user-backup)

### Tenant Namespace Resources (Dynamic)

Created by controller via templates in `infra/k8s/templates/tenant/`:
- Namespace (tenant-{tenantId})
- ResourceQuota
- LimitRange
- NetworkPolicy (deny-all, allow-ingress, allow-egress)

### Filesystem Paths

| Path | Created By | Deletion Method |
|------|------------|-----------------|
| /etc/voxeil/ | installer | rm -rf |
| /etc/voxeil/installer.env | installer | rm -f |
| /etc/voxeil/allowlist.txt | installer | rm -f |
| /var/lib/voxeil/ | installer | rm -rf |
| /var/lib/voxeil/install.state | installer | rm -f |
| /usr/local/bin/voxeil-ufw-apply | installer | rm -f |
| /etc/systemd/system/voxeil-ufw-apply.service | installer | systemctl disable/stop, rm -f |
| /etc/systemd/system/voxeil-ufw-apply.path | installer | systemctl disable/stop, rm -f |
| /etc/fail2ban/jail.d/voxeil.conf | installer | rm -f |
| /etc/ssh/sshd_config.voxeil-backup.* | installer | rm -f |

### k3s Installation Artifacts

| Path/Component | Created By | Deletion Method |
|----------------|------------|-----------------|
| /usr/local/bin/k3s | k3s installer | k3s-uninstall.sh or rm -f |
| /usr/local/bin/kubectl | k3s installer | rm -f |
| /usr/local/bin/crictl | k3s installer | rm -f |
| /usr/local/bin/ctr | k3s installer | rm -f |
| /var/lib/rancher/k3s/ | k3s | rm -rf |
| /etc/rancher/k3s/ | k3s | rm -rf |
| /etc/systemd/system/k3s.service | k3s installer | systemctl disable/stop, rm -f |
| /var/log/k3s/ | k3s | rm -rf |

### Docker Images

| Image | Created By | Deletion Method |
|-------|------------|-----------------|
| backup-runner:local | installer | docker rmi, k3s ctr images rm |

### System Packages (Optional - Only if installed by installer)

| Package | Created By | Deletion Method |
|---------|------------|-----------------|
| docker.io | installer | apt-get remove/purge |
| clamav, clamav-daemon | installer | apt-get remove/purge |
| fail2ban | installer | apt-get remove/purge |

## State Registry

The installer maintains a state file at `/var/lib/voxeil/install.state` that tracks which components have been installed. This file uses a simple key-value format:

```
K3S_INSTALLED=1
TRAEFIK_INSTALLED=1
CERT_MANAGER_INSTALLED=1
KYVERNO_INSTALLED=1
FLUX_INSTALLED=1
PLATFORM_INSTALLED=1
INFRA_DB_INSTALLED=1
BACKUP_SYSTEM_INSTALLED=1
STORAGE_INSTALLED=1
```

The uninstaller uses this state file to determine what to remove. If the state file is missing, use `--force` to remove all detected resources.

### State Registry Functions

Both installer and uninstaller provide these helper functions:
- `ensure_state_dir()` - Creates `/var/lib/voxeil` directory
- `state_set KEY VALUE` - Sets a state key=value
- `state_get KEY default` - Gets a state key with optional default
- `state_load()` - Safely sources the state file if it exists

## Labeling Strategy

All Kubernetes resources created by the installer MUST have the label:
```yaml
metadata:
  labels:
    app.kubernetes.io/part-of: voxeil
```

This includes:
- All namespaces (platform, infra-db, dns-zone, mail-zone, backup-system, kyverno, flux-system, cert-manager)
- All resources within those namespaces (Deployments, Services, ConfigMaps, Secrets, PVCs, etc.)
- Cluster-scoped resources (ClusterRoles, ClusterRoleBindings, Webhooks, CRDs)

The label enables:
- Easy discovery: `kubectl get all -A -l app.kubernetes.io/part-of=voxeil`
- Targeted cleanup: Uninstaller deletes resources by label
- Verification: `scripts/verify-clean.sh` checks for labeled resources

### Labeling Exceptions

Some resources may not support labels:
- Some CRDs (depends on CRD definition)
- System resources managed by k3s (kube-system namespace, etc.)

For large upstream manifests (cert-manager, Kyverno, Flux), labels are added to:
- Namespaces (always)
- Cluster-scoped resources (ClusterRoles, ClusterRoleBindings, Webhooks, CRDs)
- Key resources where possible

## Uninstall Order

The uninstaller follows this exact reverse order:

1. **Workloads** - Delete all namespace-scoped resources by label
2. **Namespaces** - Delete in reverse order, wait for termination (300s timeout)
3. **Webhooks** - Delete ValidatingWebhookConfiguration and MutatingWebhookConfiguration by label
4. **Cluster Roles** - Delete ClusterRoles and ClusterRoleBindings by label
5. **CRDs** - Delete CustomResourceDefinitions by label (LAST)
6. **Storage** - Delete PVCs (already done), then PVs tied to voxeil namespaces
7. **k3s** - Remove k3s if K3S_INSTALLED=1 or --force
8. **State** - Remove `/var/lib/voxeil` directory

## Verification

### Doctor Mode

Both installer and uninstaller support `--doctor` mode to check installation state without making changes:

```bash
./installer/installer.sh --doctor
./uninstaller/uninstaller.sh --doctor
```

Doctor mode reports:
- State file contents
- Resources labeled `app.kubernetes.io/part-of=voxeil`
- Unlabeled namespaces that might be leftovers
- PersistentVolumes tied to voxeil namespaces

### Verify Clean Script

After uninstallation, verify the system is clean:

```bash
./scripts/verify-clean.sh
```

This script:
- Checks for all resources with the voxeil label
- Checks for unlabeled voxeil namespaces
- Checks for PersistentVolumes tied to voxeil namespaces
- Checks for state file
- Exits 0 only if system is completely clean

## Notes

1. **CRDs must be deleted LAST** - after all instances are removed
2. **Webhooks must be deleted** before CRDs to avoid blocking
3. **Namespaces must wait for termination** - use `wait_ns_deleted()` with 300s timeout, force finalizer removal if stuck
4. **PVCs block namespace deletion** - must be deleted first or finalizers removed
5. **Dynamic resources** (user-*, tenant-*) are created by controller at runtime and should be labeled
6. **k3s default resources** (local-path StorageClass, kube-system namespace) should NOT be deleted
7. **State registry** at `/var/lib/voxeil/install.state` tracks what was installed
8. **Idempotency** - Installer can be re-run safely; it checks state and skips already-installed components
9. **Dry-run mode** - Both scripts support `--dry-run` to preview changes without executing
10. **Force mode** - Uninstaller supports `--force` to remove all resources even if state file is missing
