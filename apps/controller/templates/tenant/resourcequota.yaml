apiVersion: v1
kind: ResourceQuota
metadata:
  name: site-quota
  # namespace is set by the controller per tenant
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 2Gi
    requests.storage: 1Gi
    limits.cpu: "2"
    limits.memory: 4Gi
    pods: "1"
    services: "5"
    configmaps: "10"
    persistentvolumeclaims: "1"
