import { z } from "zod";
import { HttpError } from "./errors.js";
import { readAllowlist, writeAllowlist } from "../security/allowlist.js";
import { checkRateLimit, pruneRateLimitStore } from "../security/rate-limit.js";
import { logAudit } from "../audit/audit.service.js";
import { CreateUserSchema, LoginSchema, ToggleUserSchema } from "../users/user.dto.js";
import { createUser, listUsers, setUserActive, deleteUser, verifyUserCredentials, getUserById, updateUserStatus } from "../users/user.service.js";
import { signToken } from "../auth/jwt.js";
import { bootstrapUserNamespace } from "../users/user.bootstrap.js";
import { CreateAppSchema, DeployAppSchema } from "../apps/app.dto.js";
import { listApps, createApp, deployApp } from "../apps/app.service.js";
import { getClients } from "../k8s/client.js";
const AllowlistSchema = z.object({
    items: z.array(z.string().min(1)).default([])
});
const LOGIN_RATE_LIMIT = Number(process.env.LOGIN_RATE_LIMIT ?? "10");
const LOGIN_RATE_WINDOW_SECONDS = Number(process.env.LOGIN_RATE_WINDOW_SECONDS ?? "300");

function requireAdmin(req) {
    if (!req.user) {
        throw new HttpError(401, "Authentication required.");
    }
    if (req.user.role !== "admin") {
        throw new HttpError(403, "Admin access required.");
    }
    return req.user;
}

function requireUser(req) {
    if (!req.user) {
        throw new HttpError(401, "Authentication required.");
    }
    return req.user;
}

function safeAudit(entry) {
    void logAudit(entry).catch(() => undefined);
}

function getClientIp(req) {
    return req.ip ?? null;
}
export function registerRoutes(app) {
    app.post("/auth/login", async (req, reply) => {
        const body = LoginSchema.parse(req.body ?? {});
        pruneRateLimitStore();
        const ip = getClientIp(req);
        const rateKey = `${ip ?? "unknown"}:${body.username}`;
        const limitResult = checkRateLimit(rateKey, {
            limit: Math.max(1, LOGIN_RATE_LIMIT),
            windowMs: Math.max(1, LOGIN_RATE_WINDOW_SECONDS) * 1000
        });
        if (!limitResult.allowed) {
            throw new HttpError(429, "Too many login attempts. Please retry later.");
        }
        let user;
        try {
            user = await verifyUserCredentials(body.username, body.password);
        }
        catch (error) {
            safeAudit({
                action: "auth.login_failed",
                actorUsername: body.username,
                ip,
                success: false,
                error: error?.message ?? "invalid_credentials"
            });
            throw error;
        }
        const token = signToken({
            sub: user.id,
            role: user.role,
            disabled: !user.active
        });
        safeAudit({
            action: "auth.login",
            actorUserId: user.id,
            actorUsername: user.username,
            ip,
            success: true
        });
        return reply.send({ ok: true, token, user });
    });
    app.get("/admin/users", async (req, reply) => {
        requireAdmin(req);
        const users = await listUsers();
        return reply.send({ ok: true, users });
    });
    app.post("/admin/users", async (req, reply) => {
        const actor = requireAdmin(req);
        const body = CreateUserSchema.parse(req.body);
        let user;
        try {
            user = await createUser(body);
            safeAudit({
                action: "users.create",
                actorUserId: actor.sub,
                targetType: "user",
                targetId: user.id,
                ip: getClientIp(req),
                success: true
            });
        } catch (error) {
            safeAudit({
                action: "users.create",
                actorUserId: actor.sub,
                targetType: "user",
                ip: getClientIp(req),
                success: false,
                error: error?.message ?? String(error)
            });
            throw error;
        }
        try {
            await bootstrapUserNamespace(user.id);
            await updateUserStatus(user.id, "active");
            user = await getUserById(user.id);
            safeAudit({
                action: "users.bootstrap",
                actorUserId: actor.sub,
                targetType: "user",
                targetId: user.id,
                ip: getClientIp(req),
                success: true
            });
        } catch (error) {
            await updateUserStatus(user.id, "error");
            safeAudit({
                action: "users.bootstrap",
                actorUserId: actor.sub,
                targetType: "user",
                targetId: user.id,
                ip: getClientIp(req),
                success: false,
                error: error?.message ?? String(error)
            });
            throw new HttpError(500, `User created but namespace bootstrap failed: ${error?.message ?? String(error)}`);
        }
        return reply.send({ ok: true, user });
    });
    app.patch("/admin/users/:id", async (req, reply) => {
        const actor = requireAdmin(req);
        const id = String(req.params.id ?? "");
        if (!id)
            throw new HttpError(400, "User id is required.");
        const body = ToggleUserSchema.parse(req.body ?? {});
        const user = await setUserActive(id, body.active);
        safeAudit({
            action: "users.toggle",
            actorUserId: actor.sub,
            targetType: "user",
            targetId: user.id,
            ip: getClientIp(req),
            success: true
        });
        return reply.send({ ok: true, user });
    });
    app.delete("/admin/users/:id", async (req, reply) => {
        const actor = requireAdmin(req);
        const id = String(req.params.id ?? "");
        if (!id)
            throw new HttpError(400, "User id is required.");
        await deleteUser(id);
        safeAudit({
            action: "users.delete",
            actorUserId: actor.sub,
            targetType: "user",
            targetId: id,
            ip: getClientIp(req),
            success: true
        });
        return reply.send({ ok: true });
    });
    app.get("/admin/security/allowlist", async (req, reply) => {
        requireAdmin(req);
        const items = await readAllowlist();
        return reply.send({ ok: true, items });
    });
    app.put("/admin/security/allowlist", async (req, reply) => {
        const actor = requireAdmin(req);
        const body = AllowlistSchema.parse(req.body ?? {});
        const items = await writeAllowlist(body.items);
        safeAudit({
            action: "security.allowlist.update",
            actorUserId: actor.sub,
            targetType: "allowlist",
            ip: getClientIp(req),
            success: true
        });
        return reply.send({ ok: true, items });
    });
    // Apps endpoints
    app.get("/apps", async (req, reply) => {
        const user = requireUser(req);
        const apps = await listApps(user.sub);
        return reply.send({ ok: true, apps });
    });

    app.post("/apps", async (req, reply) => {
        const user = requireUser(req);
        const body = CreateAppSchema.parse(req.body);
        let app;
        try {
            app = await createApp(user.sub, body);
            safeAudit({
                action: "apps.create",
                actorUserId: user.sub,
                targetType: "app",
                targetId: app.id,
                ip: getClientIp(req),
                success: true
            });
        } catch (error) {
            safeAudit({
                action: "apps.create",
                actorUserId: user.sub,
                targetType: "app",
                ip: getClientIp(req),
                success: false,
                error: error?.message ?? String(error)
            });
            throw error;
        }
        return reply.send({ ok: true, app });
    });

    app.post("/apps/:id/deploy", async (req, reply) => {
        const user = requireUser(req);
        const appId = String(req.params.id ?? "");
        if (!appId) {
            throw new HttpError(400, "App id is required.");
        }
        const body = DeployAppSchema.parse(req.body ?? {});
        let result;
        try {
            result = await deployApp(appId, user.sub, body);
            safeAudit({
                action: "apps.deploy",
                actorUserId: user.sub,
                targetType: "app",
                targetId: appId,
                ip: getClientIp(req),
                success: true
            });
        } catch (error) {
            safeAudit({
                action: "apps.deploy",
                actorUserId: user.sub,
                targetType: "app",
                targetId: appId,
                ip: getClientIp(req),
                success: false,
                error: error?.message ?? String(error)
            });
            throw error;
        }
        return reply.send({ ok: true, ...result });
    });
}
        const slug = String(req.params.slug ?? "");
        const body = PatchLimitsSchema.parse(req.body);
        const result = await updateSiteLimits(slug, body);
        safeAudit({
            action: "sites.limits.update",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/deploy", async (req, reply) => {
        const slug = String(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = DeploySiteSchema.parse(req.body);
        const result = await deploySite(slug, body);
        safeAudit({
            action: "sites.deploy",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.get("/sites/:slug/logs/stream", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        requireAdmin(req);
        const namespace = `tenant-${slug}`;
        const query = req.query;
        const container = query.container?.trim() || "app";
        const tailLines = Number.parseInt(query.tailLines ?? "", 10);
        const resolvedTailLines = Number.isFinite(tailLines) && tailLines > 0 ? tailLines : 200;
        const podName = await resolveSitePodName(namespace);
        const stream = new PassThrough();
        reply.header("Content-Type", "text/plain; charset=utf-8");
        reply.header("Cache-Control", "no-cache");
        reply.send(stream);
        const log = new k8s.Log(getClients().kc);
        void log
            .log(namespace, podName, container, stream, {
            follow: true,
            tailLines: resolvedTailLines,
            timestamps: true
        })
            .catch((error) => {
            stream.write(`\n[log stream error] ${error?.message ?? String(error)}\n`);
            stream.end();
        });
        req.raw.on("close", () => stream.end());
    });
    app.patch("/sites/:slug/tls", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = PatchTlsSchema.parse(req.body);
        const result = await updateSiteTls(slug, body);
        safeAudit({
            action: "sites.tls.update",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/mail/enable", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = MailEnableSchema.parse(req.body);
        const result = await enableSiteMail(slug, body);
        safeAudit({
            action: "sites.mail.enable",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { domain: body.domain },
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/dns/enable", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = DnsEnableSchema.parse(req.body);
        const result = await enableSiteDns(slug, body);
        safeAudit({
            action: "sites.dns.enable",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { domain: body.domain, targetIp: body.targetIp },
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/github/enable", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = GithubEnableSchema.parse(req.body);
        const result = await enableSiteGithub(slug, body);
        safeAudit({
            action: "sites.github.enable",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: {
                repo: body.repo,
                branch: body.branch ?? null,
                workflow: body.workflow ?? null,
                image: body.image
            },
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/db/enable", async (req, reply) => {
        const slug = String(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = DbEnableSchema.parse(req.body ?? {});
        const result = await enableSiteDb(slug, body);
        safeAudit({
            action: "sites.db.enable",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { dbName: body.dbName ?? null },
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/db/disable", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const result = await disableSiteDb(slug);
        safeAudit({
            action: "sites.db.disable",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/db/purge", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        requireConfirmDelete(req.body);
        const result = await purgeSiteDb(slug);
        safeAudit({
            action: "sites.db.purge",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.get("/sites/:slug/db/status", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        requireAdmin(req);
        const result = await getSiteDbStatus(slug);
        return reply.send(result);
    });
    app.post("/sites/:slug/mail/disable", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const result = await disableSiteMail(slug);
        safeAudit({
            action: "sites.mail.disable",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/dns/disable", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const result = await disableSiteDns(slug);
        safeAudit({
            action: "sites.dns.disable",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/github/disable", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const result = await disableSiteGithub(slug);
        safeAudit({
            action: "sites.github.disable",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/mail/purge", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        requireConfirmDelete(req.body);
        const result = await purgeSiteMail(slug);
        safeAudit({
            action: "sites.mail.purge",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/dns/purge", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        requireConfirmDelete(req.body);
        const result = await purgeSiteDns(slug);
        safeAudit({
            action: "sites.dns.purge",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/github/deploy", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = GithubDeploySchema.parse(req.body ?? {});
        const result = await triggerSiteGithubDeploy(slug, body);
        safeAudit({
            action: "sites.github.deploy",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { ref: body.ref ?? null, image: body.image ?? null },
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/mail/mailboxes", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = MailboxCreateSchema.parse(req.body);
        const result = await createSiteMailbox(slug, body);
        safeAudit({
            action: "sites.mail.mailbox.create",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { localPart: body.localPart },
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/mail/aliases", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = AliasCreateSchema.parse(req.body);
        const result = await createSiteAlias(slug, body);
        safeAudit({
            action: "sites.mail.alias.create",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { source: body.sourceLocalPart, destination: body.destination },
            success: true
        });
        return reply.send(result);
    });
    app.delete("/sites/:slug/mail/mailboxes/:address", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const address = String(req.params.address ?? "").trim();
        if (!address) {
            throw new HttpError(400, "Mailbox address is required.");
        }
        const result = await deleteSiteMailbox(slug, address);
        safeAudit({
            action: "sites.mail.mailbox.delete",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { address },
            success: true
        });
        return reply.send(result);
    });
    app.delete("/sites/:slug/mail/aliases/:source", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const source = String(req.params.source ?? "").trim();
        if (!source) {
            throw new HttpError(400, "Alias source is required.");
        }
        const result = await deleteSiteAlias(slug, source);
        safeAudit({
            action: "sites.mail.alias.delete",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { source },
            success: true
        });
        return reply.send(result);
    });
    app.get("/sites/:slug/mail/mailboxes", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        requireAdmin(req);
        const result = await listSiteMailboxes(slug);
        return reply.send(result);
    });
    app.get("/sites/:slug/mail/aliases", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        requireAdmin(req);
        const result = await listSiteAliases(slug);
        return reply.send(result);
    });
    app.get("/sites/:slug/mail/status", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        requireAdmin(req);
        const result = await getSiteMailStatus(slug);
        return reply.send(result);
    });
    app.get("/sites/:slug/dns/status", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        requireAdmin(req);
        const result = await getSiteDnsStatus(slug);
        return reply.send(result);
    });
    app.get("/sites/:slug/github/status", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        requireAdmin(req);
        const result = await getSiteGithubStatus(slug);
        return reply.send(result);
    });
    app.post("/sites/:slug/backup/enable", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = BackupEnableSchema.parse(req.body ?? {});
        const result = await enableSiteBackup(slug, body);
        safeAudit({
            action: "sites.backup.enable",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { retentionDays: body.retentionDays ?? null, schedule: body.schedule ?? null },
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/backup/disable", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const result = await disableSiteBackup(slug);
        safeAudit({
            action: "sites.backup.disable",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.patch("/sites/:slug/backup/config", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = BackupConfigSchema.parse(req.body ?? {});
        const result = await updateSiteBackupConfig(slug, body);
        safeAudit({
            action: "sites.backup.config",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { retentionDays: body.retentionDays ?? null, schedule: body.schedule ?? null },
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/backup/run", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const result = await runSiteBackup(slug);
        safeAudit({
            action: "sites.backup.run",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.get("/sites/:slug/backup/snapshots", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        requireAdmin(req);
        const result = await listSiteBackupSnapshots(slug);
        return reply.send(result);
    });
    app.post("/sites/:slug/backup/restore", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = BackupRestoreSchema.parse(req.body ?? {});
        const result = await restoreSiteBackup(slug, body);
        safeAudit({
            action: "sites.backup.restore",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: {
                snapshotId: body.snapshotId,
                restoreFiles: body.restoreFiles ?? false,
                restoreDb: body.restoreDb ?? false
            },
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/backup/purge", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        requireConfirmDelete(req.body);
        const result = await purgeSiteBackup(slug);
        safeAudit({
            action: "sites.backup.purge",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/restore/files", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = RestoreFilesSchema.parse(req.body ?? {});
        const result = await restoreSiteFiles(slug, body);
        safeAudit({
            action: "sites.restore.files",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { backupFile: body.backupFile ?? null, latest: body.latest ?? null, restoreFiles: true },
            success: true
        });
        return reply.send(result);
    });
    app.post("/sites/:slug/restore/db", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const body = RestoreDbSchema.parse(req.body ?? {});
        const result = await restoreSiteDb(slug, body);
        safeAudit({
            action: "sites.restore.db",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            meta: { backupFile: body.backupFile ?? null, latest: body.latest ?? null, restoreDb: true },
            success: true
        });
        return reply.send(result);
    });
    app.delete("/sites/:slug", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        const result = await deleteSite(slug);
        safeAudit({
            action: "sites.delete",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req)
        });
        return reply.code(200).send({ ok: true, slug: result.slug });
    });
    app.post("/sites/:slug/purge", async (req, reply) => {
        const slug = SlugParamSchema.parse(req.params.slug ?? "");
        const actor = requireAdmin(req);
        requireConfirmDelete(req.body);
        const result = await purgeSite(slug);
        safeAudit({
            action: "sites.purge",
            actorUserId: actor.sub,
            targetType: "site",
            targetId: slug,
            ip: getClientIp(req),
            success: true
        });
        return reply.send(result);
    });
}
