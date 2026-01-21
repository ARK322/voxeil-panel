apiVersion: v1
kind: ResourceQuota
metadata:
  name: user-quota
  namespace: REPLACE_NAMESPACE
spec:
  hard:
    requests.cpu: "REPLACE_CPU_REQUEST"
    requests.memory: "REPLACE_MEMORY_REQUEST"
    limits.cpu: "REPLACE_CPU_LIMIT"
    limits.memory: "REPLACE_MEMORY_LIMIT"
    persistentvolumeclaims: "REPLACE_PVC_COUNT"
