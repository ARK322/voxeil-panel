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
import { listApps, createApp, deployApp, getAppByIdWithOwnershipCheck } from "../apps/app.service.js";
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
        
        // Cleanup DB and namespace before deleting user record
        try {
            const { deleteUserNamespace } = await import("../k8s/namespace.js");
            const { dropDatabase, dropRole, revokeAndTerminate, normalizeDbName, normalizeDbUser } = await import("../postgres/admin.js");
            const { deleteSecret } = await import("../k8s/secrets.js");
            
            const namespace = `user-${id}`;
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
                console.error("Failed to cleanup DB for user:", id, dbError);
            }
            
            // Cleanup namespace (this will also delete secrets)
            try {
                await deleteUserNamespace(id);
            } catch (nsError) {
                // Log but don't fail user deletion if namespace cleanup fails
                console.error("Failed to cleanup namespace for user:", id, nsError);
            }
        } catch (cleanupError) {
            // Log but don't fail user deletion if cleanup fails
            console.error("Failed to cleanup resources for user:", id, cleanupError);
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
}