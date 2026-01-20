# INGRESS_UNIFICATION

## Status
`buildIngress()` is already centralized in `apps/controller/src/k8s/publish.ts`. No duplicate ingress builders exist elsewhere.

## Expected behavior (verified)
- TLS disabled:
  - `traefik.ingress.kubernetes.io/router.entrypoints: web`
  - `traefik.ingress.kubernetes.io/router.tls: "false"`
  - No cert-manager annotation
  - No `spec.tls` block
- TLS enabled:
  - `traefik.ingress.kubernetes.io/router.entrypoints: websecure`
  - `traefik.ingress.kubernetes.io/router.tls: "true"`
  - `cert-manager.io/cluster-issuer: <issuer>`
  - `spec.tls` with `secretName: tls-<slug>` and host list

## Notes
`PATCH /sites/:slug/tls` uses `patchIngress` with the same annotation set, so Phase2 (default HTTP) and Phase3 (TLS) behavior remains consistent.
