import k8s from "@kubernetes/client-node";

function clone(value) {
    return JSON.parse(JSON.stringify(value));
}

function replacePlaceholders(template, replacements) {
    let result = template;
    for (const [key, value] of Object.entries(replacements)) {
        result = result.replace(new RegExp(`REPLACE_${key}`, "g"), value);
    }
    return result;
}
export function renderResourceQuota(template, namespace, limits) {
    const quota = clone(template);
    quota.metadata = {
        ...quota.metadata,
        name: template.metadata?.name ?? "site-quota",
        namespace
    };
    quota.spec = quota.spec ?? {};
    quota.spec.hard = {
        ...quota.spec.hard,
        "pods": "1",
        "requests.cpu": String(limits.cpu),
        "requests.memory": `${limits.ramGi}Gi`,
        "limits.cpu": String(limits.cpu),
        "limits.memory": `${limits.ramGi}Gi`,
        "persistentvolumeclaims": "1",
        "requests.storage": `${limits.diskGi}Gi`
    };
    return quota;
}
export function renderLimitRange(template, namespace, limits) {
    const limitRange = clone(template);
    limitRange.metadata = {
        ...limitRange.metadata,
        name: template.metadata?.name ?? "site-limits",
        namespace
    };
    if (limits) {
        const next = {
            cpu: String(limits.cpu),
            memory: `${limits.ramGi}Gi`
        };
        if (!limitRange.spec) {
            limitRange.spec = {
                limits: [
                    { type: "Container", max: next, _default: next, defaultRequest: next, min: { cpu: "0", memory: "0Mi" } }
                ]
            };
        }
        else if (!limitRange.spec.limits || limitRange.spec.limits.length === 0) {
            limitRange.spec.limits = [
                { type: "Container", max: next, _default: next, defaultRequest: next, min: { cpu: "0", memory: "0Mi" } }
            ];
        }
        else {
            const limit = limitRange.spec.limits[0];
            limit.max = { ...(limit.max ?? {}), ...next };
            limit._default = { ...(limit._default ?? {}), ...next };
            limit.defaultRequest = { ...(limit.defaultRequest ?? {}), ...next };
            // Keep min permissive so valid plans never get rejected.
            limit.min = { ...(limit.min ?? {}), cpu: "0", memory: "0Mi" };
        }
    }
    return limitRange;
}
export function renderNetworkPolicy(template, namespace) {
    const policy = clone(template);
    policy.metadata = {
        ...policy.metadata,
        name: template.metadata?.name ?? "policy",
        namespace
    };
    return policy;
}

export function renderUserNamespace(template, namespace, tenantId) {
    const rendered = replacePlaceholders(template, {
        NAMESPACE: namespace,
        TENANT_ID: tenantId
    });
    return k8s.loadYaml(rendered);
}

export function renderUserResourceQuota(template, namespace, cpuRequest, cpuLimit, memoryRequest, memoryLimit, pvcCount) {
    const rendered = replacePlaceholders(template, {
        NAMESPACE: namespace,
        CPU_REQUEST: cpuRequest,
        CPU_LIMIT: cpuLimit,
        MEMORY_REQUEST: memoryRequest,
        MEMORY_LIMIT: memoryLimit,
        PVC_COUNT: pvcCount
    });
    return k8s.loadYaml(rendered);
}

export function renderUserLimitRange(template, namespace, cpuRequest, cpuLimit, memoryRequest, memoryLimit) {
    const rendered = replacePlaceholders(template, {
        NAMESPACE: namespace,
        CPU_REQUEST: cpuRequest,
        CPU_LIMIT: cpuLimit,
        MEMORY_REQUEST: memoryRequest,
        MEMORY_LIMIT: memoryLimit
    });
    return k8s.loadYaml(rendered);
}

export function renderUserNetworkPolicy(template, namespace) {
    const rendered = replacePlaceholders(template, {
        NAMESPACE: namespace
    });
    return k8s.loadYaml(rendered);
}

export function renderUserControllerRoleBinding(template, namespace) {
    const rendered = replacePlaceholders(template, {
        NAMESPACE: namespace
    });
    return k8s.loadYaml(rendered);
}
