import { getClients } from "./client.js";
import { HttpError } from "../http/errors.js";

export const USER_PREFIX = "user-";

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
