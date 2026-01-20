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

const FIELD_MANAGER = "voxeil-controller";
const APPLY_OPTIONS = { headers: { "Content-Type": "application/apply-patch+yaml" } };

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
