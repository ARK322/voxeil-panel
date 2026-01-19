import { HttpError } from "../http/errors.js";
import { loadTenantTemplates } from "../templates/load.js";
import {
  renderLimitRange,
  renderNetworkPolicy,
  renderResourceQuota
} from "../templates/render.js";
import {
  upsertDeployment,
  upsertIngress,
  upsertLimitRange,
  upsertNetworkPolicy,
  upsertResourceQuota,
  upsertService
} from "../k8s/apply.js";
import {
  allocateTenantNamespace,
  deleteTenantNamespace,
  listTenantNamespaces,
  patchNamespaceAnnotations,
  readTenantNamespace,
  requireNamespace,
  slugFromNamespace
} from "../k8s/namespace.js";
import { patchIngress } from "../k8s/ingress.js";
import { ensurePvc, expandPvcIfNeeded, getPvcSizeGi } from "../k8s/pvc.js";
import { readQuotaStatus, updateQuotaLimits } from "../k8s/quota.js";
import { buildDeployment, buildIngress, buildService } from "../k8s/publish.js";
import { ensureGhcrPullSecret } from "../k8s/secrets.js";
import { SITE_ANNOTATIONS } from "../k8s/annotations.js";
import { slugFromDomain, validateSlug } from "./site.slug.js";
import type {
  CreateSiteInput,
  PatchLimitsInput,
  PatchTlsInput,
  CreateSiteResponse,
  DeploySiteInput,
  DeploySiteResponse,
  PatchTlsResponse,
  SiteListItem,
  SiteLimitsResponse
} from "./site.dto.js";

const DEFAULT_MAINTENANCE_IMAGE = "ghcr.io/OWNER/voxeil-maintenance:latest";
const DEFAULT_MAINTENANCE_PORT = 3000;
const DEFAULT_TLS_ISSUER = "letsencrypt-staging";

function resolveMaintenanceImage(): string {
  const value = process.env.GHCR_MAINTENANCE_IMAGE ?? DEFAULT_MAINTENANCE_IMAGE;
  if (!value.trim()) {
    throw new HttpError(500, "GHCR_MAINTENANCE_IMAGE must be set.");
  }
  return value;
}

function resolveMaintenancePort(): number {
  const raw = process.env.MAINTENANCE_CONTAINER_PORT;
  const port = raw ? Number(raw) : DEFAULT_MAINTENANCE_PORT;
  if (!Number.isInteger(port) || port <= 0) {
    throw new HttpError(500, "MAINTENANCE_CONTAINER_PORT must be a positive integer.");
  }
  return port;
}

function parseBooleanAnnotation(value?: string): boolean | undefined {
  if (!value) return undefined;
  const normalized = value.toLowerCase();
  if (normalized === "true") return true;
  if (normalized === "false") return false;
  return undefined;
}

function parseNumberAnnotation(value?: string): number | undefined {
  if (!value) return undefined;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

export async function createSite(input: CreateSiteInput): Promise<CreateSiteResponse> {
  let baseSlug: string;
  try {
    baseSlug = slugFromDomain(input.domain);
  } catch (error: any) {
    throw new HttpError(400, error?.message ?? "Invalid domain.");
  }
  const maintenanceImage = resolveMaintenanceImage();
  const maintenancePort = resolveMaintenancePort();
  const tlsEnabled = input.tlsEnabled ?? false;
  const { slug, namespace } = await allocateTenantNamespace(baseSlug, {
    [SITE_ANNOTATIONS.domain]: input.domain,
    [SITE_ANNOTATIONS.tlsEnabled]: tlsEnabled ? "true" : "false",
    [SITE_ANNOTATIONS.tlsIssuer]: DEFAULT_TLS_ISSUER,
    [SITE_ANNOTATIONS.image]: maintenanceImage,
    [SITE_ANNOTATIONS.containerPort]: String(maintenancePort),
    [SITE_ANNOTATIONS.cpu]: String(input.cpu),
    [SITE_ANNOTATIONS.ramGi]: String(input.ramGi),
    [SITE_ANNOTATIONS.diskGi]: String(input.diskGi)
  });

  const templates = await loadTenantTemplates();
  const resourceQuota = renderResourceQuota(templates.resourceQuota, namespace, {
    cpu: input.cpu,
    ramGi: input.ramGi,
    diskGi: input.diskGi
  });
  const limitRange = renderLimitRange(templates.limitRange, namespace, {
    cpu: input.cpu,
    ramGi: input.ramGi
  });
  const denyAll = renderNetworkPolicy(templates.networkPolicyDenyAll, namespace);
  const allowIngress = renderNetworkPolicy(templates.networkPolicyAllowIngress, namespace);

  await Promise.all([
    upsertResourceQuota(resourceQuota),
    upsertLimitRange(limitRange),
    upsertNetworkPolicy(denyAll),
    upsertNetworkPolicy(allowIngress),
    ensurePvc(namespace, input.diskGi)
  ]);

  await ensureGhcrPullSecret(namespace, slug);
  const host = input.domain.trim();
  if (!host) {
    throw new HttpError(400, "Domain is required.");
  }
  const maintenanceSpec = {
    namespace,
    slug,
    host,
    image: maintenanceImage,
    containerPort: maintenancePort,
    cpu: input.cpu,
    ramGi: input.ramGi
  };
  await Promise.all([
    upsertDeployment(buildDeployment(maintenanceSpec)),
    upsertService(buildService(maintenanceSpec)),
    upsertIngress(buildIngress(maintenanceSpec))
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

  for (const namespaceEntry of namespaces) {
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    const slug = slugFromNamespace(namespace);
    try {
      const [quotaStatus, pvcSize] = await Promise.all([
        readQuotaStatus(namespace, quotaName),
        getPvcSizeGi(namespace)
      ]);

      const ready = quotaStatus.exists && pvcSize != null;
      items.push({
        slug,
        namespace,
        ready,
        domain: annotations[SITE_ANNOTATIONS.domain],
        image: annotations[SITE_ANNOTATIONS.image],
        containerPort: parseNumberAnnotation(annotations[SITE_ANNOTATIONS.containerPort]),
        tlsEnabled: parseBooleanAnnotation(annotations[SITE_ANNOTATIONS.tlsEnabled]),
        tlsIssuer: annotations[SITE_ANNOTATIONS.tlsIssuer],
        cpu: parseNumberAnnotation(annotations[SITE_ANNOTATIONS.cpu]),
        ramGi: parseNumberAnnotation(annotations[SITE_ANNOTATIONS.ramGi]),
        diskGi: parseNumberAnnotation(annotations[SITE_ANNOTATIONS.diskGi])
      });
    } catch {
      items.push({
        slug,
        namespace,
        ready: false,
        domain: annotations[SITE_ANNOTATIONS.domain],
        image: annotations[SITE_ANNOTATIONS.image],
        containerPort: parseNumberAnnotation(annotations[SITE_ANNOTATIONS.containerPort]),
        tlsEnabled: parseBooleanAnnotation(annotations[SITE_ANNOTATIONS.tlsEnabled]),
        tlsIssuer: annotations[SITE_ANNOTATIONS.tlsIssuer],
        cpu: parseNumberAnnotation(annotations[SITE_ANNOTATIONS.cpu]),
        ramGi: parseNumberAnnotation(annotations[SITE_ANNOTATIONS.ramGi]),
        diskGi: parseNumberAnnotation(annotations[SITE_ANNOTATIONS.diskGi])
      });
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
  if (patch.cpu !== undefined || patch.ramGi !== undefined) {
    const limitRange = renderLimitRange(templates.limitRange, namespace, {
      cpu: updated.cpu,
      ramGi: updated.ramGi
    });
    await upsertLimitRange(limitRange);
  }

  await patchNamespaceAnnotations(namespace, {
    [SITE_ANNOTATIONS.cpu]: String(updated.cpu),
    [SITE_ANNOTATIONS.ramGi]: String(updated.ramGi),
    [SITE_ANNOTATIONS.diskGi]: String(updated.diskGi)
  });

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

export async function deploySite(
  slug: string,
  input: DeploySiteInput
): Promise<DeploySiteResponse> {
  let normalized: string;
  try {
    normalized = validateSlug(slug);
  } catch (error: any) {
    throw new HttpError(400, error?.message ?? "Invalid slug.");
  }
  const namespace = `tenant-${normalized}`;
  await requireNamespace(namespace);

  await ensureGhcrPullSecret(namespace, normalized);

  const templates = await loadTenantTemplates();
  const quotaName = templates.resourceQuota.metadata?.name ?? "site-quota";
  const quotaStatus = await readQuotaStatus(namespace, quotaName);
  if (!quotaStatus.exists || !quotaStatus.limits) {
    throw new HttpError(500, "Tenant limits are missing for deployment.");
  }

  const spec = {
    namespace,
    slug: normalized,
    host: "",
    image: input.image,
    containerPort: input.containerPort,
    cpu: quotaStatus.limits.cpu,
    ramGi: quotaStatus.limits.ramGi
  };

  await Promise.all([
    upsertDeployment(buildDeployment(spec)),
    upsertService(buildService(spec))
  ]);

  await patchNamespaceAnnotations(namespace, {
    [SITE_ANNOTATIONS.image]: input.image,
    [SITE_ANNOTATIONS.containerPort]: String(input.containerPort)
  });

  return {
    slug: normalized,
    namespace,
    image: input.image,
    containerPort: input.containerPort
  };
}

export async function deleteSite(slug: string): Promise<{ slug: string }> {
  let normalized: string;
  try {
    normalized = validateSlug(slug);
  } catch (error: any) {
    throw new HttpError(400, error?.message ?? "Invalid slug.");
  }
  await deleteTenantNamespace(normalized);
  return { slug: normalized };
}

export async function updateSiteTls(
  slug: string,
  input: PatchTlsInput
): Promise<PatchTlsResponse> {
  let normalized: string;
  try {
    normalized = validateSlug(slug);
  } catch (error: any) {
    throw new HttpError(400, error?.message ?? "Invalid slug.");
  }
  const namespaceEntry = await readTenantNamespace(normalized);
  const namespace = namespaceEntry.name;
  const host = namespaceEntry.annotations[SITE_ANNOTATIONS.domain]?.trim();
  if (!host) {
    throw new HttpError(500, "Site domain is missing.");
  }
  const issuer = input.issuer ?? DEFAULT_TLS_ISSUER;
  const tlsEnabled = input.enabled;

  await patchNamespaceAnnotations(namespace, {
    [SITE_ANNOTATIONS.tlsEnabled]: tlsEnabled ? "true" : "false",
    [SITE_ANNOTATIONS.tlsIssuer]: issuer
  });

  await patchIngress("web", namespace, {
    metadata: {
      annotations: {
        "cert-manager.io/cluster-issuer": tlsEnabled ? issuer : null,
        "traefik.ingress.kubernetes.io/router.entrypoints": tlsEnabled ? "websecure" : "web",
        "traefik.ingress.kubernetes.io/router.tls": tlsEnabled ? "true" : "false"
      }
    },
    spec: {
      tls: tlsEnabled
        ? [
            {
              hosts: [host],
              secretName: `tls-${normalized}`
            }
          ]
        : null
    }
  });

  return {
    ok: true,
    slug: normalized,
    tlsEnabled,
    issuer
  };
}
