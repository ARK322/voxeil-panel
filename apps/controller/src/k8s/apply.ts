import type {
  V1Deployment,
  V1Ingress,
  V1LimitRange,
  V1NetworkPolicy,
  V1ResourceQuota,
  V1Secret,
  V1Service
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

export async function upsertDeployment(deployment: V1Deployment): Promise<void> {
  const { apps } = getClients();
  const name = deployment.metadata?.name ?? "app";
  const namespace = deployment.metadata?.namespace ?? "default";
  try {
    await apps.createNamespacedDeployment(namespace, deployment);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
    await replaceWithResourceVersion(
      deployment,
      () => apps.readNamespacedDeployment(name, namespace),
      (next) => apps.replaceNamespacedDeployment(name, namespace, next)
    );
  }
}

export async function upsertService(service: V1Service): Promise<void> {
  const { core } = getClients();
  const name = service.metadata?.name ?? "web";
  const namespace = service.metadata?.namespace ?? "default";
  try {
    await core.createNamespacedService(namespace, service);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
    await replaceWithResourceVersion(
      service,
      () => core.readNamespacedService(name, namespace),
      (next) => core.replaceNamespacedService(name, namespace, next)
    );
  }
}

export async function upsertIngress(ingress: V1Ingress): Promise<void> {
  const { net } = getClients();
  const name = ingress.metadata?.name ?? "web";
  const namespace = ingress.metadata?.namespace ?? "default";
  try {
    await net.createNamespacedIngress(namespace, ingress);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
    await replaceWithResourceVersion(
      ingress,
      () => net.readNamespacedIngress(name, namespace),
      (next) => net.replaceNamespacedIngress(name, namespace, next)
    );
  }
}

export async function upsertSecret(secret: V1Secret): Promise<void> {
  const { core } = getClients();
  const name = secret.metadata?.name ?? "secret";
  const namespace = secret.metadata?.namespace ?? "default";
  try {
    await core.createNamespacedSecret(namespace, secret);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
    await replaceWithResourceVersion(
      secret,
      () => core.readNamespacedSecret(name, namespace),
      (next) => core.replaceNamespacedSecret(name, namespace, next)
    );
  }
}
