apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: controller-access
  namespace: REPLACE_NAMESPACE
subjects:
  - kind: ServiceAccount
    name: controller
    namespace: platform
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
