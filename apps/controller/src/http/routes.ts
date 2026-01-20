import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { HttpError } from "./errors.js";
import { readAllowlist, writeAllowlist } from "../security/allowlist.js";
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
  listUsers,
  setUserActive,
  deleteUser,
  verifyUserCredentials,
  createSession,
  getSession,
  deleteSession
} from "../users/user.service.js";
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
import { restoreSiteDb, restoreSiteFiles } from "../backup/restore.service.js";

const SlugParamSchema = z.string().min(1, "Slug is required.");
const AllowlistSchema = z.object({
  items: z.array(z.string().min(1)).default([])
});

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

export function registerRoutes(app: FastifyInstance) {
  app.post("/auth/login", async (req, reply) => {
    const body = LoginSchema.parse(req.body ?? {});
    const user = await verifyUserCredentials(body.username, body.password);
    const session = await createSession(user.id);
    return reply.send({ ok: true, token: session.token, user: session.user, expiresAt: session.expiresAt });
  });

  app.get("/auth/session", async (req, reply) => {
    const token = getSessionToken(req.headers as Record<string, string | string[] | undefined>);
    const session = await getSession(token);
    return reply.send({ ok: true, user: session.user, expiresAt: session.expiresAt });
  });

  app.post("/auth/logout", async (req, reply) => {
    const token = getSessionToken(req.headers as Record<string, string | string[] | undefined>);
    await deleteSession(token);
    return reply.send({ ok: true });
  });

  app.get("/users", async (req, reply) => {
    await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const users = await listUsers();
    return reply.send({ ok: true, users });
  });

  app.post("/users", async (req, reply) => {
    await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const body = CreateUserSchema.parse(req.body);
    const user = await createUser(body);
    return reply.send({ ok: true, user });
  });

  app.patch("/users/:id", async (req, reply) => {
    await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const id = String((req.params as { id?: string }).id ?? "");
    if (!id) throw new HttpError(400, "User id is required.");
    const body = ToggleUserSchema.parse(req.body ?? {});
    const user = await setUserActive(id, body.active);
    return reply.send({ ok: true, user });
  });

  app.delete("/users/:id", async (req, reply) => {
    await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const id = String((req.params as { id?: string }).id ?? "");
    if (!id) throw new HttpError(400, "User id is required.");
    await deleteUser(id);
    return reply.send({ ok: true });
  });

  app.get("/security/allowlist", async (_req, reply) => {
    await requireAdmin(_req.headers as Record<string, string | string[] | undefined>);
    const items = await readAllowlist();
    return reply.send({ ok: true, items });
  });

  app.put("/security/allowlist", async (req, reply) => {
    await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const body = AllowlistSchema.parse(req.body ?? {});
    const items = await writeAllowlist(body.items);
    return reply.send({ ok: true, items });
  });

  app.post("/sites", async (req, reply) => {
    await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const body = CreateSiteSchema.parse(req.body);
    const result = await createSite(body);
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
    await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const slug = String((req.params as { slug: string }).slug ?? "");
    const body = PatchLimitsSchema.parse(req.body);
    const result = await updateSiteLimits(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/deploy", async (req, reply) => {
    const slug = String((req.params as { slug: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = DeploySiteSchema.parse(req.body);
    const result = await deploySite(slug, body);
    return reply.send(result);
  });

  app.patch("/sites/:slug/tls", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = PatchTlsSchema.parse(req.body);
    const result = await updateSiteTls(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = MailEnableSchema.parse(req.body);
    const result = await enableSiteMail(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/dns/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = DnsEnableSchema.parse(req.body);
    const result = await enableSiteDns(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/github/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = GithubEnableSchema.parse(req.body);
    const result = await enableSiteGithub(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/db/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = DbEnableSchema.parse(req.body ?? {});
    const result = await enableSiteDb(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/db/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await disableSiteDb(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/db/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    requireConfirmDelete(req.body);
    const result = await purgeSiteDb(slug);
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
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await disableSiteMail(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/dns/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await disableSiteDns(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/github/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await disableSiteGithub(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    requireConfirmDelete(req.body);
    const result = await purgeSiteMail(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/dns/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    requireConfirmDelete(req.body);
    const result = await purgeSiteDns(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/github/deploy", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = GithubDeploySchema.parse(req.body ?? {});
    const result = await triggerSiteGithubDeploy(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/mailboxes", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = MailboxCreateSchema.parse(req.body);
    const result = await createSiteMailbox(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/aliases", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = AliasCreateSchema.parse(req.body);
    const result = await createSiteAlias(slug, body);
    return reply.send(result);
  });

  app.delete("/sites/:slug/mail/mailboxes/:address", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const address = String((req.params as { address?: string }).address ?? "").trim();
    if (!address) {
      throw new HttpError(400, "Mailbox address is required.");
    }
    const result = await deleteSiteMailbox(slug, address);
    return reply.send(result);
  });

  app.delete("/sites/:slug/mail/aliases/:source", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const source = String((req.params as { source?: string }).source ?? "").trim();
    if (!source) {
      throw new HttpError(400, "Alias source is required.");
    }
    const result = await deleteSiteAlias(slug, source);
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
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = BackupEnableSchema.parse(req.body ?? {});
    const result = await enableSiteBackup(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await disableSiteBackup(slug);
    return reply.send(result);
  });

  app.patch("/sites/:slug/backup/config", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = BackupConfigSchema.parse(req.body ?? {});
    const result = await updateSiteBackupConfig(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/run", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const result = await runSiteBackup(slug);
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
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = BackupRestoreSchema.parse(req.body ?? {});
    const result = await restoreSiteBackup(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    requireConfirmDelete(req.body);
    const result = await purgeSiteBackup(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/restore/files", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = RestoreFilesSchema.parse(req.body ?? {});
    const result = await restoreSiteFiles(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/restore/db", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireSiteAccess(req.headers as Record<string, string | string[] | undefined>, slug);
    const body = RestoreDbSchema.parse(req.body ?? {});
    const result = await restoreSiteDb(slug, body);
    return reply.send(result);
  });

  app.delete("/sites/:slug", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    const result = await deleteSite(slug);
    return reply.code(200).send({ ok: true, slug: result.slug });
  });

  app.post("/sites/:slug/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    await requireAdmin(req.headers as Record<string, string | string[] | undefined>);
    requireConfirmDelete(req.body);
    const result = await purgeSite(slug);
    return reply.send(result);
  });
}
