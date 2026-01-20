import type { V1Role, V1RoleBinding } from "@kubernetes/client-node";
import { getClients } from "./client.js";
import { TENANT_PREFIX } from "./namespace.js";

const PLATFORM_NAMESPACE = process.env.PLATFORM_NAMESPACE ?? "platform";
const CONTROLLER_SERVICE_ACCOUNT = process.env.CONTROLLER_SERVICE_ACCOUNT ?? "controller-sa";
const TENANT_SECRET_ROLE = "controller-tenant-secrets";
const TENANT_SECRET_BINDING = "controller-tenant-secrets-binding";

async function upsertRole(role: V1Role): Promise<void> {
  const { rbac } = getClients();
  const name = role.metadata?.name ?? "role";
  const namespace = role.metadata?.namespace ?? "default";
  try {
    await rbac.createNamespacedRole(namespace, role);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
    const existing = await rbac.readNamespacedRole(name, namespace);
    const next = {
      ...role,
      metadata: {
        ...role.metadata,
        resourceVersion: existing.body.metadata?.resourceVersion
      }
    };
    await rbac.replaceNamespacedRole(name, namespace, next);
  }
}

async function upsertRoleBinding(binding: V1RoleBinding): Promise<void> {
  const { rbac } = getClients();
  const name = binding.metadata?.name ?? "binding";
  const namespace = binding.metadata?.namespace ?? "default";
  try {
    await rbac.createNamespacedRoleBinding(namespace, binding);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
    const existing = await rbac.readNamespacedRoleBinding(name, namespace);
    const next = {
      ...binding,
      metadata: {
        ...binding.metadata,
        resourceVersion: existing.body.metadata?.resourceVersion
      }
    };
    await rbac.replaceNamespacedRoleBinding(name, namespace, next);
  }
}

export async function ensureTenantSecretRbac(namespace: string): Promise<void> {
  if (!namespace.startsWith(TENANT_PREFIX)) return;

  const role: V1Role = {
    apiVersion: "rbac.authorization.k8s.io/v1",
    kind: "Role",
    metadata: {
      name: TENANT_SECRET_ROLE,
      namespace
    },
    rules: [
      {
        apiGroups: [""],
        resources: ["secrets"],
        verbs: ["get", "create", "patch", "delete"]
      }
    ]
  };

  const binding: V1RoleBinding = {
    apiVersion: "rbac.authorization.k8s.io/v1",
    kind: "RoleBinding",
    metadata: {
      name: TENANT_SECRET_BINDING,
      namespace
    },
    subjects: [
      {
        kind: "ServiceAccount",
        name: CONTROLLER_SERVICE_ACCOUNT,
        namespace: PLATFORM_NAMESPACE
      }
    ],
    roleRef: {
      apiGroup: "rbac.authorization.k8s.io",
      kind: "Role",
      name: TENANT_SECRET_ROLE
    }
  };

  await upsertRole(role);
  await upsertRoleBinding(binding);
}
