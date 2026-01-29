import { deleteUserNamespace } from "../k8s/namespace.js";
import { logger } from "../config/logger.js";
import { loadUserTemplates } from "../templates/load.js";
import {
    renderUserNamespace,
    renderUserResourceQuota,
    renderUserLimitRange,
    renderUserNetworkPolicy,
    renderUserControllerRoleBinding,
    renderUserServiceAccount,
    renderUserRole,
    renderUserRoleBinding
} from "../templates/render.js";
import { getClients, LABELS } from "../k8s/client.js";
import { HttpError } from "../http/errors.js";
import { ensureUserHomePvc } from "../k8s/pvc.js";
import { ensureDatabase, ensureRole, generateDbPassword, normalizeDbName, normalizeDbUser } from "../postgres/admin.js";
import { upsertSecret } from "../k8s/apply.js";

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
        } else if (kind === "ServiceAccount") {
            const patch = core.patchNamespacedServiceAccount;
            await patch(name, namespace, resource, undefined, undefined, FIELD_MANAGER, undefined, true, APPLY_OPTIONS);
        } else if (kind === "Role") {
            const patch = rbac.patchNamespacedRole;
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
            } else if (kind === "ServiceAccount") {
                await core.createNamespacedServiceAccount(namespace, resource);
            } else if (kind === "Role") {
                await rbac.createNamespacedRole(namespace, resource);
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

        const networkPolicy = renderUserNetworkPolicy(templates.networkPolicyBase, namespace);
        await applyResource(networkPolicy);

        const networkPolicyAllowIngress = renderUserNetworkPolicy(templates.networkPolicyAllowIngress, namespace);
        await applyResource(networkPolicyAllowIngress);

        const networkPolicyAllowEgress = renderUserNetworkPolicy(templates.networkPolicyAllowEgress, namespace);
        await applyResource(networkPolicyAllowEgress);

        const roleBinding = renderUserControllerRoleBinding(templates.controllerRoleBinding, namespace);
        await applyResource(roleBinding);

        // Create user home PVC
        await ensureUserHomePvc(namespace);

        // Create user database and role
        const dbNamePrefix = process.env.DB_NAME_PREFIX?.trim() || "db_";
        const dbUserPrefix = process.env.DB_USER_PREFIX?.trim() || "u_";
        const dbName = normalizeDbName(`${dbNamePrefix}${userId}`);
        const dbUser = normalizeDbUser(`${dbUserPrefix}${userId}`);
        const dbPassword = generateDbPassword();
        
        await ensureRole(dbUser, dbPassword);
        await ensureDatabase(dbName, dbUser);
        
        // Get DB connection config
        const dbHost = process.env.POSTGRES_HOST?.trim() ?? process.env.DB_HOST?.trim();
        const dbPort = process.env.POSTGRES_PORT?.trim() ?? process.env.DB_PORT?.trim() ?? "5432";
        if (!dbHost) {
            throw new HttpError(500, "POSTGRES_HOST must be configured for DB secret creation.");
        }
        
        // Create DB secret in user namespace
        const dbSecretName = "db-conn";
        const encodedUser = encodeURIComponent(dbUser);
        const encodedPassword = encodeURIComponent(dbPassword);
        const databaseUrl = `postgres://${encodedUser}:${encodedPassword}@${dbHost}:${dbPort}/${dbName}`;
        
        await upsertSecret({
            apiVersion: "v1",
            kind: "Secret",
            metadata: {
                name: dbSecretName,
                namespace,
                labels: {
                    [LABELS.managedBy]: LABELS.managedBy,
                    "voxeil.io/secret-type": "db-connection"
                }
            },
            type: "Opaque",
            stringData: {
                host: dbHost,
                port: dbPort,
                database: dbName,
                username: dbUser,
                password: dbPassword,
                url: databaseUrl
            }
        });

        return { success: true };
    } catch (error) {
        if (namespaceCreated) {
            try {
                await deleteUserNamespace(userId);
            } catch (cleanupError) {
                logger.error({ err: cleanupError }, "Failed to cleanup namespace after bootstrap error");
            }
        }
        throw new HttpError(500, `Failed to bootstrap user namespace: ${error?.message ?? String(error)}`);
    }
}
