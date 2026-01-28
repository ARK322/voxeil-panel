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

### Quick Start

**⚠️ IMPORTANT: This repository does NOT require cloning. Everything works via a single curl-based command.**

**One-command installation:**
```bash
curl -fL -o /tmp/voxeil.sh https://raw.githubusercontent.com/ARK322/voxeil-panel/main/voxeil.sh && bash /tmp/voxeil.sh install
```

**About `voxeil.sh`:**
- `voxeil.sh` is the **single entrypoint** for all Voxeil operations (install, uninstall, purge-node, doctor)
- It is an **ephemeral script** that you download and run (typically to `/tmp/voxeil.sh`)
- It is **NOT** installed system-wide
- It is **NOT** removed by `uninstall` or `purge-node` commands
- **Deleting `/tmp/voxeil.sh` does NOT affect the installed system** - the script is ephemeral and can be safely removed
- **`uninstall` and `purge-node` do NOT automatically delete `/tmp/voxeil.sh`** - you must manually delete it if needed
- You can safely delete and re-download it at any time
- The script orchestrates everything and downloads internal scripts (`cmd/*.sh` orchestrators) from GitHub as needed
- **Repository cloning is NOT required for end users** - this repo is for development only

**Internal Structure:**
- `voxeil.sh` → dispatcher (arg parsing + cmd dispatch)
- `cmd/` → orchestrators (`install.sh`, `uninstall.sh`, `purge-node.sh`, `doctor.sh`)
- `phases/` → phase scripts (modular, numbered execution order: `00-preflight.sh`, `10-k3s.sh`, `20-core.sh`, etc.)
- `lib/` → shared utilities (`common.sh`, `kube.sh`, `k3s.sh`, `net.sh`, `fs.sh`, `validate.sh`)
- `tools/` → CI/ops scripts (`ci/`, `ops/`) - moved from `scripts/`
- `installer/installer.sh`, `uninstaller/uninstaller.sh`, `nuke/nuke.sh` → backward-compatible wrappers

**Note:** The `installer/`, `uninstaller/`, `cmd/`, `lib/`, `phases/`, and `tools/` directories are **internal only** and should **never** be accessed directly by end users. Use `voxeil.sh` as the single entrypoint.

### Commands

All commands are executed via `voxeil.sh`:

- `install` - Install Voxeil Panel
- `uninstall [--force]` - Safe uninstall (removes only Voxeil resources)
- `purge-node --force` - Complete node wipe (removes k3s, requires --force)
- `nuke --force` - Alias for `purge-node` (IRREVERSIBLE, requires --force)
- `doctor` - Check installation status (read-only)

**Command comparison:**

| Command | What it removes | Reversible | Requires --force |
|---------|----------------|-------------|-------------------|
| `uninstall` | Only Voxeil resources (namespaces, CRDs, webhooks, PVs) | Yes (safe) | Optional (for unlabeled leftovers) |
| `purge-node` | k3s + all Kubernetes data + Voxeil resources | No (IRREVERSIBLE) | Yes (mandatory) |
| `nuke` | Same as `purge-node` (alias/wrapper) | No (IRREVERSIBLE) | Yes (mandatory) |

### Install

**Basic installation:**
```bash
bash /tmp/voxeil.sh install
```

The installer will prompt for:
- Panel domain (TLS enabled via cert-manager)
- Let's Encrypt email (required for cert-manager)

**Install flags:**

| Flag | Description |
|------|-------------|
| `--doctor` | Print installation status, make no changes |
| `--dry-run` | Show what would be installed without making changes |
| `--force` | Force installation even if components exist |
| `--skip-k3s` | Skip k3s installation (fail if kubectl unavailable) |
| `--install-k3s` | Install k3s if missing (idempotent) |
| `--kubeconfig <path>` | Use specific kubeconfig file |
| `--profile minimal\|full` | Installation profile (default: full) |
| `--with-mail` | Install mailcow (opt-in) |
| `--with-dns` | Install bind9 DNS (opt-in) |
| `--version <tag\|branch\|commit>` | Use specific version/ref (overrides --channel) |
| `--channel stable\|main` | Use stable or main channel (default: main) |
| `--build-images` | Build backup images locally (default: skip, images pulled from registry) |

**Profile options:**
- `minimal`: Platform essentials only (no kyverno/cert-manager/flux unless already used)
- `full`: Includes cert-manager, kyverno, flux, infra-db, backup-system

**Image build options:**
- By default, backup images are **not built locally** (Docker dependency avoided)
- Use `--build-images` flag to build backup images locally before k3s installation
- If `--build-images` is not used, backup images will be pulled from the registry when needed
- If GHCR image validation fails during install, the installer will show a warning and continue (you can skip validation with `SKIP_IMAGE_VALIDATION=true` env var)

**Examples:**
```bash
# Check what's installed (doctor mode)
bash /tmp/voxeil.sh doctor

# Minimal install (platform only)
bash /tmp/voxeil.sh install --profile minimal

# Full install with mail and DNS
bash /tmp/voxeil.sh install --profile full --with-mail --with-dns

# Install on existing cluster (skip k3s)
bash /tmp/voxeil.sh install --skip-k3s --kubeconfig ~/.kube/config

# Install specific version
bash /tmp/voxeil.sh --ref v1.0.0 install
```

### Uninstall (Safe)

**This removes ONLY Voxeil platform resources. It does NOT remove k3s, docker, or system namespaces.**

**Command differences:**
- **`uninstall`** → Safe uninstall that removes only Voxeil resources (namespaces, CRDs, webhooks, PVs). Does NOT remove k3s. Safe and reversible.
- **`purge-node`** → Complete node wipe that removes k3s and all Kubernetes data. Requires `--force` flag. **IRREVERSIBLE**.
- **`nuke`** → Alias/wrapper for `purge-node`. **IRREVERSIBLE** - there is no going back.

**Note:** `uninstall` is safe and reversible—it only removes Voxeil components. For a complete node wipe (including k3s), use `purge-node` instead (see below).

**Safe uninstall:**
```bash
curl -fL -o /tmp/voxeil.sh https://raw.githubusercontent.com/ARK322/voxeil-panel/main/voxeil.sh && bash /tmp/voxeil.sh uninstall --force
```

**Note:** The `uninstall` command will **NOT** delete `/tmp/voxeil.sh`. You can manually delete it if needed.

**Uninstall flags:**

| Flag | Description |
|------|-------------|
| `--doctor` | Print what exists and recommended next commands, make no changes |
| `--dry-run` | Show what would be removed without making changes |
| `--force` | Clean up unlabeled leftovers when state file is missing |
| `--keep-volumes` | Keep PersistentVolumes (default: delete PVs) |
| `--kubeconfig <path>` | Use specific kubeconfig file |

**What gets removed:**
- All Voxeil namespaces (platform, infra-db, dns-zone, mail-zone, backup-system, kyverno, flux-system, cert-manager)
- All user-* and tenant-* namespaces
- All resources labeled `app.kubernetes.io/part-of=voxeil`
- Kyverno, Flux, and cert-manager CRDs and webhooks
- PersistentVolumes (unless `--keep-volumes`)
- Filesystem files (/etc/voxeil, /var/lib/voxeil, etc.)

**What does NOT get removed:**
- k3s or docker
- System namespaces (kube-system, default, kube-public, kube-node-lease)
- Other workloads on the cluster
- `/tmp/voxeil.sh` (the entrypoint script)

**State file behavior:**
- If `/var/lib/voxeil/install.state` is missing, uninstall will **warn** and require `--force` to proceed
- This is a safety measure to prevent accidental cleanup of unlabeled resources

**Examples:**
```bash
# Check what exists (doctor mode)
bash /tmp/voxeil.sh doctor

# Safe uninstall (uses state registry)
bash /tmp/voxeil.sh uninstall

# Force cleanup (for leftovers / state missing)
bash /tmp/voxeil.sh uninstall --force

# Uninstall but keep volumes
bash /tmp/voxeil.sh uninstall --keep-volumes
```

### Purge Node (Full Reset)

⚠️ **WARNING: This will delete the Kubernetes cluster on this node. This is irreversible and different from `uninstall`.**

**Unlike `uninstall` (which only removes Voxeil platform resources), `purge-node` completely wipes the node:**
- Removes k3s using `/usr/local/bin/k3s-uninstall.sh` if present
- Removes `/var/lib/rancher` and `/etc/rancher`
- Removes `/var/lib/voxeil` state registry
- Does NOT remove docker packages (unless k3s-uninstall.sh does)
- OS remains intact

**Requires explicit --force flag:**
```bash
curl -fL -o /tmp/voxeil.sh https://raw.githubusercontent.com/ARK322/voxeil-panel/main/voxeil.sh && bash /tmp/voxeil.sh purge-node --force
```

**Note:** 
- The `purge-node` command requires `--force` as a safety measure to prevent accidental node wipe
- The `purge-node` command will **NOT** delete `/tmp/voxeil.sh`. You can manually delete it if needed
- **`nuke` is a wrapper/alias for `purge-node`** - both are **IRREVERSIBLE** and require `--force`

### Doctor Mode (Production Gate)

**Doctor mode is a read-only PROD GATE** that checks installation status without making changes. **Before deploying to production, doctor must PASS (exit code 0).**

```bash
bash /tmp/voxeil.sh doctor
```

**Exit codes:**

| Exit Code | Result | Meaning | Action Required |
|-----------|--------|---------|-----------------|
| 0 | PASS | No critical problems detected | Safe to proceed to production |
| 1 | FAIL | Critical problems found | Must fix issues before production |
| 2 | UNABLE_TO_CHECK | Doctor unable to check (kubectl unavailable, cluster unreachable, permission issues) | Fix kubectl/cluster access, then re-run doctor |

**What it checks:**
- State file contents (`/var/lib/voxeil/install.state`)
- Resources labeled `app.kubernetes.io/part-of=voxeil`
- Stuck Terminating namespaces
- Problematic pod states (ImagePullBackOff, CrashLoopBackOff, NotReady, etc.)
- Webhook deadlock risks (webhooks without ready controller pods)
- Unlabeled namespaces that might be leftovers
- PersistentVolumes tied to voxeil namespaces (by claimRef)
- Webhook configurations (validating and mutating)
- CRDs (Custom Resource Definitions)
- ClusterRoles and ClusterRoleBindings
- PVCs

Doctor mode **never modifies the system** and shows recommended next commands in its output. **Prod'a çıkmadan önce doctor PASS olmalı (exit code 0).**

### Version Pinning

Use `--ref` to pin a specific version:

```bash
# Install specific version
bash /tmp/voxeil.sh --ref v1.0.0 install

# Uninstall using specific version
bash /tmp/voxeil.sh --ref v1.0.0 uninstall --force
```

### Build Images (Optional)

**During installation:**
- Use `--build-images` flag to build backup images locally before k3s installation
- Default: backup images are skipped (pulled from registry when needed)

**For local development or custom builds:**
```bash
# Build images locally
./tools/ci/build-images.sh --tag local

# Build and push to GHCR
./tools/ci/build-images.sh --push --tag latest
```

**Note:** The `tools/` directory is for internal CI/ops use only. End users should use `voxeil.sh` commands.

### Common Scenarios

**I want to reinstall Voxeil:**
```bash
# Uninstall existing installation
bash /tmp/voxeil.sh uninstall --force

# Reinstall
bash /tmp/voxeil.sh install
```

**I want to clean leftovers after a failed install:**
```bash
# Check what's left
bash /tmp/voxeil.sh doctor

# Force cleanup
bash /tmp/voxeil.sh uninstall --force
```

**I want to reuse the node for something else:**
```bash
# Uninstall Voxeil resources (safe, removes only Voxeil components)
bash /tmp/voxeil.sh uninstall --force

# If you also want to remove k3s (irreversible, full node wipe)
bash /tmp/voxeil.sh purge-node --force
```

### Testing Workflow (Fresh VPS)

**Reproducible testing on a fresh Ubuntu VPS:**

This workflow verifies that install, uninstall, and purge-node work correctly on a clean system:

```bash
# 1. Download voxeil.sh
curl -fL -o /tmp/voxeil.sh https://raw.githubusercontent.com/ARK322/voxeil-panel/main/voxeil.sh
chmod +x /tmp/voxeil.sh

# 2. Check initial state (should be clean)
bash /tmp/voxeil.sh doctor

# 3. Install Voxeil Panel
bash /tmp/voxeil.sh install
# Follow prompts for panel domain and admin email

# 4. Verify installation
bash /tmp/voxeil.sh doctor
# Should show k3s installed, cluster ready, Traefik/Flux status

# 5. Uninstall (safe, removes only Voxeil resources)
bash /tmp/voxeil.sh uninstall --force

# 6. Verify uninstall
bash /tmp/voxeil.sh doctor
# Should show clean state (k3s still present)

# 7. Reinstall (verify install -> uninstall -> install works)
bash /tmp/voxeil.sh install

# 8. Verify reinstall
bash /tmp/voxeil.sh doctor

# 9. Purge node (complete reset, removes k3s)
bash /tmp/voxeil.sh purge-node --force

# 10. Verify purge
bash /tmp/voxeil.sh doctor
# Should show k3s not installed

# 11. Reboot (recommended after purge-node)
sudo reboot

# 12. After reboot, verify clean state
bash /tmp/voxeil.sh doctor
# System should be completely clean
```

**Expected results:**
- Install succeeds without deadlocks
- Traefik installs cleanly (no HelmChartConfig mismatch errors)
- Uninstall removes all Voxeil resources without stuck namespaces/webhooks
- Install -> uninstall -> install cycle succeeds
- Purge-node leaves system clean without requiring OS format
- No stuck namespaces, webhooks, or helm jobs after uninstall/purge

### Installation Outputs

After successful installation:
- Panel admin username + password + email (stored in `platform-secrets`)
- Controller API key (stored in `platform-secrets`)
- Panel URL: `https://<PANEL_DOMAIN>`
- pgAdmin URL: `https://pgadmin.<PANEL_DOMAIN>`
- Mailcow UI: `https://mail.<PANEL_DOMAIN>` (if `--with-mail` was used)

Note: `SITE_NODEPORT_START/END` are reserved for Phase 3 and currently unused by the controller.

### Phase 2 publish
- Creating a site provisions the namespace and immediately publishes a shared maintenance page.
- Deployments happen only via `POST /sites/:slug/deploy` (manual).
- Domains and subdomains are treated as separate sites (separate namespaces).

### Phase 3 TLS (cert-manager)
- cert-manager is cluster-wide and installed with the `full` profile (default).
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

### Legacy Cleanup

**Refactoring Notes:**
- Eski monolitik scriptler (`installer.sh`, `uninstaller.sh`, `nuke.sh`) fazlara bölündü ve modüler hale getirildi
- Gereksiz / duplicate / unreachable kodlar kaldırıldı
- Tüm iş mantığı `phases/` altında modüler phase scriptlerine taşındı
- Ortak fonksiyonlar `lib/` altında merkezileştirildi
- `tools/` altındaki scriptler (`ci/`, `ops/`) prod kurulumun parçası değildir - bunlar CI/CD ve operasyonel yardımcı scriptlerdir
- `installer/installer.sh`, `uninstaller/uninstaller.sh`, `nuke/nuke.sh` artık sadece wrapper görevi görür (backward compatibility için)

**Script Yapısı:**
- `voxeil.sh` → tek entrypoint (dispatcher)
- `cmd/*.sh` → orchestrators (phase'leri sırayla çalıştırır)
- `phases/**/*.sh` → modüler phase scriptleri (numara sırasıyla çalışır)
- `lib/*.sh` → paylaşılan utility fonksiyonları
- `tools/**/*.sh` → CI/ops helper scriptleri (prod kurulumun parçası değil)

### Future TODOs
- Add HTTPS/ingress once domain support is enabled.
- Extend quota/limit presets per plan.
- Add per-tenant API keys and audit logging.

### GitHub Deploy
See `docs/github-workflow-example.md` for a sample workflow that builds an image and triggers deploy.
