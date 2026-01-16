## Voxeil Panel (MVP)

Self-hosted, Kubernetes-native hosting control panel. API-first with a minimal UI shipped in this repo.

### Components
- `apps/controller`: Fastify API that owns all Kubernetes access (namespaces, deployments, services, quotas, network policies).
- `apps/panel`: Next.js UI that talks only to the controller service inside the cluster.
- `infra/k8s/platform`: k3s-compatible manifests with placeholders (`REPLACE_*`) for images and NodePorts.
- `infra/k8s/templates/tenant`: Baseline ResourceQuota, LimitRange, and default-deny NetworkPolicy used for every tenant namespace.

### Install (domainless MVP)
1) Build/push your own images (no hardcoded registry):
   - Controller: `apps/controller`
   - Panel: `apps/panel`
2) From the repo root run:
   ```bash
   chmod +x installer/installer.sh
   installer/installer.sh
   ```
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

### Security baseline
- Controller enforces `X-API-Key` on all routes except `/health`.
- Panel never talks directly to the Kubernetes API; it proxies via the controller service.
- Tenants get a dedicated namespace with ResourceQuota, LimitRange, and default-deny NetworkPolicy (DNS egress only).
- No domains or registry paths are hardcoded; everything is provided at install time.

### Future TODOs
- Add HTTPS/ingress once domain support is enabled.
- Extend quota/limit presets per plan.
- Add per-tenant API keys and audit logging.