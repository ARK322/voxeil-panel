import { getClients } from "./client.js";
import { parseCpuToNumber, parseGiToNumber } from "./quantity.js";
import { HttpError } from "../http/errors.js";
export async function readQuotaStatus(namespace, quotaName) {
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
    }
    catch (error) {
        if (error?.response?.statusCode === 404)
            return { exists: false };
        throw error;
    }
}
export async function updateQuotaLimits(namespace, quotaName, patch) {
    const { core } = getClients();
    const current = await core.readNamespacedResourceQuota(quotaName, namespace);
    const resourceVersion = current.body.metadata?.resourceVersion;
    if (!resourceVersion) {
        throw new HttpError(500, "ResourceQuota resourceVersion missing.");
    }
    const hard = { ...(current.body.spec?.hard ?? {}) };
    const currentCpu = parseCpuToNumber(hard["requests.cpu"]) ?? parseCpuToNumber(hard["limits.cpu"]) ?? 0;
    const currentRamGi = parseGiToNumber(hard["requests.memory"]) ?? parseGiToNumber(hard["limits.memory"]) ?? 0;
    const currentDiskGi = parseGiToNumber(hard["requests.storage"]) ?? 0;
    const desiredCpu = patch.cpu ?? currentCpu;
    const desiredRamGi = patch.ramGi ?? currentRamGi;
    const desiredDiskGi = patch.diskGi ?? currentDiskGi;
    hard["requests.cpu"] = String(desiredCpu);
    hard["limits.cpu"] = String(desiredCpu);
    hard["requests.memory"] = `${desiredRamGi}Gi`;
    hard["limits.memory"] = `${desiredRamGi}Gi`;
    hard["requests.storage"] = `${desiredDiskGi}Gi`;
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
        cpu: desiredCpu,
        ramGi: desiredRamGi,
        diskGi: desiredDiskGi
    };
}
