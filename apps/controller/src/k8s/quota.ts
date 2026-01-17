import { getClients } from "./client.js";
import { parseCpuToNumber, parseGiToNumber } from "./quantity.js";
import { HttpError } from "../http/errors.js";

export type LimitsPatch = {
  cpu?: number;
  ramGi?: number;
  diskGi?: number;
};

export type ResolvedLimits = {
  cpu: number;
  ramGi: number;
  diskGi: number;
};

export type QuotaStatus = {
  exists: boolean;
  limits?: ResolvedLimits;
};

export async function readQuotaStatus(
  namespace: string,
  quotaName: string
): Promise<QuotaStatus> {
  const { core } = getClients();
  try {
    const result = await core.readNamespacedResourceQuota(quotaName, namespace);
    const hard = result.body.spec?.hard ?? {};
    const cpu = parseCpuToNumber(hard["requests.cpu"]);
    const ramGi = parseGiToNumber(hard["requests.memory"]);
    const diskGi = parseGiToNumber(hard["requests.storage"]);
    if (cpu == null || ramGi == null || diskGi == null) {
      return { exists: true };
    }
    return { exists: true, limits: { cpu, ramGi, diskGi } };
  } catch (error: any) {
    if (error?.response?.statusCode === 404) return { exists: false };
    throw error;
  }
}

export async function updateQuotaLimits(
  namespace: string,
  quotaName: string,
  patch: LimitsPatch
): Promise<ResolvedLimits> {
  const { core } = getClients();
  const current = await core.readNamespacedResourceQuota(quotaName, namespace);
  const resourceVersion = current.body.metadata?.resourceVersion;
  if (!resourceVersion) {
    throw new HttpError(500, "ResourceQuota resourceVersion missing.");
  }

  const hard = { ...(current.body.spec?.hard ?? {}) };
  if (patch.cpu !== undefined) hard["requests.cpu"] = String(patch.cpu);
  if (patch.ramGi !== undefined) hard["requests.memory"] = `${patch.ramGi}Gi`;
  if (patch.diskGi !== undefined) hard["requests.storage"] = `${patch.diskGi}Gi`;
  hard["pods"] = "1";
  hard["persistentvolumeclaims"] = "1";

  const next = {
    ...current.body,
    spec: {
      ...current.body.spec,
      hard
    },
    metadata: {
      ...current.body.metadata,
      resourceVersion
    }
  };

  await core.replaceNamespacedResourceQuota(quotaName, namespace, next);

  return {
    cpu: patch.cpu ?? parseCpuToNumber(hard["requests.cpu"]) ?? 0,
    ramGi: patch.ramGi ?? parseGiToNumber(hard["requests.memory"]) ?? 0,
    diskGi: patch.diskGi ?? parseGiToNumber(hard["requests.storage"]) ?? 0
  };
}
