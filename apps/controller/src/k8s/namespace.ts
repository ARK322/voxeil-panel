import { getClients, LABELS } from "./client.js";
import { HttpError } from "../http/errors.js";

export const TENANT_PREFIX = "tenant-";

export async function allocateTenantNamespace(baseSlug: string): Promise<{
  slug: string;
  namespace: string;
}> {
  const { core } = getClients();
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const suffix = attempt === 0 ? "" : `-${attempt + 1}`;
    const slug = `${baseSlug}${suffix}`;
    const namespace = `${TENANT_PREFIX}${slug}`;
    try {
      await core.createNamespace({
        metadata: {
          name: namespace,
          labels: {
            [LABELS.managedBy]: LABELS.managedBy,
            [LABELS.siteSlug]: slug
          }
        }
      });
      return { slug, namespace };
    } catch (error: any) {
      if (error?.response?.statusCode === 409) continue;
      throw error;
    }
  }
  throw new HttpError(409, "Unable to allocate a unique namespace.");
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

export async function listTenantNamespaces(): Promise<string[]> {
  const { core } = getClients();
  const result = await core.listNamespace();
  return result.body.items
    .map((item) => item.metadata?.name)
    .filter((name): name is string => Boolean(name && name.startsWith(TENANT_PREFIX)));
}

export function slugFromNamespace(namespace: string): string {
  if (!namespace.startsWith(TENANT_PREFIX)) return namespace;
  return namespace.slice(TENANT_PREFIX.length);
}
