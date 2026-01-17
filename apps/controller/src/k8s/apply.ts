import type {
  V1LimitRange,
  V1NetworkPolicy,
  V1ResourceQuota
} from "@kubernetes/client-node";
import { getClients } from "./client.js";

async function replaceWithResourceVersion<T extends { metadata?: { resourceVersion?: string } }>(
  next: T,
  read: () => Promise<{ body: T }>,
  replace: (nextWithVersion: T) => Promise<unknown>
): Promise<void> {
  const existing = await read();
  const nextWithVersion = {
    ...next,
    metadata: {
      ...next.metadata,
      resourceVersion: existing.body.metadata?.resourceVersion
    }
  };
  await replace(nextWithVersion);
}

export async function upsertResourceQuota(resourceQuota: V1ResourceQuota): Promise<void> {
  const { core } = getClients();
  const name = resourceQuota.metadata?.name ?? "site-quota";
  const namespace = resourceQuota.metadata?.namespace ?? "default";
  try {
    await core.createNamespacedResourceQuota(namespace, resourceQuota);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
    await replaceWithResourceVersion(
      resourceQuota,
      () => core.readNamespacedResourceQuota(name, namespace),
      (next) => core.replaceNamespacedResourceQuota(name, namespace, next)
    );
  }
}

export async function upsertLimitRange(limitRange: V1LimitRange): Promise<void> {
  const { core } = getClients();
  const name = limitRange.metadata?.name ?? "site-limits";
  const namespace = limitRange.metadata?.namespace ?? "default";
  try {
    await core.createNamespacedLimitRange(namespace, limitRange);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
    await replaceWithResourceVersion(
      limitRange,
      () => core.readNamespacedLimitRange(name, namespace),
      (next) => core.replaceNamespacedLimitRange(name, namespace, next)
    );
  }
}

export async function upsertNetworkPolicy(policy: V1NetworkPolicy): Promise<void> {
  const { net } = getClients();
  const name = policy.metadata?.name ?? "policy";
  const namespace = policy.metadata?.namespace ?? "default";
  try {
    await net.createNamespacedNetworkPolicy(namespace, policy);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
    await replaceWithResourceVersion(
      policy,
      () => net.readNamespacedNetworkPolicy(name, namespace),
      (next) => net.replaceNamespacedNetworkPolicy(name, namespace, next)
    );
  }
}
