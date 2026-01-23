import { promises as fs, existsSync } from "node:fs";
import path from "node:path";
import k8s from "@kubernetes/client-node";
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
    // Single source of truth: apps/controller/templates/user
    const dir = path.resolve(__dirname, "user");
    if (existsSync(dir)) {
        return dir;
    }
    throw new Error("User templates directory not found. Expected: apps/controller/templates/user");
}
async function readYaml(filePath) {
    if (!existsSync(filePath)) {
        throw new Error(`Template file not found: ${filePath}`);
    }
    const raw = await fs.readFile(filePath, "utf8");
    return k8s.loadYaml(raw);
}
async function readTemplate(filePath) {
    if (!existsSync(filePath)) {
        throw new Error(`Template file not found: ${filePath}`);
    }
    return await fs.readFile(filePath, "utf8");
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
    const namespace = await readTemplate(path.join(dir, "namespace.yaml.tpl"));
    const resourceQuota = await readTemplate(path.join(dir, "resourcequota.yaml.tpl"));
    const limitRange = await readTemplate(path.join(dir, "limitrange.yaml.tpl"));
    const networkPolicyDenyAll = await readTemplate(path.join(dir, "networkpolicy-deny-all.yaml.tpl"));
    const controllerRoleBinding = await readTemplate(path.join(dir, "controller-rolebinding.yaml.tpl"));
    userTemplatesCached = {
        namespace,
        resourceQuota,
        limitRange,
        networkPolicyDenyAll,
        controllerRoleBinding
    };
    return userTemplatesCached;
}
