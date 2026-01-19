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
- Backup runner: `infra/k8s/backup` -> `backup-zone`
- Mailcow: planned `mail-zone` (manifests TBD)
- PostgreSQL: planned `db-zone` (manifests TBD)

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
