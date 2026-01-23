import { promises as fs } from "node:fs";
import path from "node:path";
import { HttpError } from "../http/errors.js";
import { loadUserTemplates } from "../templates/load.js";
import { upsertDeployment, upsertIngress, upsertLimitRange, upsertNetworkPolicy, upsertResourceQuota, upsertService } from "../k8s/apply.js";
import { patchNamespaceAnnotations, requireNamespace, resolveUserNamespaceForSite, readUserNamespaceSite, extractUserIdFromNamespace, deleteNamespace, readSiteMetadata } from "../k8s/namespace.js";
import { patchIngress, resolveIngressIssuer } from "../k8s/ingress.js";
import { ensurePvc, expandPvcIfNeeded, getPvcSizeGi } from "../k8s/pvc.js";
import { readQuotaStatus, updateQuotaLimits } from "../k8s/quota.js";
import { buildDeployment, buildIngress, buildService } from "../k8s/publish.js";
import { deleteSecret, ensureGhcrPullSecret, readSecret, upsertSecret, GHCR_PULL_SECRET_NAME } from "../k8s/secrets.js";
import { getClients, LABELS } from "../k8s/client.js";
import { getDeploymentName, getServiceName, getIngressName } from "../k8s/publish.js";
import { SITE_ANNOTATIONS } from "../k8s/annotations.js";
import { ensureDatabase, ensureRole, revokeAndTerminate, dropDatabase, dropRole, generateDbPassword, normalizeDbName, normalizeDbUser, resolveDbName, resolveDbUser } from "../postgres/admin.js";
import { slugFromDomain, validateSlug } from "./site.slug.js";
import { restoreSiteDb, restoreSiteFiles } from "../backup/restore.service.js";
import { ensureDnsZone, removeDnsZone } from "../dns/bind9.js";
import { dispatchWorkflow, parseRepo, resolveWorkflow } from "../github/client.js";
import { createMailcowMailbox, createMailcowAlias, deleteMailcowMailbox, deleteMailcowAlias, ensureMailcowDomain, getMailcowDomainActive, listMailcowAliases, listMailcowMailboxes, purgeMailcowDomain, setMailcowDomainActive } from "../mailcow/client.js";
const DEFAULT_MAINTENANCE_IMAGE = "ghcr.io/ark322/voxeil-maintenance:latest";
const DEFAULT_MAINTENANCE_PORT = 3000;
const DEFAULT_TLS_ISSUER = "letsencrypt-staging";
const SITE_DB_SECRET_NAME = "db-conn";
const LEGACY_DB_SECRET_NAME = "site-db";
const BACKUP_ROOT = "/backups/sites";
const BACKUP_NAMESPACE = "backup-system";
const DEFAULT_BACKUP_RETENTION_DAYS = 14;
const DEFAULT_BACKUP_SCHEDULE = "0 3 * * *";
const DEFAULT_BACKUP_RUNNER_IMAGE = "ghcr.io/voxeil/backup-runner:latest";
export const GITHUB_SECRET_NAME = "github-credentials";
const DEFAULT_REGISTRY_SERVER = "ghcr.io";
function resolveMaintenanceImage() {
    const value = process.env.GHCR_MAINTENANCE_IMAGE ?? DEFAULT_MAINTENANCE_IMAGE;
    if (!value.trim()) {
        throw new HttpError(500, "GHCR_MAINTENANCE_IMAGE must be set.");
    }
    return value;
}
function resolveMaintenancePort() {
    const raw = process.env.MAINTENANCE_CONTAINER_PORT;
    const port = raw ? Number(raw) : DEFAULT_MAINTENANCE_PORT;
    if (!Number.isInteger(port) || port <= 0) {
        throw new HttpError(500, "MAINTENANCE_CONTAINER_PORT must be a positive integer.");
    }
    return port;
}
function resolveBackupRunnerImage() {
    return process.env.BACKUP_RUNNER_IMAGE?.trim() || DEFAULT_BACKUP_RUNNER_IMAGE;
}
function buildDockerConfig(options) {
    const auth = Buffer.from(`${options.username}:${options.token}`).toString("base64");
    return JSON.stringify({
        auths: {
            [options.server]: {
                username: options.username,
                password: options.token,
                auth,
                ...(options.email ? { email: options.email } : {})
            }
        }
    });
}
async function resolveImagePullSecretName(namespace) {
    const secret = await readSecret(namespace, GHCR_PULL_SECRET_NAME);
    return secret ? GHCR_PULL_SECRET_NAME : undefined;
}
async function upsertRegistryPullSecret(options) {
    await upsertSecret({
        apiVersion: "v1",
        kind: "Secret",
        metadata: {
            name: GHCR_PULL_SECRET_NAME,
            namespace: options.namespace,
            labels: {
                [LABELS.managedBy]: LABELS.managedBy,
                [LABELS.siteSlug]: options.slug
            }
        },
        type: "kubernetes.io/dockerconfigjson",
        stringData: {
            ".dockerconfigjson": buildDockerConfig({
                server: options.server,
                username: options.username,
                token: options.token,
                email: options.email
            })
        }
    });
}
function parseBooleanAnnotation(value) {
    if (!value)
        return undefined;
    const normalized = value.toLowerCase();
    if (normalized === "true")
        return true;
    if (normalized === "false")
        return false;
    return undefined;
}
function parseNumberAnnotation(value) {
    if (!value)
        return undefined;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
}
function normalizeBackupSchedule(value) {
    const schedule = value.trim();
    if (!schedule) {
        throw new HttpError(400, "schedule is required.");
    }
    return schedule;
}
function normalizeRetentionDays(value) {
    if (!Number.isInteger(value) || value <= 0) {
        throw new HttpError(400, "retentionDays must be a positive integer.");
    }
    return value;
}
function resolveBackupSettings(input, existing) {
    const retentionDays = normalizeRetentionDays(input?.retentionDays ?? existing.retentionDays ?? DEFAULT_BACKUP_RETENTION_DAYS);
    const schedule = normalizeBackupSchedule(input?.schedule ?? existing.schedule ?? DEFAULT_BACKUP_SCHEDULE);
    return { retentionDays, schedule };
}
function buildBackupRunnerPodSpec(options) {
    const runnerImage = resolveBackupRunnerImage();
    const dbHost = process.env.POSTGRES_HOST ?? process.env.DB_HOST ?? "";
    const dbPort = process.env.POSTGRES_PORT ?? process.env.DB_PORT ?? "5432";
    const dbAdminUser = process.env.POSTGRES_ADMIN_USER ?? process.env.DB_ADMIN_USER ?? process.env.DB_USER ?? "";
    const dbAdminPassword = process.env.POSTGRES_ADMIN_PASSWORD ?? process.env.DB_ADMIN_PASSWORD ?? process.env.DB_PASSWORD ?? "";
    const dbNamePrefix = process.env.DB_NAME_PREFIX ?? "db_";
    return {
        spec: {
            serviceAccountName: "backup-runner",
            restartPolicy: "OnFailure",
            volumes: [
                {
                    name: "backups",
                    hostPath: {
                        path: "/backups",
                        type: "DirectoryOrCreate"
                    }
                },
                {
                    name: "script",
                    configMap: {
                        name: "backup-runner-script",
                        defaultMode: 0o755
                    }
                }
            ],
            containers: [
                {
                    name: "backup-runner",
                    image: runnerImage,
                    imagePullPolicy: "IfNotPresent",
                    command: ["/app/run.sh"],
                    env: [
                        { name: "SITE_SLUG", value: options.slug },
                        { name: "USER_NAMESPACE", value: options.namespace },
                        { name: "BACKUP_RETENTION_DAYS", value: String(options.retentionDays) },
                        { name: "DB_ENABLED", value: options.dbEnabled ? "true" : "false" },
                        { name: "DB_HOST", value: dbHost },
                        { name: "DB_PORT", value: dbPort },
                        { name: "DB_ADMIN_USER", value: dbAdminUser },
                        { name: "DB_ADMIN_PASSWORD", value: dbAdminPassword },
                        { name: "DB_NAME_PREFIX", value: dbNamePrefix }
                    ],
                    volumeMounts: [
                        { name: "backups", mountPath: "/backups" },
                        { name: "script", mountPath: "/app/run.sh", subPath: "run.sh" }
                    ]
                }
            ]
        }
    };
}
async function upsertBackupCronJob(options) {
    const { batch } = getClients();
    const name = `backup-${options.slug}`;
    const body = {
        apiVersion: "batch/v1",
        kind: "CronJob",
        metadata: {
            name,
            namespace: BACKUP_NAMESPACE,
            labels: {
                [LABELS.managedBy]: LABELS.managedBy,
                [LABELS.siteSlug]: options.slug
            }
        },
        spec: {
            schedule: options.schedule,
            concurrencyPolicy: "Forbid",
            successfulJobsHistoryLimit: 3,
            failedJobsHistoryLimit: 3,
            jobTemplate: {
                spec: {
                    backoffLimit: 1,
                    template: {
                        metadata: {
                            labels: {
                                [LABELS.managedBy]: LABELS.managedBy,
                                [LABELS.siteSlug]: options.slug
                            }
                        },
                        ...buildBackupRunnerPodSpec(options)
                    }
                }
            }
        }
    };
    try {
        await batch.readNamespacedCronJob(name, BACKUP_NAMESPACE);
        await batch.replaceNamespacedCronJob(name, BACKUP_NAMESPACE, body);
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            await batch.createNamespacedCronJob(BACKUP_NAMESPACE, body);
            return;
        }
        throw error;
    }
}
async function deleteBackupCronJob(slug) {
    const { batch } = getClients();
    const name = `backup-${slug}`;
    try {
        await batch.deleteNamespacedCronJob(name, BACKUP_NAMESPACE);
    }
    catch (error) {
        if (error?.response?.statusCode === 404)
            return;
        throw error;
    }
}
async function createBackupJob(options) {
    const { batch } = getClients();
    const timestamp = Date.now();
    const name = `backup-run-${options.slug}-${timestamp}`;
    const body = {
        apiVersion: "batch/v1",
        kind: "Job",
        metadata: {
            name,
            namespace: BACKUP_NAMESPACE,
            labels: {
                [LABELS.managedBy]: LABELS.managedBy,
                [LABELS.siteSlug]: options.slug
            }
        },
        spec: {
            backoffLimit: 1,
            template: {
                metadata: {
                    labels: {
                        [LABELS.managedBy]: LABELS.managedBy,
                        [LABELS.siteSlug]: options.slug
                    }
                },
                ...buildBackupRunnerPodSpec(options)
            }
        }
    };
    await batch.createNamespacedJob(BACKUP_NAMESPACE, body);
}
function normalizeMailDomain(value) {
    const normalized = value.trim().toLowerCase().replace(/\.$/, "");
    if (!normalized) {
        throw new HttpError(400, "Domain is required.");
    }
    return normalized;
}
function requireDbHostConfig() {
    const host = process.env.POSTGRES_HOST?.trim() ?? process.env.DB_HOST?.trim();
    const port = process.env.POSTGRES_PORT?.trim() ?? process.env.DB_PORT?.trim() ?? "5432";
    if (!host) {
        throw new HttpError(500, "POSTGRES_HOST must be configured.");
    }
    return { host, port };
}
function decodeSecretValue(value) {
    if (!value)
        return undefined;
    return Buffer.from(value, "base64").toString("utf8");
}
export async function createSite(userId, input) {
    if (!userId) {
        throw new HttpError(400, "userId is required.");
    }
    let baseSlug;
    try {
        baseSlug = slugFromDomain(input.domain);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid domain.");
    }
    const maintenanceImage = resolveMaintenanceImage();
    const maintenancePort = resolveMaintenancePort();
    const tlsEnabled = input.tlsEnabled ?? false;
    const desiredIssuer = input.tlsIssuer ?? DEFAULT_TLS_ISSUER;
    const tlsIssuer = desiredIssuer;
    // Use user namespace instead of creating tenant namespace
    const namespace = `user-${userId}`;
    await requireNamespace(namespace);
    const slug = baseSlug;
    // Store site metadata in namespace annotations
    await patchNamespaceAnnotations(namespace, {
        [`voxeil.io/site-${slug}-domain`]: input.domain,
        [`voxeil.io/site-${slug}-tlsEnabled`]: tlsEnabled ? "true" : "false",
        [`voxeil.io/site-${slug}-tlsIssuer`]: tlsIssuer,
        [`voxeil.io/site-${slug}-image`]: maintenanceImage,
        [`voxeil.io/site-${slug}-containerPort`]: String(maintenancePort),
        [`voxeil.io/site-${slug}-cpu`]: String(input.cpu),
        [`voxeil.io/site-${slug}-ramGi`]: String(input.ramGi),
        [`voxeil.io/site-${slug}-diskGi`]: String(input.diskGi),
        [`voxeil.io/site-${slug}-dbEnabled`]: "false",
        [`voxeil.io/site-${slug}-mailEnabled`]: "false",
        [`voxeil.io/site-${slug}-backupEnabled`]: "false",
        [`voxeil.io/site-${slug}-dnsEnabled`]: "false",
        [`voxeil.io/site-${slug}-githubEnabled`]: "false"
    });
    // Note: ResourceQuota, LimitRange, and NetworkPolicy are already set up for user namespace
    // Sites share the user namespace resources, no need to create separate ones
    // PVC will be handled in MODULE 2 (user home PVC)
    await ensureGhcrPullSecret(namespace, slug);
    const imagePullSecretName = await resolveImagePullSecretName(namespace);
    const host = input.domain.trim();
    if (!host) {
        throw new HttpError(400, "Domain is required.");
    }
    // Extract userId from namespace for labels
    const extractedUserId = extractUserIdFromNamespace(namespace);
    const maintenanceSpec = {
        namespace,
        slug,
        host,
        image: maintenanceImage,
        containerPort: maintenancePort,
        cpu: input.cpu,
        ramGi: input.ramGi,
        tlsEnabled,
        tlsIssuer,
        imagePullSecretName,
        userId: extractedUserId
    };
    // Note: Deployment/Service/Ingress names are now *-<siteSlug> format (handled in publish.js)
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
export async function listSites() {
    const { core } = getClients();
    const response = await core.listNamespace();
    const userNamespaces = (response.body.items || [])
        .filter(ns => ns.metadata?.name?.startsWith("user-"));
    
    const items = [];
    for (const ns of userNamespaces) {
        const namespace = ns.metadata.name;
        const annotations = ns.metadata.annotations || {};
        
        // Find all sites in this namespace by looking for site-*-domain annotations
        const siteSlugs = new Set();
        for (const key of Object.keys(annotations)) {
            const match = key.match(/^voxeil\.io\/site-(.+)-domain$/);
            if (match) {
                siteSlugs.add(match[1]);
            }
        }
        
        // Build site items from annotations
        for (const slug of siteSlugs) {
            const siteAnnotations = {};
            for (const [key, value] of Object.entries(annotations)) {
                if (key.startsWith(`voxeil.io/site-${slug}-`)) {
                    const propName = key.slice(`voxeil.io/site-${slug}-`.length);
                    siteAnnotations[propName] = value;
                }
            }
            
            // Check deployment status to determine if site is ready
            let ready = false;
            try {
                const { apps } = getClients();
                const deploymentName = getDeploymentName(slug);
                const deployment = await apps.readNamespacedDeployment(deploymentName, namespace);
                const status = deployment.body.status;
                ready = status.readyReplicas > 0 && 
                        status.readyReplicas === status.replicas &&
                        status.updatedReplicas === status.replicas;
            } catch (error) {
                // Deployment not found or error reading it - site is not ready
                ready = false;
            }
            
            // Map annotations to site properties
            items.push({
                slug,
                namespace,
                ready,
                domain: siteAnnotations.domain,
                image: siteAnnotations.image,
                containerPort: parseNumberAnnotation(siteAnnotations.containerPort),
                tlsEnabled: parseBooleanAnnotation(siteAnnotations.tlsEnabled) ?? false,
                tlsIssuer: siteAnnotations.tlsIssuer,
                dnsEnabled: parseBooleanAnnotation(siteAnnotations.dnsEnabled) ?? false,
                dnsDomain: siteAnnotations.dnsDomain,
                dnsTarget: siteAnnotations.dnsTarget,
                githubEnabled: parseBooleanAnnotation(siteAnnotations.githubEnabled) ?? false,
                githubRepo: siteAnnotations.githubRepo,
                githubBranch: siteAnnotations.githubBranch,
                githubWorkflow: siteAnnotations.githubWorkflow,
                githubImage: siteAnnotations.githubImage,
                dbEnabled: parseBooleanAnnotation(siteAnnotations.dbEnabled) ?? false,
                dbName: siteAnnotations.dbName,
                dbUser: siteAnnotations.dbUser,
                dbHost: siteAnnotations.dbHost,
                dbPort: parseNumberAnnotation(siteAnnotations.dbPort),
                dbSecret: siteAnnotations.dbSecret,
                mailEnabled: parseBooleanAnnotation(siteAnnotations.mailEnabled) ?? false,
                mailDomain: siteAnnotations.mailDomain,
                backupEnabled: parseBooleanAnnotation(siteAnnotations.backupEnabled) ?? false,
                backupRetentionDays: parseNumberAnnotation(siteAnnotations.backupRetentionDays),
                backupSchedule: siteAnnotations.backupSchedule,
                backupLastRunAt: siteAnnotations.backupLastRunAt,
                cpu: parseNumberAnnotation(siteAnnotations.cpu),
                ramGi: parseNumberAnnotation(siteAnnotations.ramGi),
                diskGi: parseNumberAnnotation(siteAnnotations.diskGi)
            });
        }
    }
    return items;
}
export async function updateSiteLimits(slug, patch) {
    if (!slug) {
        throw new HttpError(400, "Slug is required.");
    }
    const normalized = validateSlug(slug);
    const namespace = await resolveUserNamespaceForSite(normalized);
    await requireNamespace(namespace);
    
    // Read current site metadata
    const siteData = await readUserNamespaceSite(namespace, normalized);
    const currentCpu = parseNumberAnnotation(siteData.annotations.cpu) ?? 1;
    const currentRamGi = parseNumberAnnotation(siteData.annotations.ramGi) ?? 1;
    const currentDiskGi = parseNumberAnnotation(siteData.annotations.diskGi) ?? 1;
    
    // Calculate updated values
    const updated = {
        cpu: patch.cpu !== undefined ? patch.cpu : currentCpu,
        ramGi: patch.ramGi !== undefined ? patch.ramGi : currentRamGi,
        diskGi: patch.diskGi !== undefined ? patch.diskGi : currentDiskGi
    };
    
    // Update deployment resources if CPU/RAM changed
    if (patch.cpu !== undefined || patch.ramGi !== undefined) {
        const deploymentName = getDeploymentName(normalized);
        const { apps } = getClients();
        try {
            const deployment = await apps.readNamespacedDeployment(deploymentName, namespace);
            const containers = deployment.body.spec?.template?.spec?.containers || [];
            for (const container of containers) {
                if (container.resources) {
                    container.resources.requests = {
                        cpu: String(updated.cpu),
                        memory: `${updated.ramGi}Gi`
                    };
                    container.resources.limits = {
                        cpu: String(updated.cpu),
                        memory: `${updated.ramGi}Gi`
                    };
                }
            }
            await apps.replaceNamespacedDeployment(deploymentName, namespace, deployment.body);
        } catch (error) {
            if (error?.response?.statusCode !== 404) {
                throw error;
            }
            // Deployment not found, skip resource update
        }
    }
    
    // Note: diskGi is per-site but PVC is user-level (pvc-user-home)
    // Site files are stored in /home/sites/<slug> subPath
    // PVC expansion should be handled at user level, not site level
    
    // Update annotations
    await patchNamespaceAnnotations(namespace, {
        [`voxeil.io/site-${normalized}-cpu`]: String(updated.cpu),
        [`voxeil.io/site-${normalized}-ramGi`]: String(updated.ramGi),
        [`voxeil.io/site-${normalized}-diskGi`]: String(updated.diskGi)
    });
    
    return {
        slug: normalized,
        namespace,
        limits: {
            cpu: updated.cpu,
            ramGi: updated.ramGi,
            diskGi: updated.diskGi,
            pods: 1
        }
    };
}
export async function deploySite(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespace = await resolveUserNamespaceForSite(normalized);
    await requireNamespace(namespace);
    await ensureGhcrPullSecret(namespace, normalized);
    const imagePullSecretName = await resolveImagePullSecretName(namespace);
    
    // Read current site metadata for limits
    const siteData = await readUserNamespaceSite(namespace, normalized);
    const cpu = parseNumberAnnotation(siteData.annotations.cpu) ?? 1;
    const ramGi = parseNumberAnnotation(siteData.annotations.ramGi) ?? 1;
    const userId = extractUserIdFromNamespace(namespace);
    // Get domain from site metadata for host (if available)
    const host = siteData.annotations.domain?.trim() || "";
    
    const spec = {
        namespace,
        slug: normalized,
        host,
        image: input.image,
        containerPort: input.containerPort,
        cpu,
        ramGi,
        imagePullSecretName,
        uploadDirs: input.uploadDirs,
        userId
    };
    await Promise.all([
        upsertDeployment(buildDeployment(spec)),
        upsertService(buildService(spec))
    ]);
    await patchNamespaceAnnotations(namespace, {
        [`voxeil.io/site-${normalized}-image`]: input.image,
        [`voxeil.io/site-${normalized}-containerPort`]: String(input.containerPort)
    });
    return {
        slug: normalized,
        namespace,
        image: input.image,
        containerPort: input.containerPort
    };
}
export async function deleteSite(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespace = await resolveUserNamespaceForSite(normalized);
    
    // Delete all site resources by label selector
    const { core, apps, net } = getClients();
    const labelSelector = `${LABELS.managedBy}=${LABELS.managedBy},${LABELS.siteSlug}=${normalized}`;
    
    // Delete deployment
    const deploymentName = getDeploymentName(normalized);
    try {
        await apps.deleteNamespacedDeployment(deploymentName, namespace);
    } catch (error) {
        if (error?.response?.statusCode !== 404) throw error;
    }
    
    // Delete service
    const serviceName = getServiceName(normalized);
    try {
        await core.deleteNamespacedService(serviceName, namespace);
    } catch (error) {
        if (error?.response?.statusCode !== 404) throw error;
    }
    
    // Delete ingress
    const ingressName = getIngressName(normalized);
    try {
        await net.deleteNamespacedIngress(ingressName, namespace);
    } catch (error) {
        if (error?.response?.statusCode !== 404) throw error;
    }
    
    // Delete secrets with site label
    try {
        const secrets = await core.listNamespacedSecret(namespace, undefined, undefined, undefined, undefined, labelSelector);
        for (const secret of secrets.body.items || []) {
            try {
                await core.deleteNamespacedSecret(secret.metadata.name, namespace);
            } catch (error) {
                if (error?.response?.statusCode !== 404) throw error;
            }
        }
    } catch (error) {
        // Ignore errors when listing secrets
    }
    
    // Delete configmaps with site label
    try {
        const configmaps = await core.listNamespacedConfigMap(namespace, undefined, undefined, undefined, undefined, labelSelector);
        for (const cm of configmaps.body.items || []) {
            try {
                await core.deleteNamespacedConfigMap(cm.metadata.name, namespace);
            } catch (error) {
                if (error?.response?.statusCode !== 404) throw error;
            }
        }
    } catch (error) {
        // Ignore errors when listing configmaps
    }
    
    // Remove site annotations from namespace
    const annotationsToRemove = {};
    const siteData = await readUserNamespaceSite(namespace, normalized);
    for (const key of Object.keys(siteData.annotations)) {
        if (key.startsWith(`voxeil.io/site-${normalized}-`)) {
            annotationsToRemove[key] = null; // Set to null to remove
        }
    }
    if (Object.keys(annotationsToRemove).length > 0) {
        await patchNamespaceAnnotations(namespace, annotationsToRemove);
    }
    
    return { slug: normalized };
}
export async function updateSiteTls(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const host = namespaceEntry.annotations.domain?.trim();
    if (!host) {
        throw new HttpError(500, "Site domain is missing.");
    }
    const previousIssuer = namespaceEntry.annotations.tlsIssuer ?? DEFAULT_TLS_ISSUER;
    const desiredIssuer = input.issuer ?? previousIssuer;
    const tlsEnabled = input.enabled;
    const issuer = tlsEnabled
        ? await resolveIngressIssuer(namespace, normalized, desiredIssuer)
        : desiredIssuer;
    await patchNamespaceAnnotations(namespace, {
        [`voxeil.io/site-${normalized}-tlsEnabled`]: tlsEnabled ? "true" : "false",
        [`voxeil.io/site-${normalized}-tlsIssuer`]: issuer
    });
    if (!tlsEnabled && input.cleanupSecret) {
        await deleteSecret(namespace, `tls-${normalized}`);
    }
    const { getIngressName } = await import("../k8s/publish.js");
    const ingressName = getIngressName(normalized);
    await patchIngress(ingressName, namespace, {
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
export async function enableSiteMail(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const domain = normalizeMailDomain(input.domain);
    const siteDomain = normalizeMailDomain(namespaceEntry.annotations.domain ?? "");
    if (!siteDomain) {
        throw new HttpError(500, "Site domain is missing.");
    }
    if (domain !== siteDomain) {
        throw new HttpError(400, "Mail domain must match site domain.");
    }
    try {
        await ensureMailcowDomain(domain);
        await setMailcowDomainActive(domain, true);
        await patchNamespaceAnnotations(namespace, {
            [`voxeil.io/site-${normalized}-mailEnabled`]: "true",
            [`voxeil.io/site-${normalized}-mailProvider`]: "mailcow",
            [`voxeil.io/site-${normalized}-mailDomain`]: domain,
            [`voxeil.io/site-${normalized}-mailStatus`]: "ready",
            [`voxeil.io/site-${normalized}-mailLastError`]: ""
        });
    }
    catch (error) {
        const message = String(error?.message ?? "Mailcow error.");
        await patchNamespaceAnnotations(namespace, {
            [`voxeil.io/site-${normalized}-mailStatus`]: "error",
            [`voxeil.io/site-${normalized}-mailLastError`]: message
        });
        throw new HttpError(502, "Mail provider error.");
    }
    return {
        ok: true,
        slug: normalized,
        domain,
        mailEnabled: true,
        provider: "mailcow"
    };
}
export async function enableSiteDb(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    const { host, port } = requireDbHostConfig();
    // readSiteMetadata returns annotations in new format (voxeil.io/site-{slug}-{prop})
    const existingDbName = annotations.dbName;
    const existingDbUser = annotations.dbUser;
    const dbName = input?.dbName
        ? normalizeDbName(input.dbName)
        : existingDbName
            ? normalizeDbName(existingDbName)
            : resolveDbName(normalized);
    const dbUser = existingDbUser ? normalizeDbUser(existingDbUser) : resolveDbUser(normalized);
    const existingSecret = (await readSecret(namespace, SITE_DB_SECRET_NAME)) ??
        (await readSecret(namespace, LEGACY_DB_SECRET_NAME));
    const existingPassword = decodeSecretValue(existingSecret?.data?.password ?? existingSecret?.data?.DB_PASSWORD);
    let dbPassword = existingPassword;
    if (!dbPassword) {
        dbPassword = generateDbPassword();
    }
    await ensureRole(dbUser, dbPassword);
    await ensureDatabase(dbName, dbUser);
    const encodedUser = encodeURIComponent(dbUser);
    const encodedPassword = encodeURIComponent(dbPassword);
    const databaseUrl = `postgres://${encodedUser}:${encodedPassword}@${host}:${port}/${dbName}`;
    await upsertSecret({
        apiVersion: "v1",
        kind: "Secret",
        metadata: {
            name: SITE_DB_SECRET_NAME,
            namespace,
            labels: {
                [LABELS.managedBy]: LABELS.managedBy,
                [LABELS.siteSlug]: normalized
            }
        },
        type: "Opaque",
        stringData: {
            host,
            port,
            database: dbName,
            username: dbUser,
            password: dbPassword,
            url: databaseUrl
        }
    });
    // Validate secret was created successfully
    const createdSecret = await readSecret(namespace, SITE_DB_SECRET_NAME);
    if (!createdSecret) {
        // Rollback: delete DB and user if secret creation failed
        try {
            await revokeAndTerminate(dbName);
            await dropDatabase(dbName);
            await dropRole(dbUser);
        }
        catch (rollbackError) {
            // Log rollback error but don't throw (original error is more important)
            console.error("Failed to rollback DB resources after secret creation failure:", rollbackError);
        }
        throw new HttpError(500, "Failed to create DB secret in tenant namespace.");
    }
    // Validate secret content matches expected values
    const secretDbName = decodeSecretValue(createdSecret.data?.database);
    const secretDbUser = decodeSecretValue(createdSecret.data?.username);
    if (secretDbName !== dbName || secretDbUser !== dbUser) {
        // Rollback: delete DB and user if secret content is wrong
        try {
            await revokeAndTerminate(dbName);
            await dropDatabase(dbName);
            await dropRole(dbUser);
            await deleteSecret(namespace, SITE_DB_SECRET_NAME);
        }
        catch (rollbackError) {
            console.error("Failed to rollback DB resources after secret content mismatch:", rollbackError);
        }
        throw new HttpError(500, "DB secret content mismatch. Expected dbName/user do not match secret values.");
    }
    await patchNamespaceAnnotations(namespace, {
        [`voxeil.io/site-${normalized}-dbEnabled`]: "true",
        [`voxeil.io/site-${normalized}-dbName`]: dbName,
        [`voxeil.io/site-${normalized}-dbUser`]: dbUser,
        [`voxeil.io/site-${normalized}-dbHost`]: host,
        [`voxeil.io/site-${normalized}-dbPort`]: port,
        [`voxeil.io/site-${normalized}-dbSecret`]: SITE_DB_SECRET_NAME
    });
    return {
        ok: true,
        slug: normalized,
        dbEnabled: true,
        dbName,
        username: dbUser
    };
}
export async function disableSiteDb(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    // readSiteMetadata returns annotations in new format (voxeil.io/site-{slug}-{prop})
    const secretName = annotations.dbSecret;
    const secretNames = new Set([SITE_DB_SECRET_NAME, LEGACY_DB_SECRET_NAME, secretName].filter(Boolean));
    await Promise.all(Array.from(secretNames).map((name) => deleteSecret(namespace, name)));
    await patchNamespaceAnnotations(namespace, {
        [`voxeil.io/site-${normalized}-dbEnabled`]: "false",
        [`voxeil.io/site-${normalized}-dbSecret`]: ""
    });
    return { ok: true, slug: normalized, dbEnabled: false };
}
export async function purgeSiteDb(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    // readSiteMetadata returns annotations in new format (voxeil.io/site-{slug}-{prop})
    const dbName = annotations.dbName
        ? normalizeDbName(annotations.dbName ?? "")
        : resolveDbName(normalized);
    const dbUser = annotations.dbUser
        ? normalizeDbUser(annotations.dbUser ?? "")
        : resolveDbUser(normalized);
    await revokeAndTerminate(dbName);
    await dropDatabase(dbName);
    await dropRole(dbUser);
    const secretName = annotations.dbSecret;
    const secretNames = new Set([SITE_DB_SECRET_NAME, LEGACY_DB_SECRET_NAME, secretName].filter(Boolean));
    await Promise.all(Array.from(secretNames).map((name) => deleteSecret(namespace, name)));
    await patchNamespaceAnnotations(namespace, {
        [`voxeil.io/site-${normalized}-dbEnabled`]: "false",
        [`voxeil.io/site-${normalized}-dbName`]: "",
        [`voxeil.io/site-${normalized}-dbUser`]: "",
        [`voxeil.io/site-${normalized}-dbHost`]: "",
        [`voxeil.io/site-${normalized}-dbPort`]: "",
        [`voxeil.io/site-${normalized}-dbSecret`]: ""
    });
    return { ok: true, slug: normalized, purged: true };
}
export async function getSiteDbStatus(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    // readSiteMetadata returns annotations in new format (voxeil.io/site-{slug}-{prop})
    const secretName = annotations.dbSecret?.trim() || SITE_DB_SECRET_NAME;
    const secret = (await readSecret(namespaceEntry.name, secretName)) ??
        (await readSecret(namespaceEntry.name, LEGACY_DB_SECRET_NAME));
    const dbEnabled = parseBooleanAnnotation(annotations.dbEnabled) ?? false;
    const dbName = annotations.dbName;
    const dbUser = annotations.dbUser;
    return {
        ok: true,
        slug: normalized,
        dbEnabled,
        dbName,
        username: dbUser,
        secretPresent: Boolean(secret)
    };
}
export async function disableSiteMail(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    const domain = annotations.mailDomain?.trim();
    if (!domain) {
        throw new HttpError(409, "Mail domain not configured.");
    }
    try {
        await setMailcowDomainActive(domain, false);
        await patchNamespaceAnnotations(namespace, {
            [`voxeil.io/site-${normalized}-mailEnabled`]: "false",
            [`voxeil.io/site-${normalized}-mailStatus`]: "disabled",
            [`voxeil.io/site-${normalized}-mailLastError`]: ""
        });
    }
    catch (error) {
        const message = String(error?.message ?? "Mailcow error.");
        await patchNamespaceAnnotations(namespace, {
            [`voxeil.io/site-${normalized}-mailStatus`]: "error",
            [`voxeil.io/site-${normalized}-mailLastError`]: message
        });
        throw new HttpError(502, "Mail provider error.");
    }
    return { ok: true, slug: normalized, mailEnabled: false, domain, provider: "mailcow" };
}
export async function purgeSiteMail(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    const domain = annotations.mailDomain?.trim() ??
        annotations.domain?.trim();
    if (!domain) {
        throw new HttpError(409, "Mail domain not configured.");
    }
    try {
        await purgeMailcowDomain(domain);
        await patchNamespaceAnnotations(namespace, {
            [`voxeil.io/site-${normalized}-mailEnabled`]: "false",
            [`voxeil.io/site-${normalized}-mailStatus`]: "purged",
            [`voxeil.io/site-${normalized}-mailLastError`]: "",
            [`voxeil.io/site-${normalized}-mailDomain`]: domain
        });
    }
    catch (error) {
        const message = String(error?.message ?? "Mailcow error.");
        await patchNamespaceAnnotations(namespace, {
            [`voxeil.io/site-${normalized}-mailStatus`]: "error",
            [`voxeil.io/site-${normalized}-mailLastError`]: message
        });
        throw new HttpError(502, "Mail provider error.");
    }
    return {
        ok: true,
        slug: normalized,
        mailEnabled: false,
        domain,
        purged: true,
        provider: "mailcow"
    };
}
export async function createSiteMailbox(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    const domain = annotations.mailDomain?.trim();
    const mailEnabled = parseBooleanAnnotation(annotations.mailEnabled) ?? false;
    if (!domain) {
        throw new HttpError(409, "Mail domain not configured.");
    }
    if (!mailEnabled) {
        throw new HttpError(409, "Mail is disabled for this site.");
    }
    const address = await createMailcowMailbox({
        domain,
        localPart: input.localPart,
        password: input.password,
        quotaMb: input.quotaMb
    });
    return { ok: true, slug: normalized, address };
}
export async function deleteSiteMailbox(slug, address) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    const domain = annotations.mailDomain?.trim();
    const mailEnabled = parseBooleanAnnotation(annotations.mailEnabled) ?? false;
    if (!domain) {
        throw new HttpError(409, "Mail domain not configured.");
    }
    if (!mailEnabled) {
        throw new HttpError(409, "Mail is disabled for this site.");
    }
    const normalizedAddress = address.trim().toLowerCase();
    if (!normalizedAddress.endsWith(`@${domain.toLowerCase()}`)) {
        throw new HttpError(400, "Address must match the site mail domain.");
    }
    await deleteMailcowMailbox(normalizedAddress);
    return { ok: true, slug: normalized, address: normalizedAddress };
}
export async function listSiteMailboxes(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    const domain = annotations.mailDomain?.trim();
    const mailEnabled = parseBooleanAnnotation(annotations.mailEnabled) ?? false;
    if (!domain) {
        throw new HttpError(409, "Mail domain not configured.");
    }
    if (!mailEnabled) {
        throw new HttpError(409, "Mail is disabled for this site.");
    }
    const mailboxes = await listMailcowMailboxes(domain);
    return { ok: true, slug: normalized, domain, mailboxes };
}
export async function listSiteAliases(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    const domain = annotations.mailDomain?.trim();
    const mailEnabled = parseBooleanAnnotation(annotations.mailEnabled) ?? false;
    if (!domain) {
        throw new HttpError(409, "Mail domain not configured.");
    }
    if (!mailEnabled) {
        throw new HttpError(409, "Mail is disabled for this site.");
    }
    const aliases = await listMailcowAliases(domain);
    return { ok: true, slug: normalized, domain, aliases };
}
export async function createSiteAlias(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    const domain = annotations.mailDomain?.trim();
    const mailEnabled = parseBooleanAnnotation(annotations.mailEnabled) ?? false;
    if (!domain) {
        throw new HttpError(409, "Mail domain not configured.");
    }
    if (!mailEnabled) {
        throw new HttpError(409, "Mail is disabled for this site.");
    }
    const sourceLocalPart = input.sourceLocalPart.trim();
    if (!sourceLocalPart) {
        throw new HttpError(400, "sourceLocalPart is required.");
    }
    const source = `${sourceLocalPart}@${domain}`.toLowerCase();
    await createMailcowAlias({
        sourceAddress: source,
        destinationAddress: input.destination,
        active: input.active
    });
    return { ok: true, slug: normalized, source };
}
export async function deleteSiteAlias(slug, source) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    const domain = annotations.mailDomain?.trim();
    const mailEnabled = parseBooleanAnnotation(annotations.mailEnabled) ?? false;
    if (!domain) {
        throw new HttpError(409, "Mail domain not configured.");
    }
    if (!mailEnabled) {
        throw new HttpError(409, "Mail is disabled for this site.");
    }
    const normalizedSource = source.trim().toLowerCase();
    if (!normalizedSource.endsWith(`@${domain.toLowerCase()}`)) {
        throw new HttpError(400, "Alias source must match the site mail domain.");
    }
    await deleteMailcowAlias(normalizedSource);
    return { ok: true, slug: normalized, source: normalizedSource };
}
export async function getSiteMailStatus(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    const domain = annotations.mailDomain?.trim();
    const mailEnabled = parseBooleanAnnotation(annotations.mailEnabled) ?? false;
    if (!domain) {
        throw new HttpError(409, "Mail domain not configured.");
    }
    const activeInMailcow = await getMailcowDomainActive(domain);
    return { ok: true, slug: normalized, domain, mailEnabled, activeInMailcow };
}
export async function enableSiteDns(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const domain = input.domain.trim();
    const targetIp = input.targetIp.trim();
    if (!domain || !targetIp) {
        throw new HttpError(400, "domain and targetIp are required.");
    }
    await ensureDnsZone({ domain, targetIp });
    await patchNamespaceAnnotations(namespace, {
        [`voxeil.io/site-${normalized}-dnsEnabled`]: "true",
        [`voxeil.io/site-${normalized}-dnsDomain`]: domain,
        [`voxeil.io/site-${normalized}-dnsTarget`]: targetIp
    });
    return { ok: true, slug: normalized, dnsEnabled: true, domain, targetIp };
}
export async function disableSiteDns(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    const domain = annotations.dnsDomain?.trim();
    const targetIp = annotations.dnsTarget?.trim();
    if (!domain) {
        throw new HttpError(409, "DNS domain not configured.");
    }
    await removeDnsZone(domain);
    await patchNamespaceAnnotations(namespace, {
        [`voxeil.io/site-${normalized}-dnsEnabled`]: "false"
    });
    return { ok: true, slug: normalized, dnsEnabled: false, domain, targetIp };
}
export async function purgeSiteDns(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    const domain = annotations.dnsDomain?.trim();
    if (domain) {
        await removeDnsZone(domain);
    }
    await patchNamespaceAnnotations(namespace, {
        [`voxeil.io/site-${normalized}-dnsEnabled`]: "false",
        [`voxeil.io/site-${normalized}-dnsDomain`]: "",
        [`voxeil.io/site-${normalized}-dnsTarget`]: ""
    });
    return { ok: true, slug: normalized, dnsEnabled: false, purged: true };
}
export async function getSiteDnsStatus(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    const dnsEnabled = parseBooleanAnnotation(annotations.dnsEnabled) ?? false;
    const domain = annotations.dnsDomain;
    const targetIp = annotations.dnsTarget;
    return { ok: true, slug: normalized, dnsEnabled, domain, targetIp };
}
export async function enableSiteGithub(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const repoInfo = parseRepo(input.repo);
    const branch = input.branch?.trim() || "main";
    const workflow = resolveWorkflow(input.workflow);
    const image = input.image.trim();
    const token = input.token.trim();
    const webhookSecret = input.webhookSecret?.trim();
    if (!image || !token) {
        throw new HttpError(400, "image and token are required.");
    }
    await upsertSecret({
        apiVersion: "v1",
        kind: "Secret",
        metadata: {
            name: GITHUB_SECRET_NAME,
            namespace,
            labels: {
                [LABELS.managedBy]: LABELS.managedBy,
                [LABELS.siteSlug]: normalized
            }
        },
        type: "Opaque",
        stringData: {
            token,
            ...(webhookSecret ? { webhookSecret } : {})
        }
    });
    const repo = `${repoInfo.owner}/${repoInfo.repo}`;
    await patchNamespaceAnnotations(namespace, {
        [SITE_ANNOTATIONS.githubEnabled]: "true",
        [SITE_ANNOTATIONS.githubRepo]: repo,
        [SITE_ANNOTATIONS.githubBranch]: branch,
        [SITE_ANNOTATIONS.githubWorkflow]: workflow,
        [SITE_ANNOTATIONS.githubImage]: image
    });
    return {
        ok: true,
        slug: normalized,
        githubEnabled: true,
        repo,
        branch,
        workflow,
        image
    };
}
export async function disableSiteGithub(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    await deleteSecret(namespace, GITHUB_SECRET_NAME);
    await patchNamespaceAnnotations(namespace, {
        [SITE_ANNOTATIONS.githubEnabled]: "false",
        [SITE_ANNOTATIONS.githubRepo]: "",
        [SITE_ANNOTATIONS.githubBranch]: "",
        [SITE_ANNOTATIONS.githubWorkflow]: "",
        [SITE_ANNOTATIONS.githubImage]: ""
    });
    return { ok: true, slug: normalized, githubEnabled: false };
}
export async function triggerSiteGithubDeploy(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    const repoValue = annotations[SITE_ANNOTATIONS.githubRepo]?.trim();
    const branch = annotations[SITE_ANNOTATIONS.githubBranch]?.trim() || "main";
    const workflow = annotations[SITE_ANNOTATIONS.githubWorkflow]?.trim() || resolveWorkflow();
    const image = input.image?.trim() || annotations[SITE_ANNOTATIONS.githubImage]?.trim() || "";
    if (!repoValue || !image) {
        throw new HttpError(409, "GitHub deploy not configured.");
    }
    const secret = (await readSecret(namespace, GITHUB_SECRET_NAME)) ??
        (await readSecret(namespace, `${normalized}-${GITHUB_SECRET_NAME}`));
    const token = secret?.data?.token ? Buffer.from(secret.data.token, "base64").toString("utf8") : "";
    if (!token) {
        throw new HttpError(409, "GitHub token missing.");
    }
    const registryUsername = input.registryUsername?.trim();
    const registryToken = input.registryToken?.trim();
    const registryEmail = input.registryEmail?.trim();
    const registryServer = input.registryServer?.trim() || DEFAULT_REGISTRY_SERVER;
    const wantsRegistry = Boolean(registryUsername || registryToken || registryEmail);
    if (wantsRegistry && (!registryUsername || !registryToken)) {
        throw new HttpError(400, "registryUsername and registryToken are required.");
    }
    if (registryUsername && registryToken) {
        await upsertRegistryPullSecret({
            namespace,
            slug: normalized,
            server: registryServer,
            username: registryUsername,
            token: registryToken,
            email: registryEmail
        });
    }
    const repoInfo = parseRepo(repoValue);
    const ref = input.ref?.trim() || branch;
    await dispatchWorkflow({
        token,
        repo: repoInfo,
        ref,
        workflow,
        inputs: {
            image,
            slug: normalized,
            namespace
        }
    });
    await patchNamespaceAnnotations(namespace, {
        [SITE_ANNOTATIONS.githubImage]: image,
        [SITE_ANNOTATIONS.githubBranch]: ref
    });
    return { ok: true, slug: normalized, dispatched: true, ref, image };
}
export async function getSiteGithubStatus(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    const githubEnabled = parseBooleanAnnotation(annotations[SITE_ANNOTATIONS.githubEnabled]) ?? false;
    return {
        ok: true,
        slug: normalized,
        githubEnabled,
        repo: annotations[SITE_ANNOTATIONS.githubRepo],
        branch: annotations[SITE_ANNOTATIONS.githubBranch],
        workflow: annotations[SITE_ANNOTATIONS.githubWorkflow],
        image: annotations[SITE_ANNOTATIONS.githubImage]
    };
}
async function purgeSiteBackups(slug) {
    const filesDir = path.join(BACKUP_ROOT, slug, "files");
    const dbDir = path.join(BACKUP_ROOT, slug, "db");
    const removeMatching = async (dir, matcher) => {
        try {
            const entries = await fs.readdir(dir, { withFileTypes: true });
            await Promise.all(entries.map(async (entry) => {
                if (!entry.isFile())
                    return;
                if (!matcher(entry.name))
                    return;
                await fs.unlink(path.join(dir, entry.name));
            }));
        }
        catch (error) {
            if (error?.code === "ENOENT")
                return;
            throw error;
        }
    };
    await removeMatching(filesDir, (name) => name.endsWith(".tar.gz") || name.endsWith(".tar.zst"));
    await removeMatching(dbDir, (name) => name.endsWith(".sql.gz"));
}
export async function enableSiteBackup(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    const existingRetentionDays = parseNumberAnnotation(annotations[SITE_ANNOTATIONS.backupRetentionDays]);
    const existingSchedule = annotations[SITE_ANNOTATIONS.backupSchedule];
    const { retentionDays, schedule } = resolveBackupSettings(input, {
        retentionDays: existingRetentionDays,
        schedule: existingSchedule
    });
    const dbEnabled = parseBooleanAnnotation(annotations[SITE_ANNOTATIONS.dbEnabled]) ?? false;
    await upsertBackupCronJob({
        slug: normalized,
        namespace,
        retentionDays,
        schedule,
        dbEnabled
    });
    await patchNamespaceAnnotations(namespace, {
        [SITE_ANNOTATIONS.backupEnabled]: "true",
        [SITE_ANNOTATIONS.backupRetentionDays]: String(retentionDays),
        [SITE_ANNOTATIONS.backupSchedule]: schedule
    });
    return { ok: true, slug: normalized, backupEnabled: true, retentionDays, schedule };
}
export async function disableSiteBackup(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    await deleteBackupCronJob(normalized);
    await patchNamespaceAnnotations(namespace, {
        [SITE_ANNOTATIONS.backupEnabled]: "false"
    });
    return { ok: true, slug: normalized, backupEnabled: false };
}
export async function updateSiteBackupConfig(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    const existingRetentionDays = parseNumberAnnotation(annotations[SITE_ANNOTATIONS.backupRetentionDays]);
    const existingSchedule = annotations[SITE_ANNOTATIONS.backupSchedule];
    const { retentionDays, schedule } = resolveBackupSettings(input, {
        retentionDays: existingRetentionDays,
        schedule: existingSchedule
    });
    await patchNamespaceAnnotations(namespace, {
        [SITE_ANNOTATIONS.backupRetentionDays]: String(retentionDays),
        [SITE_ANNOTATIONS.backupSchedule]: schedule
    });
    const backupEnabled = parseBooleanAnnotation(annotations[SITE_ANNOTATIONS.backupEnabled]) ?? false;
    const dbEnabled = parseBooleanAnnotation(annotations[SITE_ANNOTATIONS.dbEnabled]) ?? false;
    if (backupEnabled) {
        await upsertBackupCronJob({
            slug: normalized,
            namespace,
            retentionDays,
            schedule,
            dbEnabled
        });
    }
    return { ok: true, slug: normalized, retentionDays, schedule };
}
export async function runSiteBackup(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    const backupEnabled = parseBooleanAnnotation(annotations[SITE_ANNOTATIONS.backupEnabled]) ?? false;
    if (!backupEnabled) {
        throw new HttpError(409, "Backups are disabled for this site.");
    }
    const retentionDays = normalizeRetentionDays(parseNumberAnnotation(annotations[SITE_ANNOTATIONS.backupRetentionDays]) ??
        DEFAULT_BACKUP_RETENTION_DAYS);
    const dbEnabled = parseBooleanAnnotation(annotations[SITE_ANNOTATIONS.dbEnabled]) ?? false;
    await createBackupJob({
        slug: normalized,
        namespace,
        retentionDays,
        dbEnabled
    });
    await patchNamespaceAnnotations(namespace, {
        [SITE_ANNOTATIONS.backupLastRunAt]: new Date().toISOString()
    });
    return { ok: true, slug: normalized, started: true };
}
export async function listSiteBackupSnapshots(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const filesDir = path.join(BACKUP_ROOT, normalized, "files");
    const dbDir = path.join(BACKUP_ROOT, normalized, "db");
    const items = new Map();
    const addItem = (id, partial) => {
        const existing = items.get(id) ?? { id, hasFiles: false, hasDb: false, sizeBytes: 0 };
        items.set(id, {
            id,
            hasFiles: existing.hasFiles || Boolean(partial.hasFiles),
            hasDb: existing.hasDb || Boolean(partial.hasDb),
            sizeBytes: existing.sizeBytes + (partial.sizeBytes ?? 0)
        });
    };
    const readDirSafe = async (dir) => {
        try {
            return await fs.readdir(dir, { withFileTypes: true });
        }
        catch (error) {
            if (error?.code === "ENOENT")
                return [];
            throw error;
        }
    };
    const fileEntries = await readDirSafe(filesDir);
    for (const entry of fileEntries) {
        if (!entry.isFile())
            continue;
        const name = entry.name;
        if (name.endsWith(".tar.gz")) {
            const id = name.slice(0, -".tar.gz".length);
            const stat = await fs.stat(path.join(filesDir, name));
            addItem(id, { hasFiles: true, sizeBytes: stat.size });
        }
        else if (name.endsWith(".tar.zst")) {
            const id = name.slice(0, -".tar.zst".length);
            const stat = await fs.stat(path.join(filesDir, name));
            addItem(id, { hasFiles: true, sizeBytes: stat.size });
        }
    }
    const dbEntries = await readDirSafe(dbDir);
    for (const entry of dbEntries) {
        if (!entry.isFile())
            continue;
        const name = entry.name;
        if (!name.endsWith(".sql.gz"))
            continue;
        const id = name.slice(0, -".sql.gz".length);
        const stat = await fs.stat(path.join(dbDir, name));
        addItem(id, { hasDb: true, sizeBytes: stat.size });
    }
    const list = Array.from(items.values()).sort((a, b) => b.id.localeCompare(a.id));
    return { ok: true, slug: normalized, items: list };
}
export async function restoreSiteBackup(slug, input) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const snapshotId = input.snapshotId.trim();
    if (!snapshotId || snapshotId !== path.basename(snapshotId)) {
        throw new HttpError(400, "snapshotId must be a filename-safe value.");
    }
    const restoreFiles = input.restoreFiles ?? true;
    const restoreDb = input.restoreDb ?? true;
    if (!restoreFiles && !restoreDb) {
        throw new HttpError(400, "restoreFiles or restoreDb must be true.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const annotations = namespaceEntry.annotations;
    if (restoreDb) {
        const dbEnabled = parseBooleanAnnotation(annotations[SITE_ANNOTATIONS.dbEnabled]) ?? false;
        if (!dbEnabled) {
            throw new HttpError(409, "Database is not enabled for this site.");
        }
    }
    if (restoreFiles) {
        const filesDir = path.join(BACKUP_ROOT, normalized, "files");
        const tarGz = path.join(filesDir, `${snapshotId}.tar.gz`);
        const tarZst = path.join(filesDir, `${snapshotId}.tar.zst`);
        let archive = `${snapshotId}.tar.gz`;
        try {
            await fs.access(tarGz);
        }
        catch {
            await fs.access(tarZst).catch(() => {
                throw new HttpError(404, "Files backup archive not found.");
            });
            archive = `${snapshotId}.tar.zst`;
        }
        await restoreSiteFiles(normalized, { backupFile: archive });
    }
    if (restoreDb) {
        const dbDir = path.join(BACKUP_ROOT, normalized, "db");
        const archivePath = path.join(dbDir, `${snapshotId}.sql.gz`);
        await fs.access(archivePath).catch(() => {
            throw new HttpError(404, "Database backup archive not found.");
        });
        await restoreSiteDb(normalized, { backupFile: `${snapshotId}.sql.gz` });
    }
    return { ok: true, slug: normalized, restored: true, snapshotId };
}
export async function purgeSiteBackup(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    await deleteBackupCronJob(normalized);
    await purgeSiteBackups(normalized);
    await patchNamespaceAnnotations(namespace, {
        [SITE_ANNOTATIONS.backupEnabled]: "false",
        [SITE_ANNOTATIONS.backupLastRunAt]: ""
    });
    return { ok: true, slug: normalized, purged: true };
}
export async function purgeSite(slug) {
    let normalized;
    try {
        normalized = validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
    const namespaceEntry = await readSiteMetadata(normalized);
    const namespace = namespaceEntry.name;
    const annotations = namespaceEntry.annotations;
    // Delete site resources first (deployment, service, ingress, etc.)
    await deleteSite(normalized);
    // readSiteMetadata returns annotations in new format (voxeil.io/site-{slug}-{prop})
    const dbEnabled = parseBooleanAnnotation(annotations.dbEnabled) ?? false;
    const dbNameAnnotation = annotations.dbName;
    const dbUserAnnotation = annotations.dbUser;
    if (dbEnabled || dbNameAnnotation || dbUserAnnotation) {
        const dbName = dbNameAnnotation ? normalizeDbName(dbNameAnnotation) : resolveDbName(normalized);
        const dbUser = dbUserAnnotation ? normalizeDbUser(dbUserAnnotation) : resolveDbUser(normalized);
        await revokeAndTerminate(dbName);
        await dropDatabase(dbName);
        await dropRole(dbUser);
    }
    const mailEnabled = parseBooleanAnnotation(annotations.mailEnabled) ?? false;
    const mailDomain = annotations.mailDomain?.trim() ??
        annotations.domain?.trim();
    if (mailDomain && (mailEnabled || annotations.mailDomain)) {
        await purgeMailcowDomain(mailDomain);
    }
    await purgeSiteBackups(normalized);
    return { ok: true, slug: normalized, purged: true };
}
