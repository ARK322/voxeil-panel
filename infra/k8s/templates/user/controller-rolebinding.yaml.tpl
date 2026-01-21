apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: controller-user-operator
  namespace: REPLACE_TENANT_NAMESPACE
subjects:
  - kind: ServiceAccount
    name: controller-sa
    namespace: platform
roleRef:
  kind: ClusterRole
  name: user-operator
  apiGroup: rbac.authorization.k8s.io
