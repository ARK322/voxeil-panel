import type {
  V1LimitRange,
  V1NetworkPolicy,
  V1ResourceQuota
} from "@kubernetes/client-node";

type Limits = {
  cpu: number;
  ramGi: number;
  diskGi: number;
};

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

export function renderResourceQuota(
  template: V1ResourceQuota,
  namespace: string,
  limits: Limits
): V1ResourceQuota {
  const quota = clone(template);
  quota.metadata = {
    ...quota.metadata,
    name: template.metadata?.name ?? "site-quota",
    namespace
  };
  quota.spec = quota.spec ?? {};
  quota.spec.hard = {
    ...quota.spec.hard,
    "pods": "1",
    "requests.cpu": String(limits.cpu),
    "requests.memory": `${limits.ramGi}Gi`,
    "persistentvolumeclaims": "1",
    "requests.storage": `${limits.diskGi}Gi`
  };
  return quota;
}

export function renderLimitRange(template: V1LimitRange, namespace: string): V1LimitRange {
  const limitRange = clone(template);
  limitRange.metadata = {
    ...limitRange.metadata,
    name: template.metadata?.name ?? "site-limits",
    namespace
  };
  return limitRange;
}

export function renderNetworkPolicy(
  template: V1NetworkPolicy,
  namespace: string
): V1NetworkPolicy {
  const policy = clone(template);
  policy.metadata = {
    ...policy.metadata,
    name: template.metadata?.name ?? "policy",
    namespace
  };
  return policy;
}
