import { getClients } from "./client.js";
import { parseGiToNumber } from "./quantity.js";
import { HttpError } from "../http/errors.js";

export const TENANT_PVC_NAME = "site-data";

export async function ensurePvc(namespace: string, sizeGi: number): Promise<void> {
  const { core } = getClients();
  try {
    await core.createNamespacedPersistentVolumeClaim(namespace, {
      metadata: { name: TENANT_PVC_NAME },
      spec: {
        accessModes: ["ReadWriteOnce"],
        resources: {
          requests: {
            storage: `${sizeGi}Gi`
          }
        }
      }
    });
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
  }
}

export async function getPvcSizeGi(namespace: string): Promise<number | null> {
  const { core } = getClients();
  try {
    const pvc = await core.readNamespacedPersistentVolumeClaim(TENANT_PVC_NAME, namespace);
    const value = pvc.body.spec?.resources?.requests?.storage;
    return parseGiToNumber(value);
  } catch (error: any) {
    if (error?.response?.statusCode === 404) return null;
    throw error;
  }
}

export async function expandPvcIfNeeded(namespace: string, nextSizeGi: number): Promise<void> {
  const { core } = getClients();
  let pvc;
  try {
    pvc = await core.readNamespacedPersistentVolumeClaim(TENANT_PVC_NAME, namespace);
  } catch (error: any) {
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
