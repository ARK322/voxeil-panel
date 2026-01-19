## Voxeil Panel (MVP)

Self-hosted, Kubernetes-native hosting control panel. API-first with a minimal UI shipped in this repo.

### Components
- `apps/controller`: Fastify API that owns all Kubernetes access (namespaces, quotas, PVCs, network policies).
- `apps/panel`: Next.js UI that talks only to the controller service inside the cluster.
- `infra/k8s/platform`: k3s-compatible manifests with placeholders (`REPLACE_*`) for images and NodePorts.
- `infra/k8s/templates/tenant`: Baseline ResourceQuota, LimitRange, and default-deny NetworkPolicy used for every tenant namespace.

### Data model note
- Control-plane DB: one shared PostgreSQL instance for controller state in `db-zone`.
- Tenant site DBs: per-site database + role/user inside that same shared PostgreSQL cluster.
- Shared services run in their own namespaces (`db-zone`, `mail-zone`, `backup-zone`); tenant namespaces only host site workloads.

### Install
1) Build/push your own images (no hardcoded registry):
   - Controller: `apps/controller`
   - Panel: `apps/panel`
   - Maintenance page: `voxeil-maintenance` (served from GHCR)
2) One-liner install (no git clone required):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/ARK322/voxeil-panel/main/install.sh | bash
   ```
   - Override `OWNER`, `REPO`, or `REF` env vars to point at a fork/tag if needed.
   - Provide GHCR credentials via env vars before running:
     - `GHCR_USERNAME`
     - `GHCR_TOKEN` (PAT with `read:packages`)
     - `GHCR_EMAIL` (optional)
   The installer will ask for:
   - Panel NodePort
   - Optional controller NodePort (admin-only)
   - Site NodePort range
   - IP allowlist (used with UFW if available)
   - Controller + panel image references
3) Outputs:
   - Panel admin password (stored in `platform-secrets`)
   - Controller API key (stored in `platform-secrets`)
   - Panel URL: `http://<VPS_IP>:<PANEL_NODEPORT>`
  - Note: `SITE_NODEPORT_START/END` are reserved for Phase 3 and currently unused by the controller.

### Phase 2 publish
- Creating a site provisions the namespace and immediately publishes a shared maintenance page.
- Deployments happen only via `POST /sites/:slug/deploy` (manual).
- Domains and subdomains are treated as separate sites (separate namespaces).

### Phase 3 TLS (cert-manager)
- cert-manager is cluster-wide and always installed by the installer.
- TLS is site-based and opt-in via `PATCH /sites/:slug/tls`.
- `LETSENCRYPT_EMAIL` is required only when enabling TLS for a site.
- TLS secret naming: `tls-<slug>` (per-site, deterministic).

### Security baseline
- Controller enforces `X-API-Key` on all routes except `/health`.
- Panel never talks directly to the Kubernetes API; it proxies via the controller service.
- Tenants get a dedicated namespace with ResourceQuota, LimitRange, and default-deny NetworkPolicy (DNS egress only).
- Controller creates tenant Deployments, Services, and Ingress on site creation.
- GHCR images are pulled via the `ghcr-pull-secret` copied into each tenant namespace.
- TLS is optional and site-based; HTTP ingress remains the default.

### Controller API
All routes require `X-API-Key` (except `/health`). The UI uses purge-only deletion via `POST /sites/:slug/purge`.
Disable endpoints are reversible and do not delete data. Purge endpoints delete data/resources and require `{ "confirm": "DELETE" }`.

Confirm payload example:
- `{ "confirm": "DELETE" }`

Sites:
- `POST /sites`
  - Body: `{ "domain": "app.example.com", "cpu": 1, "ramGi": 2, "diskGi": 10, "tlsEnabled": false, "tlsIssuer": "letsencrypt-prod" }`
  - Response: `{ "domain": "app.example.com", "slug": "app-example-com", "namespace": "tenant-app-example-com", "limits": { "cpu": 1, "ramGi": 2, "diskGi": 10, "pods": 1 } }`
- `GET /sites`
  - Response: `[ { "slug": "app-example-com", "namespace": "tenant-app-example-com", "ready": true, "domain": "app.example.com", "image": "...", "containerPort": 3000, "cpu": 1, "ramGi": 2, "diskGi": 10, "tlsEnabled": false, "tlsIssuer": "letsencrypt-prod", "dbEnabled": false, "mailEnabled": false, "backupEnabled": true, "dbName": "db_app-example-com", "dbUser": "u_app-example-com", "dbSecret": "site-db" } ]`
- `POST /sites/:slug/purge` (irreversible)
  - Body: `{ "confirm": "DELETE" }`
  - Deletes tenant namespace, drops db/user, deletes mail domain + mailboxes, and removes `/backups/sites/<slug>`.
  - Response: `{ "ok": true, "slug": "app-example-com", "purged": true }`

TLS (site-based, default OFF):
- `PATCH /sites/:slug/tls`
  - Body: `{ "enabled": true, "issuer": "letsencrypt-prod" }`
  - Body (disable + cleanup): `{ "enabled": false, "cleanupSecret": true }`
  - Response: `{ "ok": true, "slug": "app-example-com", "tlsEnabled": false, "issuer": "letsencrypt-prod" }`

DB feature (shared Postgres zone, per-site db/user):
- `POST /sites/:slug/db/enable` (idempotent)
  - Response: `{ "ok": true, "slug": "app-example-com", "dbEnabled": true, "dbName": "db_app-example-com", "secretName": "site-db" }`
- `POST /sites/:slug/db/disable` (reversible)
  - Deletes the tenant `site-db` Secret only.
  - Response: `{ "ok": true, "slug": "app-example-com", "dbEnabled": false }`
- `POST /sites/:slug/db/purge` (irreversible)
  - Body: `{ "confirm": "DELETE" }`
  - Drops `db_<slug>` and role `u_<slug>`, deletes `site-db` Secret.
  - Response: `{ "ok": true, "slug": "app-example-com", "dbEnabled": false }`

Mail feature (shared Mailcow zone):
- `POST /sites/:slug/mail/enable` (idempotent)
  - Body: `{ "domain": "example.com" }`
  - Response: `{ "ok": true, "slug": "app-example-com", "domain": "example.com", "mailEnabled": true, "provider": "mailcow" }`
- `POST /sites/:slug/mail/disable` (reversible)
  - Disables mail for the site without deleting domains or mailboxes.
  - Response: `{ "ok": true, "slug": "app-example-com", "domain": "example.com", "mailEnabled": false, "provider": "mailcow" }`
- `POST /sites/:slug/mail/purge` (irreversible)
  - Body: `{ "confirm": "DELETE" }`
  - Deletes all mailboxes/aliases and removes the domain.
  - Response: `{ "ok": true, "slug": "app-example-com", "domain": "example.com", "mailEnabled": false, "purged": true, "provider": "mailcow" }`
- `POST /sites/:slug/mail/mailboxes`
  - Body: `{ "localPart": "hello", "password": "secret", "quotaMb": 512 }`
  - Response: `{ "ok": true, "slug": "app-example-com", "address": "hello@example.com" }`
- `DELETE /sites/:slug/mail/mailboxes/:address`
  - Response: `{ "ok": true, "slug": "app-example-com", "address": "hello@example.com" }`
Backup feature (shared backup zone):
- `POST /sites/:slug/backup/enable` (idempotent)
  - Response: `{ "ok": true, "slug": "app-example-com", "backupEnabled": true }`
- `POST /sites/:slug/backup/disable` (reversible)
  - Response: `{ "ok": true, "slug": "app-example-com", "backupEnabled": false }`
- `POST /sites/:slug/backup/purge` (irreversible)
  - Body: `{ "confirm": "DELETE" }`
  - Deletes `/backups/sites/<slug>` if present.
  - Response: `{ "ok": true, "slug": "app-example-com", "backupEnabled": false, "purged": true }`

Internal/admin endpoints (UI does not use):
- `DELETE /sites/:slug` (soft delete)
  - Deletes tenant namespace only. DB, mail, and backups are preserved.
  - Response: `{ "ok": true, "slug": "app-example-com" }`

### Future TODOs
- Add HTTPS/ingress once domain support is enabled.
- Extend quota/limit presets per plan.
- Add per-tenant API keys and audit logging.