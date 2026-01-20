# CURRENT_STATE

## Repo structure (critical paths)

### apps/controller/*
- `apps/controller/Dockerfile`
- `apps/controller/package.json`
- `apps/controller/package-lock.json`
- `apps/controller/tsconfig.json`
- `apps/controller/src/index.ts`
- `apps/controller/src/http/routes.ts`
- `apps/controller/src/http/errors.ts`
- `apps/controller/src/sites/site.dto.ts`
- `apps/controller/src/sites/site.service.ts`
- `apps/controller/src/sites/site.slug.ts`
- `apps/controller/src/backup/backup.dto.ts`
- `apps/controller/src/backup/helpers.ts`
- `apps/controller/src/backup/restore.service.ts`
- `apps/controller/src/k8s/*` (k8s client + apply + ingress + namespace + pvc + quota + secrets)
- `apps/controller/src/mailcow/client.ts`
- `apps/controller/src/postgres/admin.ts`
- `apps/controller/src/templates/*`
- `apps/controller/templates/tenant/*`

### infra/k8s/platform/*
- `infra/k8s/platform/namespace.yaml`
- `infra/k8s/platform/rbac.yaml`
- `infra/k8s/platform/controller-deploy.yaml`
- `infra/k8s/platform/controller-svc.yaml`
- `infra/k8s/platform/controller-nodeport.yaml`
- `infra/k8s/platform/panel-deploy.yaml`
- `infra/k8s/platform/panel-svc.yaml`

### infra/k8s/templates/*
- `infra/k8s/templates/tenant/limitrange.yaml`
- `infra/k8s/templates/tenant/networkpolicy-allow-ingress.yaml`
- `infra/k8s/templates/tenant/networkpolicy-deny-all.yaml`
- `infra/k8s/templates/tenant/resourcequota.yaml`

### infra/k8s/cert-manager/*
- `infra/k8s/cert-manager/cert-manager.yaml`
- `infra/k8s/cert-manager/cluster-issuers.yaml`

### infra/k8s/mailcow/*
- `infra/k8s/mailcow/namespace.yaml`
- `infra/k8s/mailcow/mailcow-core.yaml`
- `infra/k8s/mailcow/networkpolicy.yaml`
- `infra/k8s/mailcow/traefik-tcp/ingressroutetcp.yaml`
- `infra/k8s/mailcow/traefik-tcp/traefik-entrypoints.yaml`

### infra/k8s/backup/*
- `infra/k8s/backup/namespace.yaml`
- `infra/k8s/backup/rbac.yaml`
- `infra/k8s/backup/backup-runner.yaml`

### installer
- `installer/installer.sh`

## Current endpoint contract (from controller routes)

### Sites / TLS / Deploy
- `POST /sites` -> create site (domain, cpu, ramGi, diskGi, tlsEnabled?, tlsIssuer?)
- `GET /sites` -> list sites with annotations + readiness
- `PATCH /sites/:slug/limits` -> update cpu/ramGi/diskGi
- `POST /sites/:slug/deploy` -> set image + containerPort
- `PATCH /sites/:slug/tls` -> enable/disable TLS + issuer + optional secret cleanup
- `DELETE /sites/:slug` -> delete tenant namespace
- `POST /sites/:slug/purge` -> delete namespace + db + mail + backups

### Mail
- `POST /sites/:slug/mail/enable` {domain}
- `POST /sites/:slug/mail/disable`
- `POST /sites/:slug/mail/purge` {confirm:"DELETE"}
- `GET /sites/:slug/mail/status`
- `GET /sites/:slug/mail/mailboxes`
- `POST /sites/:slug/mail/mailboxes`
- `DELETE /sites/:slug/mail/mailboxes/:address`
- `GET /sites/:slug/mail/aliases`
- `POST /sites/:slug/mail/aliases`
- `DELETE /sites/:slug/mail/aliases/:source`

### DB
- `POST /sites/:slug/db/enable` {dbName?}
- `POST /sites/:slug/db/disable`
- `POST /sites/:slug/db/purge` {confirm:"DELETE"}
- `GET /sites/:slug/db/status`

### Backup
- `POST /sites/:slug/backup/enable` {retentionDays?, schedule?}
- `POST /sites/:slug/backup/disable`
- `PATCH /sites/:slug/backup/config` {retentionDays?, schedule?}
- `POST /sites/:slug/backup/run`
- `GET /sites/:slug/backup/snapshots`
- `POST /sites/:slug/backup/restore` {snapshotId, restoreFiles?, restoreDb?}
- `POST /sites/:slug/backup/purge` {confirm:"DELETE"}
- `POST /sites/:slug/restore/files` {backupFile?, latest?}
- `POST /sites/:slug/restore/db` {backupFile?, latest?}

## Infra notes
- Tenant state is stored in namespace annotations; controller mutates them via patch.
- Backups use a `backup` namespace and `hostPath` `/backups` with `backup-runner` jobs.
- DB admin access is via platform secret values (POSTGRES_* env).
- Mailcow integration relies on API URL + key from platform secret/env.
- Mailcow and cert-manager are installed by default; site features remain opt-in.

## Risks / gaps observed (pre-change)
- RBAC in `infra/k8s/platform/rbac.yaml` may miss `patch`/`list` verbs for controller operations.
- Backup access relies on hostPath `/backups`; requires node-level directory and strong isolation.
- Backup and restore read from local disk; retention is enforced by runner, not visible here.
- Mail/DB operations depend on platform secrets; no explicit rotation guidance yet.
- Ingress TLS handling is split across builder + patcher, risk of divergence.
