apiVersion: v1
kind: LimitRange
metadata:
  name: user-limits
  namespace: REPLACE_NAMESPACE
spec:
  limits:
    - type: Container
      default:
        cpu: REPLACE_CPU_LIMIT
        memory: REPLACE_MEMORY_LIMIT
      defaultRequest:
        cpu: REPLACE_CPU_REQUEST
        memory: REPLACE_MEMORY_REQUEST
