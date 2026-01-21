apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: REPLACE_FLUX_KUSTOMIZATION_NAME
  namespace: REPLACE_TENANT_NAMESPACE
spec:
  interval: 5m0s
  path: REPLACE_KUSTOMIZE_PATH
  prune: true
  sourceRef:
    kind: GitRepository
    name: REPLACE_FLUX_REPO_NAME
  targetNamespace: REPLACE_TENANT_NAMESPACE
