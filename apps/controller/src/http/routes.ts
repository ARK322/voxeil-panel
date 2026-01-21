import type { FastifyInstance } from "fastify";
import { createHmac, timingSafeEqual } from "node:crypto";
import { PassThrough } from "node:stream";
import k8s from "@kubernetes/client-node";
import { z } from "zod";
import { HttpError } from "./errors.js";
import { readAllowlist, writeAllowlist } from "../security/allowlist.js";
import { checkRateLimit, pruneRateLimitStore } from "../security/rate-limit.js";
import { logAudit } from "../audit/audit.service.js";
import {
  CreateSiteSchema,
  DeploySiteSchema,
  AliasCreateSchema,
  MailEnableSchema,
  MailboxCreateSchema,
  PatchLimitsSchema,
  PatchTlsSchema,
  DnsEnableSchema,
  GithubEnableSchema,
  GithubDeploySchema,
  DbEnableSchema
} from "../sites/site.dto.js";
import {
  BackupConfigSchema,
  BackupEnableSchema,
  BackupRestoreSchema,
  RestoreDbSchema,
  RestoreFilesSchema
} from "../backup/backup.dto.js";
import {
  CreateUserSchema,
  LoginSchema,
  ToggleUserSchema
} from "../users/user.dto.js";
import {
  createUser,
  createUserWithBootstrap,
  listUsers,
  setUserActive,
  deleteUser,
  verifyUserCredentials,
  createSession,
  getSession,
  deleteSession
} from "../users/user.service.js";
import { createToken } from "../auth/jwt.js";
import { requireAdmin, getAuthenticatedUser, type AuthenticatedRequest } from "../auth/middleware.js";
import {
  createSite,
  deleteSite,
  deploySite,
  enableSiteDb,
  enableSiteMail,
  disableSiteDb,
  disableSiteMail,
  purgeSiteDb,
  purgeSiteMail,
  getSiteDbStatus,
  createSiteAlias,
  createSiteMailbox,
  deleteSiteAlias,
  deleteSiteMailbox,
  getSiteMailStatus,
  getSiteDnsStatus,
  enableSiteDns,
  disableSiteDns,
  purgeSiteDns,
  enableSiteGithub,
  disableSiteGithub,
  triggerSiteGithubDeploy,
  getSiteGithubStatus,
  GITHUB_SECRET_NAME,
  listSiteAliases,
  listSiteMailboxes,
  listSites,
  purgeSite,
  purgeSiteBackup,
  listSiteBackupSnapshots,
  restoreSiteBackup,
  runSiteBackup,
  updateSiteBackupConfig,
  updateSiteTls,
  updateSiteLimits,
  enableSiteBackup,
  disableSiteBackup
} from "../sites/site.service.js";
import { listTenantNamespaces, slugFromNamespace } from "../k8s/namespace.js";
import { getClients } from "../k8s/client.js";
import { SITE_ANNOTATIONS } from "../k8s/annotations.js";
import { readSecret } from "../k8s/secrets.js";
import { restoreSiteDb, restoreSiteFiles } from "../backup/restore.service.js";

const SlugParamSchema = z.string().min(1, "Slug is required.");
const AllowlistSchema = z.object({
  items: z.array(z.string().min(1)).default([])
});
const LOGIN_RATE_LIMIT = Number(process.env.LOGIN_RATE_LIMIT ?? "10");
const LOGIN_RATE_WINDOW_SECONDS = Number(process.env.LOGIN_RATE_WINDOW_SECONDS ?? "300");

function requireConfirmDelete(body: unknown) {
  const payload = body as { confirm?: string } | null;
  if (!payload || payload.confirm !== "DELETE") {
    throw new HttpError(400, "confirm required");
  }
}

function getSessionToken(headers: Record<string, string | string[] | undefined>): string {
  const header = headers["x-session-token"];
  const token = Array.isArray(header) ? header[0] : header;
  if (!token) {
    throw new HttpError(401, "Session token is required.");
  }
  return token;
}

async function requireAdmin(headers: Record<string, string | string[] | undefined>) {
  const token = getSessionToken(headers);
  const session = await getSession(token);
  if (session.user.role !== "admin") {
    throw new HttpError(403, "Admin access required.");
  }
  return session;
}

async function requireSession(headers: Record<string, string | string[] | undefined>) {
  const token = getSessionToken(headers);
  return getSession(token);
}

async function requireSiteAccess(
  headers: Record<string, string | string[] | undefined>,
  slug: string
) {
  const session = await requireSession(headers);
  if (session.user.role === "admin") return session;
  if (session.user.siteSlug !== slug) {
    throw new HttpError(403, "Site access denied.");
  }
  return session;
}

async function resolveGithubWebhookConfig(repo: string) {
  const namespaces = await listTenantNamespaces();
  for (const entry of namespaces) {
    const annotations = entry.annotations;
    const enabled = annotations[SITE_ANNOTATIONS.githubEnabled] === "true";
    if (!enabled) continue;
    const repoValue = annotations[SITE_ANNOTATIONS.githubRepo]?.trim();
    if (!repoValue || repoValue !== repo) continue;
    const slug = slugFromNamespace(entry.name);
    const branch = annotations[SITE_ANNOTATIONS.githubBranch]?.trim() || "main";
    const image = annotations[SITE_ANNOTATIONS.githubImage]?.trim() || "";
    const secret =
      (await readSecret(entry.name, GITHUB_SECRET_NAME)) ??
      (await readSecret(entry.name, `${slug}-${GITHUB_SECRET_NAME}`));
    const webhookSecret = secret?.data?.webhookSecret
      ? Buffer.from(secret.data.webhookSecret, "base64").toString("utf8")
      : "";
    return { slug, branch, image, webhookSecret };
  }
  return null;
}

async function resolveSitePodName(namespace: string): Promise<string> {
  const { core } = getClients();
  const pods = await core.listNamespacedPod(
    namespace,
    undefined,
    undefined,
    undefined,
    undefined,
    "app=web"
  );
  const running = pods.body.items.find((item) => item.status?.phase === "Running");
  const podName = running?.metadata?.name ?? pods.body.items[0]?.metadata?.name;
  if (!podName) {
    throw new HttpError(404, "Site pod not found.");
  }
  return podName;
}

function safeAudit(entry: Parameters<typeof logAudit>[0]) {
  void logAudit(entry).catch(() => undefined);
}

function getClientIp(req: { ip?: string | undefined }): string | null {
  return req.ip ?? null;
}

export function registerRoutes(app: FastifyInstance) {
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
    } catch (error: any) {
      safeAudit({
        action: "auth.login_failed",
        actorUsername: body.username,
        ip,
        meta: { reason: error?.message ?? "invalid_credentials" }
      });
      throw error;
    }
    
    // Create JWT token
    const token = createToken({
      sub: user.id,
      role: user.role === "admin" ? "admin" : "user",
      disabled: !user.active
    });
    
    safeAudit({
      action: "auth.login",
      actorUserId: user.id,
      actorUsername: user.username,
      ip
    });
    
    return reply.send({ 
      ok: true, 
      token,
      user: {
        id: user.id,
        username: user.username,
        email: user.email,
        role: user.role,
        siteSlug: user.siteSlug
      }
    });
  });

  app.get("/auth/session", async (req, reply) => {
    const token = getSessionToken(req.headers as Record<string, string | string[] | undefined>);
    const session = await getSession(token);
    return reply.send({ ok: true, user: session.user, expiresAt: session.expiresAt });
  });

  app.post("/auth/logout", async (req, reply) => {
    const token = getSessionToken(req.headers as Record<string, string | string[] | undefined>);
    const session = await getSession(token);
    await deleteSession(token);
    safeAudit({
      action: "auth.logout",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      ip: getClientIp(req)
    });
    return reply.send({ ok: true });
  });

  app.get("/users", async (req, reply) => {
    await requireAdmin(req, reply);
    const users = await listUsers();
    return reply.send({ ok: true, users });
  });

  app.post("/admin/users", async (req, reply) => {
    await requireAdmin(req, reply);
    const actor = getAuthenticatedUser(req);
    const body = CreateUserSchema.parse(req.body);
    
    // Idempotency check: if user already exists, return existing user
    try {
      const existingUsers = await listUsers();
      const existing = existingUsers.find(u => u.username === body.username);
      if (existing) {
        // Verify namespace exists if it should
        if (existing.role === "user" || body.role === "user") {
          const namespace = `user-${existing.id}`;
          const { core } = getClients();
          try {
            await core.readNamespace(namespace);
            // Everything exists, return existing user
            safeAudit({
              action: "users.create",
              actorUserId: actor.sub,
              actorUsername: actor.sub, // We don't have username in JWT, use sub
              target: existing.id,
              ip: getClientIp(req),
              meta: { username: existing.username, role: existing.role, idempotent: true }
            });
            return reply.send({ ok: true, user: existing, idempotent: true });
          } catch (error: any) {
            // Namespace doesn't exist, continue with bootstrap
          }
        } else {
          // Admin user exists, return it
          safeAudit({
            action: "users.create",
            actorUserId: actor.sub,
            actorUsername: actor.sub,
            target: existing.id,
            ip: getClientIp(req),
            meta: { username: existing.username, role: existing.role, idempotent: true }
          });
          return reply.send({ ok: true, user: existing, idempotent: true });
        }
      }
    } catch (error: any) {
      // Continue with creation if check fails
    }
    
    // Create user with namespace bootstrap
    const user = await createUserWithBootstrap(body);
    
    safeAudit({
      action: "users.create",
      actorUserId: actor.sub,
      actorUsername: actor.sub,
      target: user.id,
      ip: getClientIp(req),
      meta: { 
        username: user.username, 
        role: user.role, 
        siteSlug: user.siteSlug ?? null,
        namespace: user.role === "user" ? `user-${user.id}` : null
      }
    });
    
    return reply.send({ ok: true, user });
  });

  app.patch("/users/:id", async (req, reply) => {
    await requireAdmin(req, reply);
    const actor = getAuthenticatedUser(req);
    const id = String((req.params as { id?: string }).id ?? "");
    if (!id) throw new HttpError(400, "User id is required.");
    const body = ToggleUserSchema.parse(req.body ?? {});
    const user = await setUserActive(id, body.active);
    safeAudit({
      action: "users.toggle",
      actorUserId: actor.sub,
      actorUsername: actor.sub,
      target: user.id,
      ip: getClientIp(req),
      meta: { active: user.active }
    });
    return reply.send({ ok: true, user });
  });

  app.delete("/users/:id", async (req, reply) => {
    await requireAdmin(req, reply);
    const actor = getAuthenticatedUser(req);
    const id = String((req.params as { id?: string }).id ?? "");
    if (!id) throw new HttpError(400, "User id is required.");
    await deleteUser(id);
    safeAudit({
      action: "users.delete",
      actorUserId: actor.sub,
      actorUsername: actor.sub,
      target: id,
      ip: getClientIp(req)
    });
    return reply.send({ ok: true });
  });

  app.get("/security/allowlist", async (_req, reply) => {
    await requireAdmin(_req.headers as Record<string, string | string[] | undefined>);
    const items = await readAllowlist();
    return reply.send({ ok: true, items });
  });

  app.put("/security/allowlist", async (req, reply) => {
    const session = await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const body = AllowlistSchema.parse(req.body ?? {});
    const items = await writeAllowlist(body.items);
    safeAudit({
      action: "security.allowlist.update",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      ip: getClientIp(req),
      meta: { count: items.length }
    });
    return reply.send({ ok: true, items });
  });

  app.post("/github/webhook", async (req, reply) => {
    const rawBody = (req as { rawBody?: Buffer }).rawBody;
    if (!rawBody) {
      throw new HttpError(400, "Webhook payload missing.");
    }
    let payload: any;
    try {
      payload = JSON.parse(rawBody.toString("utf8"));
    } catch (error: any) {
      throw new HttpError(400, "Webhook payload invalid.");
    }
    const repo = payload?.repository?.full_name?.trim();
    if (!repo) {
      throw new HttpError(400, "Repository is required.");
    }
    const config = await resolveGithubWebhookConfig(repo);
    if (!config) {
      return reply.code(202).send({ ok: true, ignored: true });
    }
    if (!config.webhookSecret) {
      throw new HttpError(409, "GitHub webhook secret not configured.");
    }
    const header = req.headers["x-hub-signature-256"];
    const signature = Array.isArray(header) ? header[0] : header;
    if (!signature) {
      throw new HttpError(401, "Signature is required.");
    }
    const expected = `sha256=${createHmac("sha256", config.webhookSecret)
      .update(rawBody)
      .digest("hex")}`;
    const signatureOk =
      signature.length === expected.length &&
      timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
    if (!signatureOk) {
      throw new HttpError(401, "Signature invalid.");
    }

    const eventHeader = req.headers["x-github-event"];
    const event = Array.isArray(eventHeader) ? eventHeader[0] : eventHeader;
    if (event !== "push") {
      return reply.send({ ok: true, ignored: true });
    }
    const ref = payload?.ref?.trim();
    const expectedRef = `refs/heads/${config.branch}`;
    if (ref !== expectedRef) {
      return reply.send({ ok: true, ignored: true });
    }
    await triggerSiteGithubDeploy(config.slug, {
      ref: config.branch,
      image: config.image || undefined
    });
    return reply.send({ ok: true, dispatched: true });
  });

  app.post("/sites", async (req, reply) => {
    const session = await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const body = CreateSiteSchema.parse(req.body);
    const result = await createSite(body);
    safeAudit({
      action: "sites.create",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: result.slug,
      ip: getClientIp(req),
      meta: { domain: result.domain, namespace: result.namespace }
    });
    return reply.send(result);
  });

  app.get("/sites", async (req, reply) => {
    const session = await requireSession(req.headers as Record<string, string | string[] | undefined>);
    const items = await listSites();
    if (session.user.role === "admin") {
      return reply.send(items);
    }
    const filtered = items.filter((item) => item.slug === session.user.siteSlug);
    return reply.send(filtered);
  });

  app.patch("/sites/:slug/limits", async (req, reply) => {
    const session = await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const slug = String((req.params as { slug: string }).slug ?? "");
    const body = PatchLimitsSchema.parse(req.body);
    const result = await updateSiteLimits(slug, body);
    safeAudit({
      action: "sites.limits.update",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { cpu: body.cpu, ramGi: body.ramGi, diskGi: body.diskGi }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/deploy", async (req, reply) => {
    const slug = String((req.params as { slug: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = DeploySiteSchema.parse(req.body);
    const result = await deploySite(slug, body);
    safeAudit({
      action: "sites.deploy",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: {
        image: body.image,
        containerPort: body.containerPort,
        uploadDirs: body.uploadDirs ?? null
      }
    });
    return reply.send(result);
  });

  app.get("/sites/:slug/logs/stream", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const namespace = `tenant-${slug}`;
    const query = req.query as { container?: string; tailLines?: string };
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
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = PatchTlsSchema.parse(req.body);
    const result = await updateSiteTls(slug, body);
    safeAudit({
      action: "sites.tls.update",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { enabled: body.enabled, issuer: body.issuer ?? null, cleanupSecret: body.cleanupSecret ?? null }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = MailEnableSchema.parse(req.body);
    const result = await enableSiteMail(slug, body);
    safeAudit({
      action: "sites.mail.enable",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { domain: body.domain }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/dns/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = DnsEnableSchema.parse(req.body);
    const result = await enableSiteDns(slug, body);
    safeAudit({
      action: "sites.dns.enable",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { domain: body.domain, targetIp: body.targetIp }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/github/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = GithubEnableSchema.parse(req.body);
    const result = await enableSiteGithub(slug, body);
    safeAudit({
      action: "sites.github.enable",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: {
        repo: body.repo,
        branch: body.branch ?? null,
        workflow: body.workflow ?? null,
        image: body.image
      }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/db/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = DbEnableSchema.parse(req.body ?? {});
    const result = await enableSiteDb(slug, body);
    safeAudit({
      action: "sites.db.enable",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { dbName: body.dbName ?? null }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/db/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const result = await disableSiteDb(slug);
    safeAudit({
      action: "sites.db.disable",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/db/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    requireConfirmDelete(req.body);
    const result = await purgeSiteDb(slug);
    safeAudit({
      action: "sites.db.purge",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });

  app.get("/sites/:slug/db/status", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await getSiteDbStatus(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const result = await disableSiteMail(slug);
    safeAudit({
      action: "sites.mail.disable",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/dns/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const result = await disableSiteDns(slug);
    safeAudit({
      action: "sites.dns.disable",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/github/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const result = await disableSiteGithub(slug);
    safeAudit({
      action: "sites.github.disable",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    requireConfirmDelete(req.body);
    const result = await purgeSiteMail(slug);
    safeAudit({
      action: "sites.mail.purge",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/dns/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    requireConfirmDelete(req.body);
    const result = await purgeSiteDns(slug);
    safeAudit({
      action: "sites.dns.purge",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/github/deploy", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = GithubDeploySchema.parse(req.body ?? {});
    const result = await triggerSiteGithubDeploy(slug, body);
    safeAudit({
      action: "sites.github.deploy",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { ref: body.ref ?? null, image: body.image ?? null }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/mailboxes", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = MailboxCreateSchema.parse(req.body);
    const result = await createSiteMailbox(slug, body);
    safeAudit({
      action: "sites.mail.mailbox.create",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { localPart: body.localPart }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/aliases", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = AliasCreateSchema.parse(req.body);
    const result = await createSiteAlias(slug, body);
    safeAudit({
      action: "sites.mail.alias.create",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { source: body.sourceLocalPart, destination: body.destination }
    });
    return reply.send(result);
  });

  app.delete("/sites/:slug/mail/mailboxes/:address", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const address = String((req.params as { address?: string }).address ?? "").trim();
    if (!address) {
      throw new HttpError(400, "Mailbox address is required.");
    }
    const result = await deleteSiteMailbox(slug, address);
    safeAudit({
      action: "sites.mail.mailbox.delete",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { address }
    });
    return reply.send(result);
  });

  app.delete("/sites/:slug/mail/aliases/:source", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const source = String((req.params as { source?: string }).source ?? "").trim();
    if (!source) {
      throw new HttpError(400, "Alias source is required.");
    }
    const result = await deleteSiteAlias(slug, source);
    safeAudit({
      action: "sites.mail.alias.delete",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { source }
    });
    return reply.send(result);
  });

  app.get("/sites/:slug/mail/mailboxes", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await listSiteMailboxes(slug);
    return reply.send(result);
  });

  app.get("/sites/:slug/mail/aliases", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await listSiteAliases(slug);
    return reply.send(result);
  });

  app.get("/sites/:slug/mail/status", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await getSiteMailStatus(slug);
    return reply.send(result);
  });

  app.get("/sites/:slug/dns/status", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await getSiteDnsStatus(slug);
    return reply.send(result);
  });

  app.get("/sites/:slug/github/status", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await getSiteGithubStatus(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = BackupEnableSchema.parse(req.body ?? {});
    const result = await enableSiteBackup(slug, body);
    safeAudit({
      action: "sites.backup.enable",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { retentionDays: body.retentionDays ?? null, schedule: body.schedule ?? null }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const result = await disableSiteBackup(slug);
    safeAudit({
      action: "sites.backup.disable",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });

  app.patch("/sites/:slug/backup/config", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = BackupConfigSchema.parse(req.body ?? {});
    const result = await updateSiteBackupConfig(slug, body);
    safeAudit({
      action: "sites.backup.config",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { retentionDays: body.retentionDays ?? null, schedule: body.schedule ?? null }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/run", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const result = await runSiteBackup(slug);
    safeAudit({
      action: "sites.backup.run",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });

  app.get("/sites/:slug/backup/snapshots", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await listSiteBackupSnapshots(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/restore", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = BackupRestoreSchema.parse(req.body ?? {});
    const result = await restoreSiteBackup(slug, body);
    safeAudit({
      action: "sites.backup.restore",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: {
        snapshotId: body.snapshotId,
        restoreFiles: body.restoreFiles ?? false,
        restoreDb: body.restoreDb ?? false
      }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    requireConfirmDelete(req.body);
    const result = await purgeSiteBackup(slug);
    safeAudit({
      action: "sites.backup.purge",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/restore/files", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = RestoreFilesSchema.parse(req.body ?? {});
    const result = await restoreSiteFiles(slug, body);
    safeAudit({
      action: "sites.restore.files",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { backupFile: body.backupFile ?? null, latest: body.latest ?? null, restoreFiles: true }
    });
    return reply.send(result);
  });

  app.post("/sites/:slug/restore/db", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireSiteAccess(
      req.headers as Record<string, string | string[] | undefined>,
      slug
    );
    const body = RestoreDbSchema.parse(req.body ?? {});
    const result = await restoreSiteDb(slug, body);
    safeAudit({
      action: "sites.restore.db",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req),
      meta: { backupFile: body.backupFile ?? null, latest: body.latest ?? null, restoreDb: true }
    });
    return reply.send(result);
  });

  app.delete("/sites/:slug", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const result = await deleteSite(slug);
    safeAudit({
      action: "sites.delete",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.code(200).send({ ok: true, slug: result.slug });
  });

  app.post("/sites/:slug/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const session = await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    requireConfirmDelete(req.body);
    const result = await purgeSite(slug);
    safeAudit({
      action: "sites.purge",
      actorUserId: session.user.id,
      actorUsername: session.user.username,
      target: slug,
      ip: getClientIp(req)
    });
    return reply.send(result);
  });
}
