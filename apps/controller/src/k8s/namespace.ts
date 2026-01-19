import { getClients, LABELS } from "./client.js";
import { HttpError } from "../http/errors.js";

export const TENANT_PREFIX = "tenant-";

export type TenantNamespace = {
  name: string;
  annotations: Record<string, string>;
};

export async function allocateTenantNamespace(
  baseSlug: string,
  annotations: Record<string, string> = {}
): Promise<{
  slug: string;
  namespace: string;
}> {
  const { core } = getClients();
  const slug = baseSlug;
  const namespace = `${TENANT_PREFIX}${slug}`;
  try {
    await core.createNamespace({
      metadata: {
        name: namespace,
        labels: {
          [LABELS.managedBy]: LABELS.managedBy,
          [LABELS.siteSlug]: slug
        },
        annotations: {
          ...annotations
        }
      }
    });
    return { slug, namespace };
  } catch (error: any) {
    if (error?.response?.statusCode === 409) {
      throw new HttpError(409, "Site already exists for this slug/domain.");
    }
    throw error;
  }
}

export async function requireNamespace(namespace: string): Promise<void> {
  const { core } = getClients();
  try {
    await core.readNamespace(namespace);
  } catch (error: any) {
    if (error?.response?.statusCode === 404) {
      throw new HttpError(404, "Namespace not found.");
    }
    throw error;
  }
}

export async function deleteNamespace(namespace: string): Promise<void> {
  const { core } = getClients();
  try {
    await core.deleteNamespace(namespace);
  } catch (error: any) {
    if (error?.response?.statusCode === 404) {
      throw new HttpError(404, "Namespace not found.");
    }
    throw error;
  }
}

export async function deleteTenantNamespace(slug: string): Promise<void> {
  const { core } = getClients();
  const namespace = `${TENANT_PREFIX}${slug}`;
  try {
    await core.deleteNamespace(namespace);
  } catch (error: any) {
    if (error?.response?.statusCode === 404) {
      throw new HttpError(404, "Site not found.");
    }
    throw error;
  }
}

export async function listTenantNamespaces(): Promise<TenantNamespace[]> {
  const { core } = getClients();
  const result = await core.listNamespace();
  return result.body.items
    .map((item) => {
      const name = item.metadata?.name;
      return {
        name: name ?? "",
        annotations: { ...(item.metadata?.annotations ?? {}) }
      };
    })
    .filter((item): item is TenantNamespace => Boolean(item.name && item.name.startsWith(TENANT_PREFIX)));
}

export async function readTenantNamespace(slug: string): Promise<TenantNamespace> {
  const { core } = getClients();
  const namespace = `${TENANT_PREFIX}${slug}`;
  try {
    const result = await core.readNamespace(namespace);
    return {
      name: namespace,
      annotations: { ...(result.body.metadata?.annotations ?? {}) }
    };
  } catch (error: any) {
    if (error?.response?.statusCode === 404) {
      throw new HttpError(404, "Site not found.");
    }
    throw error;
  }
}

export function slugFromNamespace(namespace: string): string {
  if (!namespace.startsWith(TENANT_PREFIX)) return namespace;
  return namespace.slice(TENANT_PREFIX.length);
}

export async function patchNamespaceAnnotations(
  namespace: string,
  annotations: Record<string, string>
): Promise<void> {
  const { core } = getClients();
  const patch = core.patchNamespace as unknown as (
    name: string,
    body: unknown,
    pretty?: string,
    dryRun?: string,
    fieldManager?: string,
    fieldValidation?: string,
    options?: { headers: { "Content-Type": string } }
  ) => Promise<unknown>;
  try {
    await patch(
      namespace,
      { metadata: { annotations } },
      undefined,
      undefined,
      undefined,
      undefined,
      { headers: { "Content-Type": "application/merge-patch+json" } }
    );
  } catch (error: any) {
    if (error?.response?.statusCode === 404) {
      throw new HttpError(404, "Namespace not found.");
    }
    throw error;
  }
}
