import { deleteUserNamespace } from "../k8s/namespace.js";
import { loadUserTemplates } from "../templates/load.js";
import {
    renderUserNamespace,
    renderUserResourceQuota,
    renderUserLimitRange,
    renderUserNetworkPolicy,
    renderUserControllerRoleBinding
} from "../templates/render.js";
import { getClients } from "../k8s/client.js";
import { HttpError } from "../http/errors.js";

const FIELD_MANAGER = "voxeil-controller";
const APPLY_OPTIONS = { headers: { "Content-Type": "application/apply-patch+json" } };

const DEFAULT_CPU_REQUEST = "500m";
const DEFAULT_CPU_LIMIT = "1";
const DEFAULT_MEMORY_REQUEST = "512Mi";
const DEFAULT_MEMORY_LIMIT = "1Gi";
const DEFAULT_PVC_COUNT = "5";

async function applyResource(resource) {
    const { core, rbac, net } = getClients();
    const kind = resource.kind;
    const name = resource.metadata?.name;
    const namespace = resource.metadata?.namespace;

    if (!name) {
        throw new Error("Resource must have metadata.name");
    }
    if (kind !== "Namespace" && !namespace) {
        throw new Error("Resource must have metadata.namespace");
    }

    try {
        if (kind === "Namespace") {
            const patch = core.patchNamespace;
            try {
                await patch(name, resource, undefined, undefined, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
            } catch (error) {
                if (error?.response?.statusCode === 404) {
                    await core.createNamespace(resource);
                } else {
                    throw error;
                }
            }
        } else if (kind === "ResourceQuota") {
            const patch = core.patchNamespacedResourceQuota;
            await patch(name, namespace, resource, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        } else if (kind === "LimitRange") {
            const patch = core.patchNamespacedLimitRange;
            await patch(name, namespace, resource, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        } else if (kind === "NetworkPolicy") {
            const patch = net.patchNamespacedNetworkPolicy;
            await patch(name, namespace, resource, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        } else if (kind === "RoleBinding") {
            const patch = rbac.patchNamespacedRoleBinding;
            await patch(name, namespace, resource, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        } else {
            throw new Error(`Unsupported resource kind: ${kind}`);
        }
    } catch (error) {
        if (error?.response?.statusCode === 404 && kind !== "Namespace") {
            if (kind === "ResourceQuota") {
                await core.createNamespacedResourceQuota(namespace, resource);
            } else if (kind === "LimitRange") {
                await core.createNamespacedLimitRange(namespace, resource);
            } else if (kind === "NetworkPolicy") {
                await net.createNamespacedNetworkPolicy(namespace, resource);
            } else if (kind === "RoleBinding") {
                await rbac.createNamespacedRoleBinding(namespace, resource);
            }
        } else {
            throw error;
        }
    }
}

export async function bootstrapUserNamespace(userId) {
    const namespace = `user-${userId}`;
    let namespaceCreated = false;

    try {
        const templates = await loadUserTemplates();

        const namespaceResource = renderUserNamespace(
            templates.namespace,
            namespace,
            userId
        );
        await applyResource(namespaceResource);
        namespaceCreated = true;

        const resourceQuota = renderUserResourceQuota(
            templates.resourceQuota,
            namespace,
            DEFAULT_CPU_REQUEST,
            DEFAULT_CPU_LIMIT,
            DEFAULT_MEMORY_REQUEST,
            DEFAULT_MEMORY_LIMIT,
            DEFAULT_PVC_COUNT
        );
        await applyResource(resourceQuota);

        const limitRange = renderUserLimitRange(
            templates.limitRange,
            namespace,
            DEFAULT_CPU_REQUEST,
            DEFAULT_CPU_LIMIT,
            DEFAULT_MEMORY_REQUEST,
            DEFAULT_MEMORY_LIMIT
        );
        await applyResource(limitRange);

        const networkPolicy = renderUserNetworkPolicy(templates.networkPolicyDenyAll, namespace);
        await applyResource(networkPolicy);

        const roleBinding = renderUserControllerRoleBinding(templates.controllerRoleBinding, namespace);
        await applyResource(roleBinding);

        return { success: true };
    } catch (error) {
        if (namespaceCreated) {
            try {
                await deleteUserNamespace(userId);
            } catch (cleanupError) {
                console.error("Failed to cleanup namespace after bootstrap error:", cleanupError);
            }
        }
        throw new HttpError(500, `Failed to bootstrap user namespace: ${error?.message ?? String(error)}`);
    }
}
