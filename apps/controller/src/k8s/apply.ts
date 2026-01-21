import type {
  V1Deployment,
  V1Ingress,
  V1LimitRange,
  V1Namespace,
  V1NetworkPolicy,
  V1ResourceQuota,
  V1RoleBinding,
  V1Secret,
  V1Service
} from "@kubernetes/client-node";
import { getClients } from "./client.js";

const FIELD_MANAGER = "voxeil-controller";
const APPLY_OPTIONS = { headers: { "Content-Type": "application/apply-patch+yaml" } };

/**
 * Generic function to apply any K8s resource using Server-Side Apply
 * This is idempotent and handles all resource types
 */
export async function applyTemplate<T = unknown>(
  resource: T,
  resourceKind: string,
  namespace?: string
): Promise<void> {
  const resourceObj = resource as { metadata?: { name?: string; namespace?: string } };
  const name = resourceObj.metadata?.name;
  if (!name) {
    throw new Error(`Resource name is required for ${resourceKind}`);
  }

  const targetNamespace = namespace || resourceObj.metadata?.namespace || "default";
  const { core, apps, net, rbac } = getClients();

  try {
    switch (resourceKind.toLowerCase()) {
      case "namespace": {
        const ns = resource as V1Namespace;
        const patch = core.patchNamespace as unknown as (
          name: string,
          body: unknown,
          pretty?: string,
          dryRun?: string,
          fieldManager?: string,
          fieldValidation?: string,
          options?: { headers: { "Content-Type": string } }
        ) => Promise<unknown>;
        await patch(name, ns, undefined, undefined, FIELD_MANAGER, undefined, APPLY_OPTIONS);
        break;
      }

      case "resourcequota": {
        const quota = resource as V1ResourceQuota;
        const patch = core.patchNamespacedResourceQuota as unknown as (
          name: string,
          namespace: string,
          body: unknown,
          pretty?: string,
          dryRun?: string,
          fieldManager?: string,
          fieldValidation?: string,
          force?: boolean,
          options?: { headers: { "Content-Type": string } }
        ) => Promise<unknown>;
        await patch(name, targetNamespace, quota, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        break;
      }

      case "limitrange": {
        const limitRange = resource as V1LimitRange;
        const patch = core.patchNamespacedLimitRange as unknown as (
          name: string,
          namespace: string,
          body: unknown,
          pretty?: string,
          dryRun?: string,
          fieldManager?: string,
          fieldValidation?: string,
          force?: boolean,
          options?: { headers: { "Content-Type": string } }
        ) => Promise<unknown>;
        await patch(name, targetNamespace, limitRange, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        break;
      }

      case "networkpolicy": {
        const policy = resource as V1NetworkPolicy;
        const patch = net.patchNamespacedNetworkPolicy as unknown as (
          name: string,
          namespace: string,
          body: unknown,
          pretty?: string,
          dryRun?: string,
          fieldManager?: string,
          fieldValidation?: string,
          force?: boolean,
          options?: { headers: { "Content-Type": string } }
        ) => Promise<unknown>;
        await patch(name, targetNamespace, policy, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        break;
      }

      case "rolebinding": {
        const binding = resource as V1RoleBinding;
        const patch = rbac.patchNamespacedRoleBinding as unknown as (
          name: string,
          namespace: string,
          body: unknown,
          pretty?: string,
          dryRun?: string,
          fieldManager?: string,
          fieldValidation?: string,
          force?: boolean,
          options?: { headers: { "Content-Type": string } }
        ) => Promise<unknown>;
        await patch(name, targetNamespace, binding, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        break;
      }

      case "deployment": {
        const deployment = resource as V1Deployment;
        const patch = apps.patchNamespacedDeployment as unknown as (
          name: string,
          namespace: string,
          body: unknown,
          pretty?: string,
          dryRun?: string,
          fieldManager?: string,
          fieldValidation?: string,
          force?: boolean,
          options?: { headers: { "Content-Type": string } }
        ) => Promise<unknown>;
        await patch(name, targetNamespace, deployment, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        break;
      }

      case "service": {
        const service = resource as V1Service;
        const patch = core.patchNamespacedService as unknown as (
          name: string,
          namespace: string,
          body: unknown,
          pretty?: string,
          dryRun?: string,
          fieldManager?: string,
          fieldValidation?: string,
          force?: boolean,
          options?: { headers: { "Content-Type": string } }
        ) => Promise<unknown>;
        await patch(name, targetNamespace, service, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        break;
      }

      case "ingress": {
        const ingress = resource as V1Ingress;
        const patch = net.patchNamespacedIngress as unknown as (
          name: string,
          namespace: string,
          body: unknown,
          pretty?: string,
          dryRun?: string,
          fieldManager?: string,
          fieldValidation?: string,
          force?: boolean,
          options?: { headers: { "Content-Type": string } }
        ) => Promise<unknown>;
        await patch(name, targetNamespace, ingress, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        break;
      }

      case "secret": {
        const secret = resource as V1Secret;
        const patch = core.patchNamespacedSecret as unknown as (
          name: string,
          namespace: string,
          body: unknown,
          pretty?: string,
          dryRun?: string,
          fieldManager?: string,
          fieldValidation?: string,
          force?: boolean,
          options?: { headers: { "Content-Type": string } }
        ) => Promise<unknown>;
        await patch(name, targetNamespace, secret, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        break;
      }

      default:
        throw new Error(`Unsupported resource kind: ${resourceKind}`);
    }
  } catch (error: any) {
    // If resource doesn't exist, try to create it
    if (error?.response?.statusCode === 404) {
      switch (resourceKind.toLowerCase()) {
        case "namespace": {
          const ns = resource as V1Namespace;
          // Ensure metadata.name is set
          if (!ns.metadata?.name) {
            throw new Error("Namespace name is required");
          }
          await core.createNamespace(ns);
          break;
        }
        case "resourcequota": {
          const quota = resource as V1ResourceQuota;
          await core.createNamespacedResourceQuota(targetNamespace, quota);
          break;
        }
        case "limitrange": {
          const limitRange = resource as V1LimitRange;
          await core.createNamespacedLimitRange(targetNamespace, limitRange);
          break;
        }
        case "networkpolicy": {
          const policy = resource as V1NetworkPolicy;
          await net.createNamespacedNetworkPolicy(targetNamespace, policy);
          break;
        }
        case "rolebinding": {
          const binding = resource as V1RoleBinding;
          await rbac.createNamespacedRoleBinding(targetNamespace, binding);
          break;
        }
        default:
          throw new Error(`Cannot create resource of kind: ${resourceKind}. Use applyTemplate for supported types.`);
      }
    } else {
      throw error;
    }
  }
}

export async function upsertResourceQuota(resourceQuota: V1ResourceQuota): Promise<void> {
  const { core } = getClients();
  const name = resourceQuota.metadata?.name ?? "site-quota";
  const namespace = resourceQuota.metadata?.namespace ?? "default";
  const patch = core.patchNamespacedResourceQuota as unknown as (
    name: string,
    namespace: string,
    body: unknown,
    pretty?: string,
    dryRun?: string,
    fieldManager?: string,
    fieldValidation?: string,
    force?: boolean,
    options?: { headers: { "Content-Type": string } }
  ) => Promise<unknown>;
  await patch(
    name,
    namespace,
    resourceQuota,
    undefined,
    undefined,
    FIELD_MANAGER,
    undefined,
    true,
    APPLY_OPTIONS
  );
}

export async function upsertLimitRange(limitRange: V1LimitRange): Promise<void> {
  const { core } = getClients();
  const name = limitRange.metadata?.name ?? "site-limits";
  const namespace = limitRange.metadata?.namespace ?? "default";
  const patch = core.patchNamespacedLimitRange as unknown as (
    name: string,
    namespace: string,
    body: unknown,
    pretty?: string,
    dryRun?: string,
    fieldManager?: string,
    fieldValidation?: string,
    force?: boolean,
    options?: { headers: { "Content-Type": string } }
  ) => Promise<unknown>;
  await patch(
    name,
    namespace,
    limitRange,
    undefined,
    undefined,
    FIELD_MANAGER,
    undefined,
    true,
    APPLY_OPTIONS
  );
}

export async function upsertNetworkPolicy(policy: V1NetworkPolicy): Promise<void> {
  const { net } = getClients();
  const name = policy.metadata?.name ?? "policy";
  const namespace = policy.metadata?.namespace ?? "default";
  const patch = net.patchNamespacedNetworkPolicy as unknown as (
    name: string,
    namespace: string,
    body: unknown,
    pretty?: string,
    dryRun?: string,
    fieldManager?: string,
    fieldValidation?: string,
    force?: boolean,
    options?: { headers: { "Content-Type": string } }
  ) => Promise<unknown>;
  await patch(
    name,
    namespace,
    policy,
    undefined,
    undefined,
    FIELD_MANAGER,
    undefined,
    true,
    APPLY_OPTIONS
  );
}

export async function upsertDeployment(deployment: V1Deployment): Promise<void> {
  const { apps } = getClients();
  const name = deployment.metadata?.name ?? "app";
  const namespace = deployment.metadata?.namespace ?? "default";
  const patch = apps.patchNamespacedDeployment as unknown as (
    name: string,
    namespace: string,
    body: unknown,
    pretty?: string,
    dryRun?: string,
    fieldManager?: string,
    fieldValidation?: string,
    force?: boolean,
    options?: { headers: { "Content-Type": string } }
  ) => Promise<unknown>;
  await patch(
    name,
    namespace,
    deployment,
    undefined,
    undefined,
    FIELD_MANAGER,
    undefined,
    true,
    APPLY_OPTIONS
  );
}

export async function upsertService(service: V1Service): Promise<void> {
  const { core } = getClients();
  const name = service.metadata?.name ?? "web";
  const namespace = service.metadata?.namespace ?? "default";
  const patch = core.patchNamespacedService as unknown as (
    name: string,
    namespace: string,
    body: unknown,
    pretty?: string,
    dryRun?: string,
    fieldManager?: string,
    fieldValidation?: string,
    force?: boolean,
    options?: { headers: { "Content-Type": string } }
  ) => Promise<unknown>;
  await patch(
    name,
    namespace,
    service,
    undefined,
    undefined,
    FIELD_MANAGER,
    undefined,
    true,
    APPLY_OPTIONS
  );
}

export async function upsertIngress(ingress: V1Ingress): Promise<void> {
  const { net } = getClients();
  const name = ingress.metadata?.name ?? "web";
  const namespace = ingress.metadata?.namespace ?? "default";
  const patch = net.patchNamespacedIngress as unknown as (
    name: string,
    namespace: string,
    body: unknown,
    pretty?: string,
    dryRun?: string,
    fieldManager?: string,
    fieldValidation?: string,
    force?: boolean,
    options?: { headers: { "Content-Type": string } }
  ) => Promise<unknown>;
  await patch(
    name,
    namespace,
    ingress,
    undefined,
    undefined,
    FIELD_MANAGER,
    undefined,
    true,
    APPLY_OPTIONS
  );
}

export async function upsertSecret(secret: V1Secret): Promise<void> {
  const { core } = getClients();
  const name = secret.metadata?.name ?? "secret";
  const namespace = secret.metadata?.namespace ?? "default";
  const patch = core.patchNamespacedSecret as unknown as (
    name: string,
    namespace: string,
    body: unknown,
    pretty?: string,
    dryRun?: string,
    fieldManager?: string,
    fieldValidation?: string,
    force?: boolean,
    options?: { headers: { "Content-Type": string } }
  ) => Promise<unknown>;
  await patch(
    name,
    namespace,
    secret,
    undefined,
    undefined,
    FIELD_MANAGER,
    undefined,
    true,
    APPLY_OPTIONS
  );
}
