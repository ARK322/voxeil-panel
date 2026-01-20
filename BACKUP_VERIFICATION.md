# BACKUP_VERIFICATION

## Contract check (current)
Endpoints present:
- `POST /sites/:slug/backup/enable` `{retentionDays?, schedule?}`
- `POST /sites/:slug/backup/disable`
- `PATCH /sites/:slug/backup/config`
- `POST /sites/:slug/backup/run`
- `GET /sites/:slug/backup/snapshots`
- `POST /sites/:slug/backup/restore` `{snapshotId, restoreFiles?, restoreDb?}`
- `POST /sites/:slug/backup/purge` `{confirm:"DELETE"}`

Notes:
- `disable` is reversible (removes CronJob, keeps archives).
- `purge` now removes archives and disables backups (CronJob removed).

## Retention behavior
- Backup runner removes archives older than `RETENTION_DAYS` (default 14) via:
  - `find ... -mtime +RETENTION_DAYS -delete`
- Manual `run` uses the same retention logic since it invokes the same runner.

## Storage + namespace
- Backups live on hostPath `/backups/sites/<slug>/{files,db}`.
- CronJobs/Jobs run in the `backup` namespace using `backup-runner` SA.
- Restore uses a temporary pod in the tenant namespace with a read-only mount to `/backups`.

## Tenant isolation
- Tenants cannot access `/backups` unless a controller-created pod is launched.
- Only controller-managed workloads are deployed; tenants do not have direct K8s access.

## Test checklist

### Build
```
cd apps/controller
npm run build
```

### Manifest check (dry-run)
```
kubectl apply --dry-run=client -f infra/k8s/backup
```

### K8s verification (example flow)
```
# Enable backups (creates CronJob in backup namespace)
curl -X POST http://<controller>/sites/<slug>/backup/enable \
  -H "X-API-Key: <key>" \
  -H "Content-Type: application/json" \
  -d '{"retentionDays":14,"schedule":"0 3 * * *"}'

# Verify CronJob
kubectl -n backup get cronjob backup-<slug>

# Trigger manual run
curl -X POST http://<controller>/sites/<slug>/backup/run -H "X-API-Key: <key>"
kubectl -n backup get jobs -l vhp-controller=vhp-controller

# List snapshots
curl http://<controller>/sites/<slug>/backup/snapshots -H "X-API-Key: <key>"

# Restore
curl -X POST http://<controller>/sites/<slug>/backup/restore \
  -H "X-API-Key: <key>" \
  -H "Content-Type: application/json" \
  -d '{"snapshotId":"<id>","restoreFiles":true,"restoreDb":true}'

# Purge (removes archives + disables)
curl -X POST http://<controller>/sites/<slug>/backup/purge \
  -H "X-API-Key: <key>" \
  -H "Content-Type: application/json" \
  -d '{"confirm":"DELETE"}'
kubectl -n backup get cronjob backup-<slug> || true
```
