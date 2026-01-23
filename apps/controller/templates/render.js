import k8s from "@kubernetes/client-node";

function clone(value) {
    return JSON.parse(JSON.stringify(value));
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
    const resource = clone(template);
    resource.metadata = {
        ...resource.metadata,
        name: namespace,
        labels: {
            ...resource.metadata?.labels,
            "voxeil.io/user-id": tenantId
        }
    };
    return resource;
}

export function renderUserResourceQuota(template, namespace, cpuRequest, cpuLimit, memoryRequest, memoryLimit, pvcCount) {
    const quota = clone(template);
    quota.metadata = {
        ...quota.metadata,
        namespace
    };
    quota.spec = quota.spec ?? {};
    quota.spec.hard = {
        ...quota.spec.hard,
        "requests.cpu": cpuRequest,
        "requests.memory": memoryRequest,
        "limits.cpu": cpuLimit,
        "limits.memory": memoryLimit,
        "persistentvolumeclaims": pvcCount
    };
    return quota;
}

export function renderUserLimitRange(template, namespace, cpuRequest, cpuLimit, memoryRequest, memoryLimit) {
    const limitRange = clone(template);
    limitRange.metadata = {
        ...limitRange.metadata,
        namespace
    };
    limitRange.spec = limitRange.spec ?? {};
    if (!limitRange.spec.limits || limitRange.spec.limits.length === 0) {
        limitRange.spec.limits = [{
            type: "Container",
            default: {
                cpu: cpuLimit,
                memory: memoryLimit
            },
            defaultRequest: {
                cpu: cpuRequest,
                memory: memoryRequest
            }
        }];
    } else {
        const limit = limitRange.spec.limits[0];
        limit.default = {
            cpu: cpuLimit,
            memory: memoryLimit
        };
        limit.defaultRequest = {
            cpu: cpuRequest,
            memory: memoryRequest
        };
    }
    return limitRange;
}

export function renderUserNetworkPolicy(template, namespace) {
    const policy = clone(template);
    policy.metadata = {
        ...policy.metadata,
        namespace
    };
    return policy;
}

export function renderUserControllerRoleBinding(template, namespace) {
    const roleBinding = clone(template);
    roleBinding.metadata = {
        ...roleBinding.metadata,
        namespace
    };
    return roleBinding;
}
