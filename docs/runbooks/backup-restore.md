# Backup and Restore

## Overview

Backups live on the host at `/backups/voxeil` and are organized per site slug
under `/backups/voxeil/sites/<slug>`. Restore is driven via controller endpoints
protected by the `x-api-key` admin key.

## Restore files (API)

Choose a specific archive or ask for the newest file backup.

```bash
curl -X POST "https://<controller-host>/sites/<slug>/restore/files" \
  -H "x-api-key: <ADMIN_API_KEY>" \
  -H "content-type: application/json" \
  -d '{"backupFile":"20240101T010101Z.tar.zst"}'
```

```bash
curl -X POST "https://<controller-host>/sites/<slug>/restore/files" \
  -H "x-api-key: <ADMIN_API_KEY>" \
  -H "content-type: application/json" \
  -d '{"latest":true}'
```

## Restore database (API)

```bash
curl -X POST "https://<controller-host>/sites/<slug>/restore/db" \
  -H "x-api-key: <ADMIN_API_KEY>" \
  -H "content-type: application/json" \
  -d '{"backupFile":"20240101T010101Z.sql.gz"}'
```

```bash
curl -X POST "https://<controller-host>/sites/<slug>/restore/db" \
  -H "x-api-key: <ADMIN_API_KEY>" \
  -H "content-type: application/json" \
  -d '{"latest":true}'
```

## Notes

- Restore is wipe-and-restore: existing PVC contents are deleted before the archive is extracted.
- File archives live at `/backups/voxeil/sites/<slug>/files/<timestamp>.tar.zst`.
- DB archives live at `/backups/voxeil/sites/<slug>/db/<timestamp>.sql.gz`.
- If DB env vars were not set at backup time, a `SKIPPED.txt` marker is written under
  `/backups/voxeil/sites/<slug>/db/`.

## Troubleshooting

- `backupFile or latest=true required`: request body missing both parameters.
- `Backup archive not found`: verify the filename exists under the site backup directory.
- `DB restore not configured.`: ensure `DB_HOST` plus `DB_ADMIN_USER/DB_ADMIN_PASSWORD` (or legacy `DB_USER/DB_PASSWORD`) are set on the controller.
- `Restore pod failed` or `timed out`: inspect the temp pod in `tenant-<slug>` for logs/events.
