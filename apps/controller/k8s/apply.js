import { getClients } from "./client.js";
const FIELD_MANAGER = "voxeil-controller";
const APPLY_OPTIONS = { headers: { "Content-Type": "application/apply-patch+yaml" } };
export async function upsertResourceQuota(resourceQuota) {
    const { core } = getClients();
    const name = resourceQuota.metadata?.name ?? "site-quota";
    const namespace = resourceQuota.metadata?.namespace ?? "default";
    const patch = core.patchNamespacedResourceQuota;
    await patch(name, namespace, resourceQuota, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
}
export async function upsertLimitRange(limitRange) {
    const { core } = getClients();
    const name = limitRange.metadata?.name ?? "site-limits";
    const namespace = limitRange.metadata?.namespace ?? "default";
    const patch = core.patchNamespacedLimitRange;
    await patch(name, namespace, limitRange, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
}
export async function upsertNetworkPolicy(policy) {
    const { net } = getClients();
    const name = policy.metadata?.name ?? "policy";
    const namespace = policy.metadata?.namespace ?? "default";
    const patch = net.patchNamespacedNetworkPolicy;
    await patch(name, namespace, policy, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
}
export async function upsertDeployment(deployment) {
    const { apps } = getClients();
    const name = deployment.metadata?.name ?? "app";
    const namespace = deployment.metadata?.namespace ?? "default";
    const patch = apps.patchNamespacedDeployment;
    await patch(name, namespace, deployment, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
}
export async function upsertService(service) {
    const { core } = getClients();
    const name = service.metadata?.name ?? "web";
    const namespace = service.metadata?.namespace ?? "default";
    const patch = core.patchNamespacedService;
    await patch(name, namespace, service, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
}
export async function upsertIngress(ingress) {
    const { net } = getClients();
    const name = ingress.metadata?.name ?? "web";
    const namespace = ingress.metadata?.namespace ?? "default";
    const patch = net.patchNamespacedIngress;
    await patch(name, namespace, ingress, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
}
export async function upsertSecret(secret) {
    const { core } = getClients();
    const name = secret.metadata?.name ?? "secret";
    const namespace = secret.metadata?.namespace ?? "default";
    const patch = core.patchNamespacedSecret;
    await patch(name, namespace, secret, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
}
