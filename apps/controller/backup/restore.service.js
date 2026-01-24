import { HttpError } from "../http/errors.js";
import { requireNamespace, resolveUserNamespaceForSite } from "../k8s/namespace.js";
import { getClients, LABELS } from "../k8s/client.js";
import { validateSlug } from "../sites/site.slug.js";
import { buildRestorePod } from "./helpers.js";
import { USER_BACKUP_PVC_NAME } from "../k8s/pvc.js";
const POD_WAIT_TIMEOUT_MS = 30 * 60 * 1000;
const POD_POLL_INTERVAL_MS = 2000;
function normalizeSlug(slug) {
    try {
        return validateSlug(slug);
    }
    catch (error) {
        throw new HttpError(400, error?.message ?? "Invalid slug.");
    }
}
async function waitForPodCompletion(namespace, name) {
    const { core } = getClients();
    const started = Date.now();
    // eslint-disable-next-line no-constant-condition
    while (true) {
        const result = await core.readNamespacedPod(name, namespace);
        const phase = result.body.status?.phase;
        if (phase === "Succeeded")
            return;
        if (phase === "Failed") {
            throw new HttpError(500, "Restore pod failed.");
        }
        if (Date.now() - started > POD_WAIT_TIMEOUT_MS) {
            throw new HttpError(504, "Restore pod timed out.");
        }
        await new Promise((resolve) => setTimeout(resolve, POD_POLL_INTERVAL_MS));
    }
}
async function deletePodSafely(namespace, name) {
    const { core } = getClients();
    try {
        await core.deleteNamespacedPod(name, namespace);
    }
    catch (error) {
        if (error?.response?.statusCode === 404)
            return;
        throw error;
    }
}
function requireDbConfig() {
    const host = process.env.DB_HOST;
    const user = process.env.DB_ADMIN_USER ?? process.env.DB_USER;
    const password = process.env.DB_ADMIN_PASSWORD ?? process.env.DB_PASSWORD;
    if (!host || !user || !password) {
        throw new HttpError(409, "DB restore not configured.");
    }
    const port = process.env.DB_PORT?.trim() || "5432";
    return { host, user, password, port };
}
// runDbRestore function removed - now handled in pod
export async function restoreSiteFiles(slug, input) {
    const normalized = normalizeSlug(slug);
    const namespace = await resolveUserNamespaceForSite(normalized);
    await requireNamespace(namespace);
    // Archive name will be validated in the pod
    const archive = input.backupFile || (input.latest ? "latest" : null);
    if (!archive) {
        throw new HttpError(400, "backupFile or latest=true required");
    }
    const podName = `restore-${normalized}-${Date.now()}`;
    const pod = buildRestorePod({
        name: podName,
        namespace,
        slug: normalized,
        archivePath: `/backups/${normalized}/files/${archive}`
    });
    const { core } = getClients();
    await core.createNamespacedPod(namespace, pod);
    try {
        await waitForPodCompletion(namespace, podName);
    }
    finally {
        await deletePodSafely(namespace, podName);
    }
    return { ok: true, slug: normalized, restored: "files", archive };
}
export async function restoreSiteDb(slug, input) {
    const normalized = normalizeSlug(slug);
    const namespace = await resolveUserNamespaceForSite(normalized);
    await requireNamespace(namespace);
    // Archive name will be validated in the pod
    const archive = input.backupFile || (input.latest ? "latest" : null);
    if (!archive) {
        throw new HttpError(400, "backupFile or latest=true required");
    }
    const dbName = `db_${normalized}`;
    
    // Create a pod to restore DB from backup PVC
    const podName = `restore-db-${normalized}-${Date.now()}`;
    const { host, user, password, port } = requireDbConfig();
    const { core } = getClients();
    
    // Handle "latest" by finding the most recent backup file
    const isLatest = archive === "latest";
    const dbDir = `/backups/${normalized}/db`;
    const findLatestCmd = isLatest
        ? `latest_file=$(find "${dbDir}" -type f -name "*.sql.gz" -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-); if [ -z "$latest_file" ]; then echo "No backup found" >&2; exit 1; fi; archive_path="$latest_file"`
        : `archive_path="${dbDir}/${archive}"`;
    
    const pod = {
        apiVersion: "v1",
        kind: "Pod",
        metadata: {
            name: podName,
            namespace,
            labels: {
                [LABELS.managedBy]: LABELS.managedBy,
                [LABELS.siteSlug]: normalized,
                "app.kubernetes.io/name": "restore-db"
            }
        },
        spec: {
            restartPolicy: "Never",
            containers: [
                {
                    name: "restore",
                    image: "postgres:16-alpine",
                    command: ["/bin/sh", "-c"],
                    args: [
                        `${findLatestCmd} && if [ ! -f "$archive_path" ]; then echo "Archive not found: $archive_path" >&2; exit 1; fi && PGPASSWORD='${password.replace(/'/g, "'\"'\"'")}' gunzip -c "$archive_path" | psql -h ${host} -p ${port} -U ${user} ${dbName}`
                    ],
                    env: [
                        { name: "PGPASSWORD", value: password }
                    ],
                    volumeMounts: [
                        {
                            name: "backups",
                            mountPath: "/backups",
                            readOnly: true
                        }
                    ]
                }
            ],
            volumes: [
                {
                    name: "backups",
                    persistentVolumeClaim: {
                        claimName: USER_BACKUP_PVC_NAME
                    }
                }
            ]
        }
    };
    
    await core.createNamespacedPod(namespace, pod);
    try {
        await waitForPodCompletion(namespace, podName);
    }
    finally {
        await deletePodSafely(namespace, podName);
    }
    return { ok: true, slug: normalized, restored: "db", archive };
}
