import { getClients, LABELS } from "./client.js";
import { HttpError } from "../http/errors.js";

export const USER_PREFIX = "user-";
export const TENANT_PREFIX = "tenant-";

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
    
    try {
        await core.readNamespace(namespace);
        // Namespace exists, patch annotations if needed
        if (annotations && Object.keys(annotations).length > 0) {
            await patchNamespaceAnnotations(namespace, annotations);
        }
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            // Create namespace
            await core.createNamespace(namespaceBody);
        }
        else {
            throw error;
        }
    }
    
    return { slug, namespace };
}

export async function deleteTenantNamespace(slug) {
    const { core } = getClients();
    const namespace = `${TENANT_PREFIX}${slug}`;
    try {
        await core.deleteNamespace(namespace);
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
