apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-ingress
  # namespace is set by the controller per tenant
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - {} # allow all ingress (NodePort traffic hits pods)
