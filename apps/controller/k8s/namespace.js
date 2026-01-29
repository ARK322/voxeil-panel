import { getClients, LABELS } from "./client.js";
import { HttpError } from "../http/errors.js";
import { loadTenantTemplates } from "../templates/load.js";
import { renderNetworkPolicy } from "../templates/render.js";
import { upsertResourceQuota, upsertLimitRange, upsertNetworkPolicy } from "./apply.js";

export const USER_PREFIX = "user-";
export const TENANT_PREFIX = "tenant-";

/**
 * Wait for namespace to be deleted (with timeout).
 * @param {string} namespace - Namespace name
 * @param {number} timeoutMs - Timeout in milliseconds (default: 60000)
 * @returns {Promise<void>}
 */
async function waitNamespaceDeleted(namespace, timeoutMs = 60000) {
    const { core } = getClients();
    const startTime = Date.now();
    const pollInterval = 2000; // 2 seconds
    
    while (Date.now() - startTime < timeoutMs) {
        try {
            await core.readNamespace(namespace);
            // Namespace still exists, wait and retry
            await new Promise(resolve => setTimeout(resolve, pollInterval));
        } catch (error) {
            if (error?.response?.statusCode === 404) {
                // Namespace deleted
                return;
            }
            // Other error, throw it
            throw error;
        }
    }
    
    // Timeout reached, namespace still exists
    throw new HttpError(500, `Namespace ${namespace} still exists after ${timeoutMs}ms timeout`);
}

export async function requireNamespace(namespace) {
    const { core } = getClients();
    try {
        await core.readNamespace(namespace);
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            throw new HttpError(404, "Namespace not found.");
        }
        throw error;
    }
}

export async function deleteNamespace(namespace) {
    const { core } = getClients();
    try {
        await core.deleteNamespace(namespace);
        // Wait for namespace deletion to complete
        await waitNamespaceDeleted(namespace, 60000); // 60 second timeout
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            throw new HttpError(404, "Namespace not found.");
        }
        throw error;
    }
}

export async function patchNamespaceAnnotations(namespace, annotations) {
    const { core } = getClients();
    const patch = core.patchNamespace;
    try {
        await patch(namespace, { metadata: { annotations } }, undefined, undefined, undefined, undefined, { headers: { "Content-Type": "application/merge-patch+json" } });
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            throw new HttpError(404, "Namespace not found.");
        }
        throw error;
    }
}

export async function deleteUserNamespace(userId) {
    const { core } = getClients();
    const namespace = `${USER_PREFIX}${userId}`;
    try {
        await core.deleteNamespace(namespace);
        // Wait for namespace deletion to complete (ignore timeout errors for user namespaces)
        try {
            await waitNamespaceDeleted(namespace, 60000); // 60 second timeout
        } catch (error) {
            // If timeout, log warning but don't fail (user namespace cleanup is best-effort)
            if (error?.statusCode === 500) {
                // Timeout - namespace may still be deleting, but we'll continue
                // The uninstall phase will handle stuck namespaces
            } else {
                throw error;
            }
        }
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            return;
        }
        throw error;
    }
}

export async function allocateTenantNamespace(slug, annotations = {}) {
    const { core } = getClients();
    const namespace = `${TENANT_PREFIX}${slug}`;
    
    const namespaceBody = {
        apiVersion: "v1",
        kind: "Namespace",
        metadata: {
            name: namespace,
            labels: {
                [LABELS.managedBy]: LABELS.managedBy,
                "voxeil.io/tenant": "true",
                "voxeil.io/tenant-slug": slug
            },
            annotations: annotations || {}
        }
    };
    
    const isNewNamespace = await (async () => {
        try {
            await core.readNamespace(namespace);
            // Namespace exists, patch annotations if needed
            if (annotations && Object.keys(annotations).length > 0) {
                await patchNamespaceAnnotations(namespace, annotations);
            }
            return false;
        }
        catch (error) {
            if (error?.response?.statusCode === 404) {
                // Create namespace
                await core.createNamespace(namespaceBody);
                return true;
            }
            else {
                throw error;
            }
        }
    })();
    
    // Apply tenant templates (limitrange, resourcequota, networkpolicies)
    if (isNewNamespace) {
        const templates = await loadTenantTemplates();
        
        // Apply ResourceQuota
        const resourceQuota = templates.resourceQuota;
        resourceQuota.metadata = {
            ...resourceQuota.metadata,
            name: resourceQuota.metadata?.name ?? "site-quota",
            namespace
        };
        await upsertResourceQuota(resourceQuota);
        
        // Apply LimitRange
        const limitRange = templates.limitRange;
        limitRange.metadata = {
            ...limitRange.metadata,
            name: limitRange.metadata?.name ?? "site-limits",
            namespace
        };
        await upsertLimitRange(limitRange);
        
        // Apply NetworkPolicies
        const denyAllPolicy = renderNetworkPolicy(templates.networkPolicyDenyAll, namespace);
        await upsertNetworkPolicy(denyAllPolicy);
        
        const allowIngressPolicy = renderNetworkPolicy(templates.networkPolicyAllowIngress, namespace);
        await upsertNetworkPolicy(allowIngressPolicy);
        
        const allowEgressPolicy = renderNetworkPolicy(templates.networkPolicyAllowEgress, namespace);
        await upsertNetworkPolicy(allowEgressPolicy);
    }
    
    return { slug, namespace };
}

export async function deleteTenantNamespace(slug) {
    const { core } = getClients();
    const namespace = `${TENANT_PREFIX}${slug}`;
    try {
        await core.deleteNamespace(namespace);
        // Wait for namespace deletion to complete (ignore timeout errors for tenant namespaces)
        try {
            await waitNamespaceDeleted(namespace, 60000); // 60 second timeout
        } catch (error) {
            // If timeout, log warning but don't fail (tenant namespace cleanup is best-effort)
            if (error?.statusCode === 500) {
                // Timeout - namespace may still be deleting, but we'll continue
                // The uninstall phase will handle stuck namespaces
            } else {
                throw error;
            }
        }
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            return;
        }
        throw error;
    }
}

export async function listTenantNamespaces() {
    const { core } = getClients();
    const response = await core.listNamespace();
    const tenantNamespaces = (response.body.items || [])
        .filter(ns => ns.metadata?.name?.startsWith(TENANT_PREFIX))
        .map(ns => ({
            name: ns.metadata.name,
            labels: ns.metadata.labels || {},
            annotations: ns.metadata.annotations || {}
        }));
    return tenantNamespaces;
}

export async function readTenantNamespace(slug) {
    const { core } = getClients();
    const namespace = `${TENANT_PREFIX}${slug}`;
    try {
        const response = await core.readNamespace(namespace);
        return {
            name: response.body.metadata.name,
            labels: response.body.metadata.labels || {},
            annotations: response.body.metadata.annotations || {}
        };
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            throw new HttpError(404, "Tenant namespace not found.");
        }
        throw error;
    }
}

export function slugFromNamespace(namespace) {
    if (!namespace || typeof namespace !== "string") {
        throw new HttpError(400, "Invalid namespace.");
    }
    if (!namespace.startsWith(TENANT_PREFIX)) {
        throw new HttpError(400, "Namespace is not a tenant namespace.");
    }
    return namespace.slice(TENANT_PREFIX.length);
}

export async function findUserNamespaceBySiteSlug(slug) {
    const { core } = getClients();
    const response = await core.listNamespace();
    const userNamespaces = (response.body.items || [])
        .filter(ns => ns.metadata?.name?.startsWith(USER_PREFIX));
    
    for (const ns of userNamespaces) {
        const annotations = ns.metadata?.annotations || {};
        // Check if this namespace has a site with the given slug
        const siteDomainKey = `voxeil.io/site-${slug}-domain`;
        if (annotations[siteDomainKey]) {
            return ns.metadata.name;
        }
    }
    
    throw new HttpError(404, `Site with slug '${slug}' not found in any user namespace.`);
}

export async function readUserNamespaceSite(userNamespace, slug) {
    const { core } = getClients();
    try {
        const response = await core.readNamespace(userNamespace);
        const annotations = response.body.metadata.annotations || {};
        const siteDomainKey = `voxeil.io/site-${slug}-domain`;
        if (!annotations[siteDomainKey]) {
            throw new HttpError(404, `Site with slug '${slug}' not found in namespace '${userNamespace}'.`);
        }
        // Extract site data from annotations
        const siteData = {};
        for (const [key, value] of Object.entries(annotations)) {
            if (key.startsWith(`voxeil.io/site-${slug}-`)) {
                const propName = key.slice(`voxeil.io/site-${slug}-`.length);
                siteData[propName] = value;
            }
        }
        return {
            namespace: userNamespace,
            slug,
            annotations: siteData
        };
    } catch (error) {
        if (error?.response?.statusCode === 404) {
            throw new HttpError(404, `User namespace '${userNamespace}' not found.`);
        }
        throw error;
    }
}

/**
 * Resolve user namespace for a site by slug.
 * This is the single source of truth for namespace resolution.
 */
export async function resolveUserNamespaceForSite(slug) {
    return await findUserNamespaceBySiteSlug(slug);
}

/**
 * Extract userId from user namespace name.
 * @param {string} namespace - User namespace name (e.g., "user-123")
 * @returns {string} - User ID (e.g., "123")
 */
export function extractUserIdFromNamespace(namespace) {
    if (!namespace || typeof namespace !== "string") {
        throw new HttpError(400, "Invalid namespace.");
    }
    if (!namespace.startsWith(USER_PREFIX)) {
        throw new HttpError(400, "Namespace is not a user namespace.");
    }
    return namespace.slice(USER_PREFIX.length);
}

/**
 * Read site metadata from user namespace (replaces readTenantNamespace).
 * Returns format compatible with old readTenantNamespace for easier migration.
 */
export async function readSiteMetadata(slug) {
    const namespace = await resolveUserNamespaceForSite(slug);
    const siteData = await readUserNamespaceSite(namespace, slug);
    // Return in format compatible with old readTenantNamespace
    return {
        name: siteData.namespace,
        labels: {}, // User namespace labels if needed
        annotations: siteData.annotations
    };
}
