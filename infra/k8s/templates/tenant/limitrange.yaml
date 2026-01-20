apiVersion: v1
kind: LimitRange
metadata:
  name: site-limits
  # namespace is set by the controller per tenant
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 1Gi
      defaultRequest:
        cpu: 100m
        memory: 512Mi
      max:
        cpu: 1000m
        memory: 4Gi
      min:
        cpu: "0"
        memory: 256Mi
