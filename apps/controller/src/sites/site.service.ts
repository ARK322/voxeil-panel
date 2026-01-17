import { HttpError } from "../http/errors.js";
import { loadTenantTemplates } from "../templates/load.js";
import {
  renderLimitRange,
  renderNetworkPolicy,
  renderResourceQuota
} from "../templates/render.js";
import { upsertLimitRange, upsertNetworkPolicy, upsertResourceQuota } from "../k8s/apply.js";
import { allocateTenantNamespace, listTenantNamespaces, requireNamespace, slugFromNamespace } from "../k8s/namespace.js";
import { ensurePvc, expandPvcIfNeeded, getPvcSizeGi } from "../k8s/pvc.js";
import { readQuotaStatus, updateQuotaLimits } from "../k8s/quota.js";
import { slugFromDomain } from "./site.slug.js";
import type {
  CreateSiteInput,
  PatchLimitsInput,
  CreateSiteResponse,
  SiteListItem,
  SiteLimitsResponse
} from "./site.dto.js";

export async function createSite(input: CreateSiteInput): Promise<CreateSiteResponse> {
  let baseSlug: string;
  try {
    baseSlug = slugFromDomain(input.domain);
  } catch (error: any) {
    throw new HttpError(400, error?.message ?? "Invalid domain.");
  }
  const { slug, namespace } = await allocateTenantNamespace(baseSlug);

  const templates = await loadTenantTemplates();
  const resourceQuota = renderResourceQuota(templates.resourceQuota, namespace, {
    cpu: input.cpu,
    ramGi: input.ramGi,
    diskGi: input.diskGi
  });
  const limitRange = renderLimitRange(templates.limitRange, namespace);
  const denyAll = renderNetworkPolicy(templates.networkPolicyDenyAll, namespace);
  const allowIngress = renderNetworkPolicy(templates.networkPolicyAllowIngress, namespace);

  await Promise.all([
    upsertResourceQuota(resourceQuota),
    upsertLimitRange(limitRange),
    upsertNetworkPolicy(denyAll),
    upsertNetworkPolicy(allowIngress),
    ensurePvc(namespace, input.diskGi)
  ]);

  return {
    domain: input.domain,
    slug,
    namespace,
    limits: {
      cpu: input.cpu,
      ramGi: input.ramGi,
      diskGi: input.diskGi,
      pods: 1
    }
  };
}

export async function listSites(): Promise<SiteListItem[]> {
  const templates = await loadTenantTemplates();
  const quotaName = templates.resourceQuota.metadata?.name ?? "site-quota";
  const namespaces = await listTenantNamespaces();
  const items: SiteListItem[] = [];

  for (const namespace of namespaces) {
    const slug = slugFromNamespace(namespace);
    try {
      const [quotaStatus, pvcSize] = await Promise.all([
        readQuotaStatus(namespace, quotaName),
        getPvcSizeGi(namespace)
      ]);

      const ready = quotaStatus.exists && pvcSize != null;
      items.push({ slug, namespace, ready });
    } catch {
      items.push({ slug, namespace, ready: false });
    }
  }

  return items;
}

export async function updateSiteLimits(
  slug: string,
  patch: PatchLimitsInput
): Promise<SiteLimitsResponse> {
  if (!slug) {
    throw new HttpError(400, "Slug is required.");
  }
  const namespace = `tenant-${slug}`;
  await requireNamespace(namespace);

  const templates = await loadTenantTemplates();
  const quotaName = templates.resourceQuota.metadata?.name ?? "site-quota";

  if (patch.diskGi !== undefined) {
    await expandPvcIfNeeded(namespace, patch.diskGi);
  }

  const updated = await updateQuotaLimits(namespace, quotaName, patch);

  return {
    slug,
    namespace,
    limits: {
      cpu: updated.cpu,
      ramGi: updated.ramGi,
      diskGi: updated.diskGi,
      pods: 1
    }
  };
}
