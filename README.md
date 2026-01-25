## Voxeil Panel (MVP)

Self-hosted, Kubernetes-native hosting control panel. API-first with a minimal UI shipped in this repo.

### Components
- `apps/controller`: Fastify API that owns all Kubernetes access (namespaces, quotas, PVCs, network policies).
- `apps/panel`: Next.js UI that talks only to the controller service inside the cluster.
- `infra/k8s/platform`: k3s-compatible manifests with placeholders (`REPLACE_*`) for images and NodePorts.
- `infra/k8s/templates/tenant`: Baseline ResourceQuota, LimitRange, and default-deny NetworkPolicy used for every tenant namespace.
- `infra/k8s/dns`: Bind9 DNS service (installed by default; site usage opt-in).

### Data model note
- Control-plane DB: one shared PostgreSQL instance for controller state in `infra`.
- Tenant site DBs: per-site database + role/user inside that same shared PostgreSQL cluster.
- Shared services run in their own namespaces (`infra`, `mail-zone`, `backup`, `dns-zone`); tenant namespaces only host site workloads.

### Install
1) Build/push your own images (no hardcoded registry):
   - Controller: `apps/controller`
   - Panel: `apps/panel`
   - Maintenance page: `voxeil-maintenance` (served from GHCR)
   
   To build images locally:
   ```bash
   # Build images (local tags)
   ./scripts/build-images.sh --tag local
   
   # Build and push to GHCR
   ./scripts/build-images.sh --push --tag latest
   
   # Or build manually:
   cd apps/controller && docker build -t ghcr.io/ark322/voxeil-controller:latest .
   cd apps/panel && docker build -t ghcr.io/ark322/voxeil-panel:latest .
   docker push ghcr.io/ark322/voxeil-controller:latest
   docker push ghcr.io/ark322/voxeil-panel:latest
   ```
   
2) Install Voxeil platform (idempotent):
   
   **Recommended (download first to avoid pipe failures):**
   ```bash
   curl -fL -o /tmp/voxeil-install.sh https://raw.githubusercontent.com/ARK322/voxeil-panel/main/install.sh
   bash /tmp/voxeil-install.sh [flags]
   ```
   
   **Or one-liner (may fail with curl:(23) pipe errors):**
   ```bash
   curl -fsSL https://raw.githubusercontent.com/ARK322/voxeil-panel/main/install.sh | bash
   ```
   
   **Installer flags:**
   - `--doctor` - Print installation status, make no changes
   - `--dry-run` - Show what would be installed without making changes
   - `--force` - Force installation even if components exist
   - `--skip-k3s` - Skip k3s installation (fail if kubectl unavailable)
   - `--install-k3s` - Install k3s if missing (idempotent)
   - `--kubeconfig <path>` - Use specific kubeconfig file
   - `--profile minimal|full` - Installation profile (default: full)
     - `minimal`: Platform essentials only (no kyverno/cert-manager/flux unless already used)
     - `full`: Includes cert-manager, kyverno, flux, infra-db, backup-system
   - `--with-mail` - Install mailcow (opt-in)
   - `--with-dns` - Install bind9 DNS (opt-in)
   
   **Examples:**
   ```bash
   # Check what's installed (doctor mode)
   bash installer/installer.sh --doctor
   
   # Minimal install (platform only)
   bash installer/installer.sh --profile minimal
   
   # Full install with mail and DNS
   bash installer/installer.sh --profile full --with-mail --with-dns
   
   # Install on existing cluster (skip k3s)
   bash installer/installer.sh --skip-k3s --kubeconfig ~/.kube/config
   ```
   
   The installer will prompt for:
   - Panel domain (TLS enabled via cert-manager)
   - Let's Encrypt email (required for cert-manager)
   
   Override `OWNER`, `REPO`, or `REF` env vars to point at a fork/tag if needed.

### Uninstall

**Safe uninstall (default):** Removes ONLY Voxeil resources, never touches kube-system/default/kube-public/kube-node-lease or k3s/docker.

**Recommended (download first):**
```bash
curl -fL -o /tmp/voxeil-uninstall.sh https://raw.githubusercontent.com/ARK322/voxeil-panel/main/uninstaller/uninstaller.sh
bash /tmp/voxeil-uninstall.sh [flags]
```

**Or one-liner:**
```bash
curl -fsSL https://raw.githubusercontent.com/ARK322/voxeil-panel/main/uninstaller/uninstaller.sh | bash
```

**Uninstaller flags:**
- `--doctor` - Print what exists and recommended next commands, make no changes
- `--dry-run` - Show what would be removed without making changes
- `--force` - Clean up unlabeled leftovers when state file is missing
- `--purge-node` - Remove k3s and rancher directories (requires --force)
- `--keep-volumes` - Keep PersistentVolumes (default: delete PVs)
- `--kubeconfig <path>` - Use specific kubeconfig file

**Safety rules:**
1. Default uninstall NEVER deletes kube-system/default/kube-public/kube-node-lease
2. Default uninstall NEVER uninstalls k3s/docker/runtime
3. Node wipe requires: `--purge-node --force` (explicit opt-in)
4. If `/var/lib/voxeil/install.state` exists → uninstall only what KEY=1
5. If state missing: default uninstall prints warning and exits 0 (safe)
6. `--force` triggers fallback cleanup (known leftovers + pattern match) safely

**Examples:**
```bash
# Check what exists (doctor mode)
bash uninstaller/uninstaller.sh --doctor

# Safe uninstall (uses state registry)
bash uninstaller/uninstaller.sh

# Force cleanup (for leftovers / state missing)
bash uninstaller/uninstaller.sh --force

# Purge node (removes k3s + rancher dirs, requires --force)
bash uninstaller/uninstaller.sh --purge-node --force

# Uninstall but keep volumes
bash uninstaller/uninstaller.sh --keep-volumes
```

**What gets removed:**
- All Voxeil namespaces (platform, infra-db, dns-zone, mail-zone, backup-system, kyverno, flux-system, cert-manager)
- All user-* and tenant-* namespaces
- All resources labeled `app.kubernetes.io/part-of=voxeil`
- Kyverno, Flux, and cert-manager CRDs and webhooks
- PersistentVolumes (unless --keep-volumes)
- Filesystem files (/etc/voxeil, /var/lib/voxeil, etc.)

**Node purge (--purge-node --force):**
- Removes k3s binaries and /usr/local/bin/k3s-uninstall.sh
- Removes /var/lib/rancher and /etc/rancher
- Removes /var/lib/voxeil state registry
- Does NOT remove docker packages (unless k3s-uninstall.sh does)
3) Outputs:
  - Panel admin username + password + email (stored in `platform-secrets`)
   - Controller API key (stored in `platform-secrets`)
   - Panel URL: `https://<PANEL_DOMAIN>`
  - pgAdmin URL: `https://pgadmin.<PANEL_DOMAIN>`
  - Mailcow UI: `https://mail.<PANEL_DOMAIN>`
  - Note: `SITE_NODEPORT_START/END` are reserved for Phase 3 and currently unused by the controller.

### Phase 2 publish
- Creating a site provisions the namespace and immediately publishes a shared maintenance page.
- Deployments happen only via `POST /sites/:slug/deploy` (manual).
- Domains and subdomains are treated as separate sites (separate namespaces).

### Phase 3 TLS (cert-manager)
- cert-manager is cluster-wide and always installed by the installer.
- TLS is site-based and opt-in via `PATCH /sites/:slug/tls`.
- `LETSENCRYPT_EMAIL` is required at install time to configure ClusterIssuers.
- TLS secret naming: `tls-<slug>` (per-site, deterministic).

Ingress snapshot (TLS enabled):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
  - hosts: [app.example.com]
    secretName: tls-app-example-com
```

### Security baseline
- Controller enforces `X-API-Key` on all routes except `/health`.
- Panel never talks directly to the Kubernetes API; it proxies via the controller service.
- Tenants get a dedicated namespace with ResourceQuota, LimitRange, and default-deny NetworkPolicy (DNS egress only).
- Controller creates tenant Deployments, Services, and Ingress on site creation.
- GHCR images are pulled via the `ghcr-pull-secret` copied into each tenant namespace.
- TLS is optional and site-based; HTTP ingress remains the default.
- UFW + fail2ban are configured on install; ClamAV is installed when available.
- Controller stays internal (ClusterIP only).

### Controller API
All routes require `X-API-Key` (except `/health`). The UI uses purge-only deletion via `POST /sites/:slug/purge`.
Disable endpoints are reversible and do not delete data. Purge endpoints delete data/resources and require `{ "confirm": "DELETE" }`.

Confirm payload example:
- `{ "confirm": "DELETE" }`

### DB Zone contract
- Shared Postgres lives in `infra`, with per-site databases and roles.
- Enable creates `db_<slug>` + `u_<slug>` and a tenant `db-conn` Secret.
- Disable removes the tenant Secret only (reversible).
- Purge revokes connections, drops db/role, deletes the Secret (irreversible; confirm required).
- Tenant secret keys: `host`, `port`, `database`, `username`, `password`, `url`.

Sites:
- `POST /sites`
  - Body: `{ "domain": "app.example.com", "cpu": 1, "ramGi": 2, "diskGi": 10, "tlsEnabled": false, "tlsIssuer": "letsencrypt-prod" }`
  - Response: `{ "domain": "app.example.com", "slug": "app-example-com", "namespace": "tenant-app-example-com", "limits": { "cpu": 1, "ramGi": 2, "diskGi": 10, "pods": 1 } }`
- `GET /sites`
  - Response: `[ { "slug": "app-example-com", "namespace": "tenant-app-example-com", "ready": true, "domain": "app.example.com", "image": "...", "containerPort": 3000, "cpu": 1, "ramGi": 2, "diskGi": 10, "tlsEnabled": false, "tlsIssuer": "letsencrypt-prod", "dbEnabled": false, "mailEnabled": false, "mailDomain": "example.com", "backupEnabled": false, "backupRetentionDays": 14, "backupSchedule": "0 3 * * *", "backupLastRunAt": "2026-01-20T03:00:00.000Z", "dbName": "db_app-example-com", "dbUser": "u_app-example-com", "dbSecret": "site-db" } ]`
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
  - Body: `{ "dbName": "db_app_example_com" }` (optional; defaults to `db_<slug>`)
  - Response: `{ "ok": true, "slug": "app-example-com", "dbEnabled": true, "dbName": "db_app_example_com", "username": "u_app_example_com" }`
- `POST /sites/:slug/db/disable` (reversible)
  - Deletes the tenant `db-conn` Secret only.
  - Response: `{ "ok": true, "slug": "app-example-com", "dbEnabled": false }`
- `POST /sites/:slug/db/purge` (irreversible)
  - Body: `{ "confirm": "DELETE" }`
  - Revokes connections, drops `db_<slug>` and role `u_<slug>`, deletes `db-conn` Secret.
  - Response: `{ "ok": true, "slug": "app-example-com", "purged": true }`
- `GET /sites/:slug/db/status`
  - Response: `{ "ok": true, "slug": "app-example-com", "dbEnabled": true, "dbName": "db_app_example_com", "username": "u_app_example_com", "secretPresent": true }`

Mail feature (shared Mailcow zone):
- `POST /sites/:slug/mail/enable` (idempotent)
  - Body: `{ "domain": "example.com" }`
  - Response: `{ "ok": true, "slug": "app-example-com", "domain": "example.com", "mailEnabled": true, "provider": "mailcow" }`
- `POST /sites/:slug/mail/disable` (reversible)
  - Disables mail for the site without deleting domains or mailboxes; sets the Mailcow domain inactive.
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
- `GET /sites/:slug/mail/mailboxes`
  - Response: `{ "ok": true, "slug": "app-example-com", "domain": "example.com", "mailboxes": ["hello@example.com"] }`
- `POST /sites/:slug/mail/aliases`
  - Body: `{ "sourceLocalPart": "info", "destination": "dest@example.net", "active": true }`
  - Response: `{ "ok": true, "slug": "app-example-com", "source": "info@example.com" }`
- `DELETE /sites/:slug/mail/aliases/:source`
  - Response: `{ "ok": true, "slug": "app-example-com", "source": "info@example.com" }`
- `GET /sites/:slug/mail/aliases`
  - Response: `{ "ok": true, "slug": "app-example-com", "domain": "example.com", "aliases": ["info@example.com"] }`
- `GET /sites/:slug/mail/status`
  - Response: `{ "ok": true, "slug": "app-example-com", "domain": "example.com", "mailEnabled": true, "activeInMailcow": true }`

### Mailcow API Contract
Disable is reversible and sets the Mailcow domain inactive. Purge deletes mailboxes, aliases, and the domain.

Zone lifecycle:
- `POST /sites/:slug/mail/enable` -> `{ "domain": "example.com" }`
- `POST /sites/:slug/mail/disable`
- `POST /sites/:slug/mail/purge` -> `{ "confirm": "DELETE" }`

Mailbox CRUD:
- `GET /sites/:slug/mail/mailboxes`
- `POST /sites/:slug/mail/mailboxes` -> `{ "localPart": "hello", "password": "secret", "quotaMb": 512 }`
- `DELETE /sites/:slug/mail/mailboxes/:address`

Alias CRUD:
- `GET /sites/:slug/mail/aliases`
- `POST /sites/:slug/mail/aliases` -> `{ "sourceLocalPart": "info", "destination": "dest@example.net", "active": true }`
- `DELETE /sites/:slug/mail/aliases/:source`

Status:
- `GET /sites/:slug/mail/status`

### Backups

Backups (shared backup runner):
- Storage path: `/backups/sites/<slug>/` (`files/` + `db/`)
- `POST /sites/:slug/backup/enable` (idempotent)
  - Body: `{ "retentionDays": 14, "schedule": "0 3 * * *" }` (optional)
  - Response: `{ "ok": true, "slug": "app-example-com", "backupEnabled": true, "retentionDays": 14, "schedule": "0 3 * * *" }`
- `POST /sites/:slug/backup/disable` (reversible)
  - Response: `{ "ok": true, "slug": "app-example-com", "backupEnabled": false }`
- `PATCH /sites/:slug/backup/config`
  - Body: `{ "retentionDays": 30, "schedule": "0 2 * * *" }`
  - Response: `{ "ok": true, "slug": "app-example-com", "retentionDays": 30, "schedule": "0 2 * * *" }`
- `POST /sites/:slug/backup/run`
  - Response: `{ "ok": true, "slug": "app-example-com", "started": true }`
- `GET /sites/:slug/backup/snapshots`
  - Response: `{ "ok": true, "slug": "app-example-com", "items": [ { "id": "20260120T030000Z", "hasFiles": true, "hasDb": true, "sizeBytes": 12345 } ] }`
- `POST /sites/:slug/backup/restore`
  - Body: `{ "snapshotId": "20260120T030000Z", "restoreFiles": true, "restoreDb": true }`
  - Response: `{ "ok": true, "slug": "app-example-com", "restored": true, "snapshotId": "20260120T030000Z" }`
- `POST /sites/:slug/backup/purge` (irreversible)
  - Body: `{ "confirm": "DELETE" }`
  - Deletes backup archives only (retains directories).
  - Response: `{ "ok": true, "slug": "app-example-com", "purged": true }`

Internal/admin endpoints (UI does not use):
- `DELETE /sites/:slug` (soft delete)
  - Deletes tenant namespace only. DB, mail, and backups are preserved.
  - Response: `{ "ok": true, "slug": "app-example-com" }`

### Future TODOs
- Add HTTPS/ingress once domain support is enabled.
- Extend quota/limit presets per plan.
- Add per-tenant API keys and audit logging.

### GitHub Deploy
See `docs/github-workflow-example.md` for a sample workflow that builds an image and triggers deploy.
