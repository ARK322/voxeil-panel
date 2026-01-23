import { promises as fs, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import k8s from "@kubernetes/client-node";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

let cached = null;
let userTemplatesCached = null;
function resolveTemplatesDir() {
    // Single source of truth: infra/k8s/templates/tenant
    const candidates = [
        path.resolve(process.cwd(), "infra", "k8s", "templates", "tenant"),
        path.resolve(__dirname, "..", "..", "..", "infra", "k8s", "templates", "tenant")
    ];
    for (const candidate of candidates) {
        if (existsSync(candidate)) {
            return candidate;
        }
    }
    throw new Error("Tenant templates directory not found. Expected: infra/k8s/templates/tenant");
}
function resolveUserTemplatesDir() {
    // Single source of truth: infra/k8s/templates/user
    const candidates = [
        path.resolve(process.cwd(), "infra", "k8s", "templates", "user"),
        path.resolve(__dirname, "..", "..", "..", "infra", "k8s", "templates", "user")
    ];
    for (const candidate of candidates) {
        if (existsSync(candidate)) {
            return candidate;
        }
    }
    throw new Error("User templates directory not found. Expected: infra/k8s/templates/user");
}
async function readYaml(filePath) {
    if (!existsSync(filePath)) {
        throw new Error(`Template file not found: ${filePath}`);
    }
    const raw = await fs.readFile(filePath, "utf8");
    return k8s.loadYaml(raw);
}
export async function loadTenantTemplates() {
    if (cached)
        return cached;
    const dir = resolveTemplatesDir();
    const resourceQuota = await readYaml(path.join(dir, "resourcequota.yaml"));
    const limitRange = await readYaml(path.join(dir, "limitrange.yaml"));
    const networkPolicyDenyAll = await readYaml(path.join(dir, "networkpolicy-deny-all.yaml"));
    const networkPolicyAllowIngress = await readYaml(path.join(dir, "networkpolicy-allow-ingress.yaml"));
    const networkPolicyAllowEgress = await readYaml(path.join(dir, "networkpolicy-allow-egress.yaml"));
    cached = {
        resourceQuota,
        limitRange,
        networkPolicyDenyAll,
        networkPolicyAllowIngress,
        networkPolicyAllowEgress
    };
    return cached;
}

export async function loadUserTemplates() {
    if (userTemplatesCached)
        return userTemplatesCached;
    const dir = resolveUserTemplatesDir();
    const namespace = await readYaml(path.join(dir, "namespace.yaml"));
    const resourceQuota = await readYaml(path.join(dir, "resourcequota.yaml"));
    const limitRange = await readYaml(path.join(dir, "limitrange.yaml"));
    const networkPolicyDenyAll = await readYaml(path.join(dir, "networkpolicy-deny-all.yaml"));
    const networkPolicyAllowIngress = await readYaml(path.join(dir, "networkpolicy-allow-ingress.yaml"));
    const networkPolicyAllowEgress = await readYaml(path.join(dir, "networkpolicy-allow-egress.yaml"));
    const controllerRoleBinding = await readYaml(path.join(dir, "controller-rolebinding.yaml"));
    userTemplatesCached = {
        namespace,
        resourceQuota,
        limitRange,
        networkPolicyDenyAll,
        networkPolicyAllowIngress,
        networkPolicyAllowEgress,
        controllerRoleBinding
    };
    return userTemplatesCached;
}
