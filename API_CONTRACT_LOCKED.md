# API_CONTRACT_LOCKED

All endpoints require `X-API-Key` except `/health`.

## Sites

### POST /sites
Request:
```json
{ "domain": "app.example.com", "cpu": 1, "ramGi": 2, "diskGi": 10, "tlsEnabled": false, "tlsIssuer": "letsencrypt-prod" }
```
Response:
```json
{ "domain": "app.example.com", "slug": "app-example-com", "namespace": "tenant-app-example-com", "limits": { "cpu": 1, "ramGi": 2, "diskGi": 10, "pods": 1 } }
```

### GET /sites
Response:
```json
[{ "slug": "app-example-com", "namespace": "tenant-app-example-com", "ready": true, "domain": "app.example.com", "image": "ghcr.io/...", "containerPort": 3000, "tlsEnabled": false, "tlsIssuer": "letsencrypt-prod", "dbEnabled": false, "mailEnabled": false, "backupEnabled": false }]
```

### PATCH /sites/:slug/limits
Request:
```json
{ "cpu": 2, "ramGi": 4 }
```
Response:
```json
{ "slug": "app-example-com", "namespace": "tenant-app-example-com", "limits": { "cpu": 2, "ramGi": 4, "diskGi": 10, "pods": 1 } }
```

### POST /sites/:slug/deploy
Request:
```json
{ "image": "ghcr.io/org/app:latest", "containerPort": 3000 }
```
Response:
```json
{ "slug": "app-example-com", "namespace": "tenant-app-example-com", "image": "ghcr.io/org/app:latest", "containerPort": 3000 }
```

### PATCH /sites/:slug/tls
Request:
```json
{ "enabled": true, "issuer": "letsencrypt-prod" }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "tlsEnabled": true, "issuer": "letsencrypt-prod" }
```

### DELETE /sites/:slug
Response:
```json
{ "ok": true, "slug": "app-example-com" }
```

### POST /sites/:slug/purge
Request:
```json
{ "confirm": "DELETE" }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "purged": true }
```

## Mail

### POST /sites/:slug/mail/enable
Request:
```json
{ "domain": "example.com" }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "domain": "example.com", "mailEnabled": true, "provider": "mailcow" }
```

### POST /sites/:slug/mail/disable
Response:
```json
{ "ok": true, "slug": "app-example-com", "mailEnabled": false, "domain": "example.com", "provider": "mailcow" }
```

### POST /sites/:slug/mail/purge
Request:
```json
{ "confirm": "DELETE" }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "mailEnabled": false, "domain": "example.com", "purged": true, "provider": "mailcow" }
```

### GET /sites/:slug/mail/status
Response:
```json
{ "ok": true, "slug": "app-example-com", "domain": "example.com", "mailEnabled": true, "activeInMailcow": true }
```

### GET /sites/:slug/mail/mailboxes
Response:
```json
{ "ok": true, "slug": "app-example-com", "domain": "example.com", "mailboxes": ["hello@example.com"] }
```

### POST /sites/:slug/mail/mailboxes
Request:
```json
{ "localPart": "hello", "password": "secret", "quotaMb": 512 }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "address": "hello@example.com" }
```

### DELETE /sites/:slug/mail/mailboxes/:address
Response:
```json
{ "ok": true, "slug": "app-example-com", "address": "hello@example.com" }
```

### GET /sites/:slug/mail/aliases
Response:
```json
{ "ok": true, "slug": "app-example-com", "domain": "example.com", "aliases": ["info@example.com"] }
```

### POST /sites/:slug/mail/aliases
Request:
```json
{ "sourceLocalPart": "info", "destination": "dest@example.net", "active": true }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "source": "info@example.com" }
```

### DELETE /sites/:slug/mail/aliases/:source
Response:
```json
{ "ok": true, "slug": "app-example-com", "source": "info@example.com" }
```

## DB

### POST /sites/:slug/db/enable
Request:
```json
{ "dbName": "db_app_example_com" }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "dbEnabled": true, "dbName": "db_app_example_com", "username": "u_app_example_com" }
```

### POST /sites/:slug/db/disable
Response:
```json
{ "ok": true, "slug": "app-example-com", "dbEnabled": false }
```

### POST /sites/:slug/db/purge
Request:
```json
{ "confirm": "DELETE" }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "purged": true }
```

### GET /sites/:slug/db/status
Response:
```json
{ "ok": true, "slug": "app-example-com", "dbEnabled": true, "dbName": "db_app_example_com", "username": "u_app_example_com", "secretPresent": true }
```

## Backups

### POST /sites/:slug/backup/enable
Request:
```json
{ "retentionDays": 14, "schedule": "0 3 * * *" }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "backupEnabled": true, "retentionDays": 14, "schedule": "0 3 * * *" }
```

### POST /sites/:slug/backup/disable
Response:
```json
{ "ok": true, "slug": "app-example-com", "backupEnabled": false }
```

### PATCH /sites/:slug/backup/config
Request:
```json
{ "retentionDays": 30, "schedule": "0 2 * * *" }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "retentionDays": 30, "schedule": "0 2 * * *" }
```

### POST /sites/:slug/backup/run
Response:
```json
{ "ok": true, "slug": "app-example-com", "started": true }
```

### GET /sites/:slug/backup/snapshots
Response:
```json
{ "ok": true, "slug": "app-example-com", "items": [{ "id": "20260120T030000Z", "hasFiles": true, "hasDb": true, "sizeBytes": 12345 }] }
```

### POST /sites/:slug/backup/restore
Request:
```json
{ "snapshotId": "20260120T030000Z", "restoreFiles": true, "restoreDb": true }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "restored": true, "snapshotId": "20260120T030000Z" }
```

### POST /sites/:slug/backup/purge
Request:
```json
{ "confirm": "DELETE" }
```
Response:
```json
{ "ok": true, "slug": "app-example-com", "purged": true }
```

## Error codes (global)
- `400` invalid input or missing required fields.
- `401` missing/invalid `X-API-Key`.
- `404` missing site/namespace or backup archive.
- `409` conflict (disabled features, missing config, or already exists).
- `500` controller/infra failures.
