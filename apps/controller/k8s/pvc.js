import { getClients } from "./client.js";
import { parseGiToNumber } from "./quantity.js";
import { HttpError } from "../http/errors.js";
export const TENANT_PVC_NAME = "site-data";
export const USER_HOME_PVC_NAME = "pvc-user-home";
const DEFAULT_STORAGE_CLASS = process.env.STORAGE_CLASS_NAME ?? "local-path";
const DEFAULT_USER_HOME_SIZE_GI = 10; // Default 10Gi for user home
export async function ensurePvc(namespace, sizeGi) {
    const { core } = getClients();
    try {
        await core.createNamespacedPersistentVolumeClaim(namespace, {
            metadata: { name: TENANT_PVC_NAME },
            spec: {
                accessModes: ["ReadWriteOnce"],
                storageClassName: DEFAULT_STORAGE_CLASS,
                resources: {
                    requests: {
                        storage: `${sizeGi}Gi`
                    }
                }
            }
        });
    }
    catch (error) {
        if (error?.response?.statusCode !== 409)
            throw error;
    }
}
export async function getPvcSizeGi(namespace) {
    const { core } = getClients();
    try {
        const pvc = await core.readNamespacedPersistentVolumeClaim(TENANT_PVC_NAME, namespace);
        const value = pvc.body.spec?.resources?.requests?.storage;
        return parseGiToNumber(value);
    }
    catch (error) {
        if (error?.response?.statusCode === 404)
            return null;
        throw error;
    }
}
export async function expandPvcIfNeeded(namespace, nextSizeGi) {
    const { core } = getClients();
    let pvc;
    try {
        pvc = await core.readNamespacedPersistentVolumeClaim(TENANT_PVC_NAME, namespace);
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            throw new HttpError(409, "PVC site-data not found.");
        }
        throw error;
    }
    const currentGi = parseGiToNumber(pvc.body.spec?.resources?.requests?.storage);
    if (currentGi != null && nextSizeGi <= currentGi) {
        throw new HttpError(400, "diskGi must be greater than current size.");
    }
    const resourceVersion = pvc.body.metadata?.resourceVersion;
    if (!resourceVersion) {
        throw new HttpError(500, "PVC resourceVersion missing.");
    }
    const next = {
        ...pvc.body,
        spec: {
            ...pvc.body.spec,
            resources: {
                ...pvc.body.spec?.resources,
                requests: {
                    ...pvc.body.spec?.resources?.requests,
                    storage: `${nextSizeGi}Gi`
                }
            }
        },
        metadata: {
            ...pvc.body.metadata,
            resourceVersion
        }
    };
    await core.replaceNamespacedPersistentVolumeClaim(TENANT_PVC_NAME, namespace, next);
}

export async function ensureUserHomePvc(namespace, sizeGi = DEFAULT_USER_HOME_SIZE_GI) {
    const { core } = getClients();
    try {
        await core.createNamespacedPersistentVolumeClaim(namespace, {
            metadata: { 
                name: USER_HOME_PVC_NAME,
                labels: {
                    "voxeil.io/pvc-type": "user-home"
                }
            },
            spec: {
                accessModes: ["ReadWriteOnce"],
                storageClassName: DEFAULT_STORAGE_CLASS,
                resources: {
                    requests: {
                        storage: `${sizeGi}Gi`
                    }
                }
            }
        });
    }
    catch (error) {
        if (error?.response?.statusCode !== 409)
            throw error;
    }
}

export async function getUserHomePvcSizeGi(namespace) {
    const { core } = getClients();
    try {
        const pvc = await core.readNamespacedPersistentVolumeClaim(USER_HOME_PVC_NAME, namespace);
        const value = pvc.body.spec?.resources?.requests?.storage;
        return parseGiToNumber(value);
    }
    catch (error) {
        if (error?.response?.statusCode === 404)
            return null;
        throw error;
    }
}
