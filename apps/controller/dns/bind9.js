import { HttpError } from "../http/errors.js";
import { getClients } from "../k8s/client.js";
const DNS_NAMESPACE = "dns-zone";
const ZONES_CONFIGMAP = "bind9-zones";
const BIND9_DEPLOYMENT = "bind9";
function normalizeDomain(domain) {
    const normalized = domain.trim().toLowerCase().replace(/\.$/, "");
    if (!normalized) {
        throw new HttpError(400, "Domain is required.");
    }
    return normalized;
}
function normalizeTargetIp(value) {
    const trimmed = value.trim();
    if (!trimmed) {
        throw new HttpError(400, "targetIp is required.");
    }
    return trimmed;
}
function buildZoneBlock(domain) {
    return [
        `zone "${domain}" {`,
        "  type master;",
        `  file "/etc/bind/zones/db.${domain}";`,
        "};"
    ].join("\n");
}
function buildZoneFile({ domain, targetIp }) {
    const serial = Math.floor(Date.now() / 1000);
    return [
        "$TTL 300",
        `@ IN SOA ns1.${domain}. admin.${domain}. (`,
        `  ${serial} ; serial`,
        "  3600 ; refresh",
        "  900 ; retry",
        "  604800 ; expire",
        "  300 ; minimum",
        ")",
        `@ IN NS ns1.${domain}.`,
        `ns1 IN A ${targetIp}`,
        `@ IN A ${targetIp}`
    ].join("\n");
}
function removeZoneBlock(namedConfLocal, domain) {
    const pattern = new RegExp(`zone\\s+\\"${domain}\\"\\s+\\{[\\s\\S]*?\\};\\s*`, "g");
    return namedConfLocal.replace(pattern, "");
}
async function readZonesConfigMap() {
    const { core } = getClients();
    try {
        const result = await core.readNamespacedConfigMap(ZONES_CONFIGMAP, DNS_NAMESPACE);
        return result.body;
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            const created = await core.createNamespacedConfigMap(DNS_NAMESPACE, {
                apiVersion: "v1",
                kind: "ConfigMap",
                metadata: { name: ZONES_CONFIGMAP, namespace: DNS_NAMESPACE },
                data: {
                    "named.conf.local": "// Managed by Voxeil controller.\n"
                }
            });
            return created.body;
        }
        throw error;
    }
}
async function saveZonesConfigMap(data) {
    const { core } = getClients();
    const patch = core.patchNamespacedConfigMap;
    await patch(ZONES_CONFIGMAP, DNS_NAMESPACE, { data }, undefined, undefined, undefined, undefined, { headers: { "Content-Type": "application/merge-patch+json" } });
}
async function restartBind9() {
    const { apps } = getClients();
    const patch = apps.patchNamespacedDeployment;
    await patch(BIND9_DEPLOYMENT, DNS_NAMESPACE, {
        spec: {
            template: {
                metadata: {
                    annotations: {
                        "voxeil.com/restarted-at": new Date().toISOString()
                    }
                }
            }
        }
    }, undefined, undefined, undefined, undefined, { headers: { "Content-Type": "application/merge-patch+json" } });
}
export async function ensureDnsZone(input) {
    const domain = normalizeDomain(input.domain);
    const targetIp = normalizeTargetIp(input.targetIp);
    const configMap = await readZonesConfigMap();
    const data = { ...(configMap.data ?? {}) };
    const zoneKey = `db.${domain}`;
    const existingLocal = data["named.conf.local"] ?? "// Managed by Voxeil controller.\n";
    const cleanedLocal = removeZoneBlock(existingLocal, domain).trimEnd();
    const zoneBlock = buildZoneBlock(domain);
    data["named.conf.local"] = `${cleanedLocal}\n${zoneBlock}\n`;
    data[zoneKey] = buildZoneFile({ domain, targetIp });
    await saveZonesConfigMap(data);
    await restartBind9();
}
export async function removeDnsZone(domainInput) {
    const domain = normalizeDomain(domainInput);
    const configMap = await readZonesConfigMap();
    const data = { ...(configMap.data ?? {}) };
    const existingLocal = data["named.conf.local"] ?? "";
    data["named.conf.local"] = removeZoneBlock(existingLocal, domain);
    delete data[`db.${domain}`];
    await saveZonesConfigMap(data);
    await restartBind9();
}
