apiVersion: v1
kind: Secret
metadata:
  name: REPLACE_FLUX_SECRET_NAME
  namespace: REPLACE_TENANT_NAMESPACE
type: kubernetes.io/ssh-auth
stringData:
  ssh-privatekey: REPLACE_FLUX_SSH_PRIVATE_KEY
  known_hosts: REPLACE_FLUX_KNOWN_HOSTS
