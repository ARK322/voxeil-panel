# INSTALLER_RUNBOOK

## Provisioning checklist
- Generates `ADMIN_API_KEY` and stores it in `platform-secrets`.
- Creates GHCR pull secret in `platform` namespace.
- Installs cert-manager and ClusterIssuers (cluster-wide).
- Traefik stays default (k3s built-in).
- Mailcow always installed (site-based enable/disable via API).
- Backup namespace applied and `/backups/sites` host path prepared.
- Shared Postgres values written to `platform-secrets`.

## Required env vars
```
GHCR_USERNAME=...
GHCR_TOKEN=...   # read:packages
CONTROLLER_IMAGE=ghcr.io/<owner>/controller:tag
PANEL_IMAGE=ghcr.io/<owner>/panel:tag
LETSENCRYPT_EMAIL=admin@example.com
```

## Optional env vars
```
ALLOW_IP=1.2.3.4
```

## Tests
```
bash -n installer/installer.sh
```

```
# Render sanity (manual)
# Inspect rendered manifests in the temp directory path echoed by the installer.
```

## Expected output
- Prints Panel URL, admin password, controller API key.
- Prints next steps for TLS, Mailcow DNS, and backups.
