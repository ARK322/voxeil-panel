import { z } from "zod";
import { HttpError } from "./errors.js";
import { logger } from "../config/logger.js";
import { parseEnvNumber } from "../config/env.js";
import { readAllowlist, writeAllowlist } from "../security/allowlist.js";
import { checkRateLimit, pruneRateLimitStore } from "../security/rate-limit.js";
import { logAudit } from "../audit/audit.service.js";
import { CreateUserSchema, LoginSchema, ToggleUserSchema } from "../users/user.dto.js";
import { createUser, listUsers, setUserActive, deleteUser, verifyUserCredentials, getUserById, updateUserStatus } from "../users/user.service.js";
import { signToken } from "../auth/jwt.js";
import { revokeTokenJti } from "../auth/token-revocation.service.js";
import { bootstrapUserNamespace } from "../users/user.bootstrap.js";
import { CreateAppSchema, DeployAppSchema } from "../apps/app.dto.js";
import { listApps, createApp, deployApp, getAppByIdWithOwnershipCheck } from "../apps/app.service.js";
import {
    CreateSiteSchema,
    PatchLimitsSchema,
    DeploySiteSchema,
    PatchTlsSchema,
    ConfirmDeleteSchema,
    MailEnableSchema,
    DnsEnableSchema,
    GithubEnableSchema,
    GithubDeploySchema,
    RegistryCredentialsSchema,
    DbEnableSchema,
    MailboxCreateSchema,
    AliasCreateSchema
} from "../sites/site.dto.js";
import {
    createSite,
    listSites,
    deleteSite,
    updateSiteLimits,
    deploySite,
    updateSiteTls,
    enableSiteDb,
    disableSiteDb,
    purgeSiteDb,
    enableSiteMail,
    disableSiteMail,
    purgeSiteMail,
    createSiteMailbox,
    deleteSiteMailbox,
    listSiteMailboxes,
    listSiteAliases,
    createSiteAlias,
    deleteSiteAlias,
    enableSiteDns,
    disableSiteDns,
    purgeSiteDns,
    enableSiteGithub,
    disableSiteGithub,
    triggerSiteGithubDeploy,
    saveSiteRegistryCredentials,
    deleteSiteRegistryCredentials
} from "../sites/site.service.js";
const AllowlistSchema = z.object({
    items: z.array(z.string().min(1)).default([])
});
const LOGIN_RATE_LIMIT = parseEnvNumber("LOGIN_RATE_LIMIT", 10, { min: 1, max: 1000 });
const LOGIN_RATE_WINDOW_SECONDS = parseEnvNumber("LOGIN_RATE_WINDOW_SECONDS", 300, { min: 1, max: 86400 });

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
        await pruneRateLimitStore();
        const ip = getClientIp(req);
        const rateKey = `${ip ?? "unknown"}:${body.username}`;
        const limitResult = await checkRateLimit(rateKey, {
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
    
    // Production-ready logout endpoint (for session invalidation tracking)
    app.post("/auth/logout", async (req, reply) => {
        const user = requireUser(req);
        // Production-ready: revoke the current token so logout actually invalidates it.
        if (user.jti && user.exp) {
            await revokeTokenJti(user.jti, user.exp);
        }
        safeAudit({
            action: "auth.logout",
            actorUserId: user.sub,
            actorUsername: user.username,
            ip: getClientIp(req),
            success: true
        });
        return reply.send({ ok: true, message: "Logged out successfully" });
    });
    
    // Production-ready token refresh endpoint
    app.post("/auth/refresh", async (req, reply) => {
        const user = requireUser(req);
        // Production-ready: rotate token + revoke current one for immediate invalidation.
        if (user.jti && user.exp) {
            await revokeTokenJti(user.jti, user.exp);
        }
        const newToken = signToken({
            sub: user.sub,
            role: user.role,
            disabled: user.disabled ?? false
        });
        safeAudit({
            action: "auth.refresh",
            actorUserId: user.sub,
            ip: getClientIp(req),
            success: true
        });
        return reply.send({ ok: true, token: newToken });
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
        if (!id) {
            throw new HttpError(400, "User id is required.");
        }
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
        if (!id) {
            throw new HttpError(400, "User id is required.");
        }
        
        // Cleanup DB and namespace before deleting user record
        try {
            const { deleteUserNamespace } = await import("../k8s/namespace.js");
            const { dropDatabase, dropRole, revokeAndTerminate, normalizeDbName, normalizeDbUser } = await import("../postgres/admin.js");
            const dbNamePrefix = process.env.DB_NAME_PREFIX?.trim() || "db_";
            const dbUserPrefix = process.env.DB_USER_PREFIX?.trim() || "u_";
            const dbName = normalizeDbName(`${dbNamePrefix}${id}`);
            const dbUser = normalizeDbUser(`${dbUserPrefix}${id}`);
            
            // Cleanup DB
            try {
                await revokeAndTerminate(dbName);
                await dropDatabase(dbName);
                await dropRole(dbUser);
            } catch (dbError) {
                // Log but don't fail user deletion if DB cleanup fails
                logger.error({ err: dbError, userId: id }, "Failed to cleanup DB for user");
            }
            
            // Cleanup namespace (this will also delete secrets)
            try {
                await deleteUserNamespace(id);
            } catch (nsError) {
                // Log but don't fail user deletion if namespace cleanup fails
                logger.error({ err: nsError, userId: id }, "Failed to cleanup namespace for user");
            }
        } catch (cleanupError) {
            // Log but don't fail user deletion if cleanup fails
            logger.error({ err: cleanupError, userId: id }, "Failed to cleanup resources for user");
        }
        
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

    app.get("/apps/:id", async (req, reply) => {
        const user = requireUser(req);
        const appId = String(req.params.id ?? "");
        if (!appId) {
            throw new HttpError(400, "App id is required.");
        }
        const app = await getAppByIdWithOwnershipCheck(appId, user.sub);
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

    // Sites endpoints
    app.get("/sites", async (req, reply) => {
        const user = requireUser(req);
        const sites = await listSites();
        // Filter sites by user ownership (sites are in user-{userId} namespace)
        const userSites = sites.filter(site => site.namespace === `user-${user.sub}`);
        return reply.send({ ok: true, sites: userSites });
    });

    app.post("/sites", async (req, reply) => {
        const user = requireUser(req);
        const body = CreateSiteSchema.parse(req.body);
        let site;
        try {
            site = await createSite(user.sub, body);
            safeAudit({
                action: "sites.create",
                actorUserId: user.sub,
                targetType: "site",
                targetId: site.slug,
                ip: getClientIp(req),
                success: true
            });
        } catch (error) {
            safeAudit({
                action: "sites.create",
                actorUserId: user.sub,
                targetType: "site",
                ip: getClientIp(req),
                success: false,
                error: error?.message ?? String(error)
            });
            throw error;
        }
        return reply.send({ ok: true, ...site });
    });

    app.delete("/sites/:slug", async (req, reply) => {
        const user = requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        try {
            await deleteSite(slug);
            safeAudit({
                action: "sites.delete",
                actorUserId: user.sub,
                targetType: "site",
                targetId: slug,
                ip: getClientIp(req),
                success: true
            });
        } catch (error) {
            safeAudit({
                action: "sites.delete",
                actorUserId: user.sub,
                targetType: "site",
                targetId: slug,
                ip: getClientIp(req),
                success: false,
                error: error?.message ?? String(error)
            });
            throw error;
        }
        return reply.send({ ok: true });
    });

    app.patch("/sites/:slug/limits", async (req, reply) => {
        requireUser(req); // User authenticated but not used in this handler
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = PatchLimitsSchema.parse(req.body ?? {});
        const result = await updateSiteLimits(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/deploy", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = DeploySiteSchema.parse(req.body ?? {});
        const result = await deploySite(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.patch("/sites/:slug/tls", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = PatchTlsSchema.parse(req.body ?? {});
        const result = await updateSiteTls(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/db/enable", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = DbEnableSchema.parse(req.body ?? {});
        const result = await enableSiteDb(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/db/disable", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const result = await disableSiteDb(slug);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/db/purge", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        ConfirmDeleteSchema.parse(req.body ?? {});
        const result = await purgeSiteDb(slug);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/mail/enable", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = MailEnableSchema.parse(req.body ?? {});
        const result = await enableSiteMail(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/mail/disable", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const result = await disableSiteMail(slug);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/mail/purge", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        ConfirmDeleteSchema.parse(req.body ?? {});
        const result = await purgeSiteMail(slug);
        return reply.send({ ok: true, ...result });
    });

    app.get("/sites/:slug/mail/mailboxes", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const result = await listSiteMailboxes(slug);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/mail/mailboxes", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = MailboxCreateSchema.parse(req.body ?? {});
        const result = await createSiteMailbox(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.delete("/sites/:slug/mail/mailboxes/:address", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        const address = String(req.params.address ?? "");
        if (!slug || !address) {
            throw new HttpError(400, "Site slug and address are required.");
        }
        const result = await deleteSiteMailbox(slug, decodeURIComponent(address));
        return reply.send({ ok: true, ...result });
    });

    app.get("/sites/:slug/mail/aliases", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const result = await listSiteAliases(slug);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/mail/aliases", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = AliasCreateSchema.parse(req.body ?? {});
        const result = await createSiteAlias(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.delete("/sites/:slug/mail/aliases/:source", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        const source = String(req.params.source ?? "");
        if (!slug || !source) {
            throw new HttpError(400, "Site slug and source are required.");
        }
        const result = await deleteSiteAlias(slug, decodeURIComponent(source));
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/dns/enable", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = DnsEnableSchema.parse(req.body ?? {});
        const result = await enableSiteDns(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/dns/disable", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const result = await disableSiteDns(slug);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/dns/purge", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        ConfirmDeleteSchema.parse(req.body ?? {});
        const result = await purgeSiteDns(slug);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/github/enable", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = GithubEnableSchema.parse(req.body ?? {});
        const result = await enableSiteGithub(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/github/disable", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const result = await disableSiteGithub(slug);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/github/deploy", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = GithubDeploySchema.parse(req.body ?? {});
        const result = await triggerSiteGithubDeploy(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.post("/sites/:slug/registry/credentials", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const body = RegistryCredentialsSchema.parse(req.body ?? {});
        const result = await saveSiteRegistryCredentials(slug, body);
        return reply.send({ ok: true, ...result });
    });

    app.delete("/sites/:slug/registry/credentials", async (req, reply) => {
        requireUser(req);
        const slug = String(req.params.slug ?? "");
        if (!slug) {
            throw new HttpError(400, "Site slug is required.");
        }
        const result = await deleteSiteRegistryCredentials(slug);
        return reply.send({ ok: true, ...result });
    });

    // Security logs endpoint (fail2ban)
    app.get("/admin/security/logs", async (req, reply) => {
        requireAdmin(req);
        const { exec } = await import("node:child_process");
        const { promisify } = await import("node:util");
        const execAsync = promisify(exec);
        
        try {
            // Get fail2ban status
            const status = {};
            try {
                const { stdout: statusOutput } = await execAsync("fail2ban-client status 2>/dev/null || echo 'FAIL2BAN_NOT_RUNNING'");
                if (!statusOutput.includes("FAIL2BAN_NOT_RUNNING")) {
                    const lines = statusOutput.split("\n");
                    const jailLine = lines.find(line => line.includes("Jail list:"));
                    if (jailLine) {
                        const jails = jailLine.split(":")[1]?.trim().split(",").map(j => j.trim()).filter(Boolean) || [];
                        status.jails = jails;
                        
                        // Get banned IPs for each jail
                        status.banned = {};
                        for (const jail of jails) {
                            try {
                                const { stdout: jailStatus } = await execAsync(`fail2ban-client status ${jail} 2>/dev/null || echo ''`);
                                const bannedLine = jailStatus.split("\n").find(line => line.includes("Banned IP list:"));
                                if (bannedLine) {
                                    const ips = bannedLine.split(":")[1]?.trim().split(/\s+/).filter(Boolean) || [];
                                    status.banned[jail] = ips;
                                }
                            } catch {
                                status.banned[jail] = [];
                            }
                        }
                    }
                } else {
                    status.error = "fail2ban not running";
                }
            } catch (error) {
                status.error = error.message;
            }
            
            // Get fail2ban log (last 500 lines)
            let logLines = [];
            try {
                const { stdout: logOutput } = await execAsync("tail -n 500 /var/log/fail2ban.log 2>/dev/null || echo ''");
                logLines = logOutput.split("\n").filter(Boolean);
            } catch {
                // Log file might not exist or be readable
            }
            
            return reply.send({
                ok: true,
                status,
                logs: logLines.slice(-200) // Last 200 lines
            });
        } catch (error) {
            throw new HttpError(500, `Failed to read security logs: ${error.message}`);
        }
    });
}