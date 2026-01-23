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
