apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: REPLACE_FLUX_REPO_NAME
  namespace: REPLACE_TENANT_NAMESPACE
spec:
  interval: 1m0s
  url: REPLACE_GIT_URL
  ref:
    branch: REPLACE_GIT_BRANCH
  secretRef:
    name: REPLACE_FLUX_SECRET_NAME
