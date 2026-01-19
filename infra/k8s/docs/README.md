# Kubernetes Manifests

## Apply Platform Manifests

1) Ensure the platform images are set in the manifests:
   - `infra/k8s/platform/controller-deploy.yaml` -> `REPLACE_CONTROLLER_IMAGE`
   - `infra/k8s/platform/panel-deploy.yaml` -> `REPLACE_PANEL_IMAGE`
2) Create the platform secret in the `platform` namespace (keys: `ADMIN_API_KEY`, `PANEL_ADMIN_PASSWORD`, `SITE_NODEPORT_START`, `SITE_NODEPORT_END`, `MAILCOW_API_URL`, `MAILCOW_API_KEY`).
3) Create the GHCR pull secret in the `platform` namespace (name: `ghcr-pull-secret`).
4) Apply the platform manifests:

```
kubectl apply -f infra/k8s/platform
```

## Shared Service Zones (Optional)

Shared services live in their own namespaces (zones) and can be installed independently:
- Backup runner: `infra/k8s/backup` -> `backup`
- Mailcow: `infra/k8s/mailcow` -> `mail-zone`
- PostgreSQL: planned `db-zone` (manifests TBD)

## Backup Zone (backup)

Apply the backup runner manifests after ensuring the host has `/backups`:

```
sudo mkdir -p /backups/sites
```

Apply order:

```
kubectl apply -f infra/k8s/backup/namespace.yaml
kubectl apply -f infra/k8s/backup/rbac.yaml
kubectl apply -f infra/k8s/backup/backup-runner.yaml
```

### Verify backup runner

```
kubectl -n backup get configmap backup-runner-script
kubectl -n backup get sa backup-runner
```

## Mailcow Zone (mail-zone)

Apply the Mailcow zone manifests after creating required secrets (the installer generates `mailcow-secrets`).
Apply order:

```
kubectl apply -f infra/k8s/mailcow/namespace.yaml
kubectl apply -f infra/k8s/mailcow/mailcow-core.yaml
kubectl apply -f infra/k8s/mailcow/networkpolicy.yaml
```

Mailcow API is internal-only by default. The controller should use:
`http://mailcow-api.mail-zone.svc.cluster.local`.
Mailcow web UI is not exposed by default.

### Optional: Traefik TCP exposure (mail protocols)

Enable SMTP/IMAP/POP3 exposure only after configuring Traefik TCP entrypoints:

```
kubectl apply -f infra/k8s/mailcow/traefik-tcp
```

The manifests create `IngressRouteTCP` resources in `mail-zone` that route TCP
entrypoints to the Mailcow mail services.

TCP entrypoints and ports (Traefik):
- `smtp`: 25
- `smtps`: 465
- `submission`: 587
- `imap`: 143
- `imaps`: 993
- `pop3`: 110 (optional)
- `pop3s`: 995 (optional)

### Verify Mailcow health

```
kubectl -n mail-zone get pods
kubectl -n mail-zone get svc
```

## Apply Tenant Templates

Tenant templates are designed to be applied per tenant namespace.

1) Create a tenant namespace (example):

```
kubectl create namespace tenant-acme
```

2) Apply all tenant templates to that namespace:

```
kubectl -n tenant-acme apply -f infra/k8s/templates/tenant
```
