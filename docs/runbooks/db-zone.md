# DB Zone Runbook

## Connectivity
- Shared Postgres runs in the `infra` namespace at `postgres.infra.svc.cluster.local:5432`.
- Controller connects using `DB_ADMIN_USER/DB_ADMIN_PASSWORD` from `platform-secrets`.
- Tenant apps must use the per-site `site-db` secret in their namespace.

## Credential rotation
- Rotate the admin password by updating:
  - `infra/postgres-secret` (key `POSTGRES_PASSWORD`)
  - `platform/platform-secrets` (key `DB_ADMIN_PASSWORD`)
- Restart the `postgres` StatefulSet and controller deployment after rotation.

## Restore note
- Database restores use controller `POST /sites/:slug/restore/db` and read backups from
  `/backups/sites/<slug>/db/<timestamp>.sql.gz`.
