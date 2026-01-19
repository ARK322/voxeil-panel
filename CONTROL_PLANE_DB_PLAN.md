# Control-Plane DB Plan (PostgreSQL)

## Scope and Principles
- This database is only for the controller/panel control-plane state.
- Tenant app databases (customer DBs) are not stored here; only metadata references.
- Mail zone, DB zone, and backup zone exist as shared infrastructure; their internal data stays in their own systems.
- Shared services always run in their own namespaces (zones), never in tenant namespaces.
- This is a planning document only; no runtime integration is introduced yet.

## DB Model Decisions
- Control-plane DB is one shared PostgreSQL instance in the `db-zone` namespace.
- Tenant site DBs live inside that shared PostgreSQL cluster (`db-zone`), with a per-site database and role/user.
- Mail zone is shared in the `mail-zone` namespace, with per-site mail resources tracked in control-plane metadata.
- Backup runner is shared in the `backup` namespace and stores only backup metadata in the control-plane DB.
- No per-site PostgreSQL pods in MVP.

## PostgreSQL Schema (DDL-Style Proposal)

### Enum Strategy
Use `CHECK` constraints for all status/kind enums for consistency.

### Tables

```sql
-- Sites: primary control-plane record for each tenant app
CREATE TABLE sites (
  id UUID PRIMARY KEY,
  slug TEXT NOT NULL,
  primary_domain TEXT NOT NULL,
  namespace TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN (
    'provisioning', 'active', 'suspended', 'deleting', 'deleted', 'error'
  )),
  dns_zone_id UUID NULL REFERENCES zones(id),
  mail_zone_id UUID NULL REFERENCES zones(id),
  db_zone_id UUID NULL REFERENCES zones(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ NULL,
  CONSTRAINT sites_slug_uniq UNIQUE (slug),
  CONSTRAINT sites_domain_uniq UNIQUE (primary_domain),
  CONSTRAINT sites_namespace_uniq UNIQUE (namespace)
);

CREATE INDEX sites_status_idx ON sites (status);
CREATE INDEX sites_created_at_idx ON sites (created_at);
CREATE INDEX sites_slug_idx ON sites (slug);
CREATE INDEX sites_domain_idx ON sites (primary_domain);
CREATE INDEX sites_namespace_idx ON sites (namespace);

-- Site limits: resource caps for a site
CREATE TABLE site_limits (
  site_id UUID PRIMARY KEY REFERENCES sites(id) ON DELETE CASCADE,
  cpu_millicores INT NOT NULL CHECK (cpu_millicores >= 0),
  memory_mb INT NOT NULL CHECK (memory_mb >= 0),
  disk_gb INT NOT NULL CHECK (disk_gb >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Site deploy: desired image + runtime deployment parameters
CREATE TABLE site_deploy (
  site_id UUID PRIMARY KEY REFERENCES sites(id) ON DELETE CASCADE,
  image_repository TEXT NOT NULL,
  image_tag TEXT NULL,
  image_digest TEXT NULL,
  port INT NOT NULL CHECK (port > 0 AND port <= 65535),
  replicas INT NOT NULL DEFAULT 1 CHECK (replicas >= 0),
  deploy_status TEXT NOT NULL CHECK (deploy_status IN (
    'pending', 'deploying', 'ready', 'failed'
  )),
  last_error TEXT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX site_deploy_status_idx ON site_deploy (deploy_status);

-- Site TLS: desired TLS config for ingress
CREATE TABLE site_tls (
  site_id UUID PRIMARY KEY REFERENCES sites(id) ON DELETE CASCADE,
  enabled BOOLEAN NOT NULL DEFAULT false,
  issuer TEXT NULL,
  secret_name TEXT NULL,
  tls_status TEXT NOT NULL CHECK (tls_status IN (
    'disabled', 'pending', 'ready', 'failed'
  )),
  last_error TEXT NULL,
  renewed_at TIMESTAMPTZ NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX site_tls_status_idx ON site_tls (tls_status);

-- Zones: shared infrastructure zones (mail/db/dns)
CREATE TABLE zones (
  id UUID PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('dns', 'mail', 'db', 'backup')),
  name TEXT NOT NULL,
  provider TEXT NULL,
  external_id TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT zones_kind_name_uniq UNIQUE (kind, name),
  CONSTRAINT zones_external_id_uniq UNIQUE (external_id)
);

CREATE INDEX zones_kind_idx ON zones (kind);

-- Site resources: provisioning records for K8s/infra assets
CREATE TABLE site_resources (
  id UUID PRIMARY KEY,
  site_id UUID NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN (
    'namespace', 'deployment', 'service', 'ingress', 'pvc', 'secret', 'job', 'cronjob'
  )),
  status TEXT NOT NULL CHECK (status IN (
    'pending', 'ready', 'failed', 'deleting'
  )),
  external_id TEXT NULL,
  last_error TEXT NULL,
  observed_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX site_resources_site_id_idx ON site_resources (site_id);
CREATE INDEX site_resources_status_idx ON site_resources (status);
CREATE INDEX site_resources_kind_idx ON site_resources (kind);
CREATE INDEX site_resources_external_id_idx ON site_resources (external_id);

-- Site databases: per-site DB provisioning metadata (shared db zone)
CREATE TABLE site_databases (
  site_id UUID PRIMARY KEY REFERENCES sites(id) ON DELETE CASCADE,
  engine TEXT NOT NULL CHECK (engine IN ('postgres')),
  db_name TEXT NOT NULL,
  db_user TEXT NOT NULL,
  credential_ref TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN (
    'pending', 'ready', 'failed', 'deleting'
  )),
  last_error TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Mail domains: per-site mail domain mappings (shared mail zone)
CREATE TABLE mail_domains (
  id UUID PRIMARY KEY,
  site_id UUID NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  domain TEXT NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN ('mailcow')),
  external_id TEXT NULL,
  status TEXT NOT NULL CHECK (status IN (
    'pending', 'ready', 'failed', 'deleting'
  )),
  last_error TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT mail_domains_site_domain_uniq UNIQUE (site_id, domain),
  CONSTRAINT mail_domains_domain_uniq UNIQUE (domain)
);

CREATE INDEX mail_domains_site_id_idx ON mail_domains (site_id);
CREATE INDEX mail_domains_status_idx ON mail_domains (status);

-- Mailboxes: mailbox metadata tracked in the control-plane only
CREATE TABLE mailboxes (
  id UUID PRIMARY KEY,
  mail_domain_id UUID NOT NULL REFERENCES mail_domains(id) ON DELETE CASCADE,
  local_part TEXT NOT NULL,
  quota_mb INT NULL CHECK (quota_mb >= 0),
  external_id TEXT NULL,
  status TEXT NOT NULL CHECK (status IN (
    'pending', 'ready', 'failed', 'deleting'
  )),
  last_error TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT mailboxes_domain_local_uniq UNIQUE (mail_domain_id, local_part)
);

CREATE INDEX mailboxes_domain_id_idx ON mailboxes (mail_domain_id);
CREATE INDEX mailboxes_status_idx ON mailboxes (status);

-- Jobs: async controller tasks
CREATE TABLE jobs (
  id UUID PRIMARY KEY,
  site_id UUID NULL REFERENCES sites(id) ON DELETE SET NULL,
  type TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN (
    'queued', 'running', 'succeeded', 'failed', 'canceled'
  )),
  payload JSONB NULL,
  attempts INT NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts INT NOT NULL DEFAULT 3 CHECK (max_attempts > 0),
  run_at TIMESTAMPTZ NULL,
  last_error TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX jobs_status_idx ON jobs (status);
CREATE INDEX jobs_run_at_idx ON jobs (run_at);
CREATE INDEX jobs_site_id_idx ON jobs (site_id);
CREATE INDEX jobs_created_at_idx ON jobs (created_at);

-- Audit logs: immutable control-plane events
CREATE TABLE audit_logs (
  id UUID PRIMARY KEY,
  site_id UUID NULL REFERENCES sites(id) ON DELETE SET NULL,
  actor_type TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  metadata JSONB NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX audit_logs_site_id_idx ON audit_logs (site_id);
CREATE INDEX audit_logs_action_idx ON audit_logs (action);
CREATE INDEX audit_logs_created_at_idx ON audit_logs (created_at);
```

### Future Additions (Placeholders Only)
- GitHub deploy fields: `github_owner`, `github_repo`, `github_ref`, `github_app_installation_id`, `github_commit_sha`.
- Cronjob fields: `schedule`, `command`, `timezone`, `suspend`, `last_run_at`.

## Migration / Reconcile Plan

### Schema migrations (v1 → v2)

**v1 (baseline control-plane schema)**:
- `sites`, `site_limits`, `site_deploy`, `site_tls`, `zones`, `site_resources`, `site_databases`, `jobs`, `audit_logs`.

**v2 (mail mapping metadata)**:
1) Add `mail_domains` and `mailboxes` tables.
2) Backfill:
   - For each tenant namespace with mail annotations, insert `mail_domains` with `provider='mailcow'`.
   - Insert `mailboxes` only if mailbox metadata exists (optional future endpoints).
3) Add indexes/constraints as defined above.

### Phase 0 (Today): Annotations are Source of Truth
- Controller reads and writes desired state from K8s namespace annotations.
- No DB integration; only current behavior.

### Phase 1: Dual-Read + Write-Through
- Introduce DB, but controller keeps annotations as source of truth.
- On any change, write to annotations and mirror into DB.
- Reads may consult DB to validate and report drift, but annotations still drive behavior.

### Phase 2: Backfill Job
- Enumerate tenant namespaces by label (e.g., `managed-by=voxeil` and `slug=<value>`).
- For each namespace:
  - Read annotations (domain, tls, image, port, cpu/ram/disk).
  - Upsert into `sites`, `site_limits`, `site_deploy`, and `site_tls`.
  - Create `site_resources` records for observed K8s objects.
  - Record drift or invalid values (e.g., missing domain, non-numeric limits) into `jobs` or `audit_logs`.

### Phase 3: DB Becomes Source of Truth
- Controller reads DB for desired state.
- Reconciler ensures K8s resources match DB (create/update/delete).
- Annotations become derived output and are updated only when DB changes.

### Phase 4: Minimal Annotation Usage (Optional)
- Reduce annotations to only minimal identifiers (slug/domain) for discovery.
- Everything else remains DB-driven.

### Conflict Handling
- If DB says `tls=true` but ingress lacks TLS, reconciler creates/repairs TLS and records a drift entry.
- If annotations conflict with DB during Phase 1/2, prefer annotation values for live behavior but log a drift item and surface a warning.
- If a resource exists in K8s but not in DB during Phase 3, treat it as orphaned and either adopt or delete based on policy.

### Rollback Plan
- If DB is unavailable or inconsistent, controller falls back to annotation reads.
- Disable DB write-through and continue annotation-only operation.
- Resume backfill once DB health is restored.

### Minimal Operational Checks
- DB connectivity and migration version are healthy.
- Backfill job backlog is empty or within tolerance.
- Reconciler error rate is low and no sustained drift.
- Recent audit logs show expected update cadence.
