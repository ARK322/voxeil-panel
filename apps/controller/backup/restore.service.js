import { promises as fs } from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { HttpError } from "../http/errors.js";
import { requireNamespace, resolveUserNamespaceForSite } from "../k8s/namespace.js";
import { getClients } from "../k8s/client.js";
import { validateSlug } from "../sites/site.slug.js";
import { buildRestorePod, listLatestBackup } from "./helpers.js";
const BACKUP_ROOT = "/backups/sites";
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
function ensureFilename(value) {
    const trimmed = value.trim();
    const base = path.basename(trimmed);
    if (!base || base !== trimmed) {
        throw new HttpError(400, "backupFile must be a filename.");
    }
    return base;
}
async function resolveBackupName(dir, backupFile, latest) {
    if (backupFile) {
        return ensureFilename(backupFile);
    }
    if (latest) {
        const found = await listLatestBackup(dir);
        if (!found) {
            throw new HttpError(404, "No backup archives found.");
        }
        return found;
    }
    throw new HttpError(400, "backupFile or latest=true required");
}
async function waitForPodCompletion(namespace, name) {
    const { core } = getClients();
    const started = Date.now();
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
async function runDbRestore(archivePath, dbName) {
    const { host, user, password, port } = requireDbConfig();
    await fs.access(archivePath).catch((error) => {
        if (error?.code === "ENOENT") {
            throw new HttpError(404, "Backup archive not found.");
        }
        throw error;
    });
    await new Promise((resolve, reject) => {
        const gunzip = spawn("gunzip", ["-c", archivePath]);
        const psql = spawn("psql", ["-h", host, "-p", port, "-U", user, dbName], {
            env: { ...process.env, PGPASSWORD: password }
        });
        let gunzipExit = null;
        let psqlExit = null;
        gunzip.stdout.pipe(psql.stdin);
        const handleExit = () => {
            if (gunzipExit == null || psqlExit == null)
                return;
            if (gunzipExit !== 0 || psqlExit !== 0) {
                reject(new HttpError(500, "DB restore failed."));
            }
            else {
                resolve();
            }
        };
        gunzip.on("error", (error) => reject(error));
        psql.on("error", (error) => reject(error));
        gunzip.on("close", (code) => {
            gunzipExit = code ?? 1;
            handleExit();
        });
        psql.on("close", (code) => {
            psqlExit = code ?? 1;
            handleExit();
        });
    });
}
export async function restoreSiteFiles(slug, input) {
    const normalized = normalizeSlug(slug);
    const namespace = await resolveUserNamespaceForSite(normalized);
    await requireNamespace(namespace);
    const dir = path.join(BACKUP_ROOT, normalized, "files");
    const archive = await resolveBackupName(dir, input.backupFile, input.latest);
    await fs.access(path.join(dir, archive)).catch((error) => {
        if (error?.code === "ENOENT") {
            throw new HttpError(404, "Backup archive not found.");
        }
        throw error;
    });
    const podName = `restore-${normalized}-${Date.now()}`;
    const pod = buildRestorePod({
        name: podName,
        namespace,
        slug: normalized,
        archivePath: `/backups/sites/${normalized}/files/${archive}`
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
    const dir = path.join(BACKUP_ROOT, normalized, "db");
    const archive = await resolveBackupName(dir, input.backupFile, input.latest);
    const archivePath = path.join(dir, archive);
    const dbName = `db_${normalized}`;
    await runDbRestore(archivePath, dbName);
    return { ok: true, slug: normalized, restored: "db", archive };
}
