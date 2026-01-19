import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { HttpError } from "./errors.js";
import {
  CreateSiteSchema,
  DeploySiteSchema,
  AliasCreateSchema,
  MailEnableSchema,
  MailboxCreateSchema,
  PatchLimitsSchema,
  PatchTlsSchema,
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

function requireConfirmDelete(body: unknown) {
  const payload = body as { confirm?: string } | null;
  if (!payload || payload.confirm !== "DELETE") {
    throw new HttpError(400, "confirm required");
  }
}

export function registerRoutes(app: FastifyInstance) {
  app.post("/sites", async (req, reply) => {
    const body = CreateSiteSchema.parse(req.body);
    const result = await createSite(body);
    return reply.send(result);
  });

  app.get("/sites", async () => listSites());

  app.patch("/sites/:slug/limits", async (req, reply) => {
    const slug = String((req.params as { slug: string }).slug ?? "");
    const body = PatchLimitsSchema.parse(req.body);
    const result = await updateSiteLimits(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/deploy", async (req, reply) => {
    const slug = String((req.params as { slug: string }).slug ?? "");
    const body = DeploySiteSchema.parse(req.body);
    const result = await deploySite(slug, body);
    return reply.send(result);
  });

  app.patch("/sites/:slug/tls", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const body = PatchTlsSchema.parse(req.body);
    const result = await updateSiteTls(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const body = MailEnableSchema.parse(req.body);
    const result = await enableSiteMail(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/db/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const body = DbEnableSchema.parse(req.body ?? {});
    const result = await enableSiteDb(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/db/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await disableSiteDb(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/db/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    requireConfirmDelete(req.body);
    const result = await purgeSiteDb(slug);
    return reply.send(result);
  });

  app.get("/sites/:slug/db/status", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await getSiteDbStatus(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await disableSiteMail(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    requireConfirmDelete(req.body);
    const result = await purgeSiteMail(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/mailboxes", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const body = MailboxCreateSchema.parse(req.body);
    const result = await createSiteMailbox(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/mail/aliases", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const body = AliasCreateSchema.parse(req.body);
    const result = await createSiteAlias(slug, body);
    return reply.send(result);
  });

  app.delete("/sites/:slug/mail/mailboxes/:address", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const address = String((req.params as { address?: string }).address ?? "").trim();
    if (!address) {
      throw new HttpError(400, "Mailbox address is required.");
    }
    const result = await deleteSiteMailbox(slug, address);
    return reply.send(result);
  });

  app.delete("/sites/:slug/mail/aliases/:source", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const source = String((req.params as { source?: string }).source ?? "").trim();
    if (!source) {
      throw new HttpError(400, "Alias source is required.");
    }
    const result = await deleteSiteAlias(slug, source);
    return reply.send(result);
  });

  app.get("/sites/:slug/mail/mailboxes", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await listSiteMailboxes(slug);
    return reply.send(result);
  });

  app.get("/sites/:slug/mail/aliases", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await listSiteAliases(slug);
    return reply.send(result);
  });

  app.get("/sites/:slug/mail/status", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await getSiteMailStatus(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const body = BackupEnableSchema.parse(req.body ?? {});
    const result = await enableSiteBackup(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await disableSiteBackup(slug);
    return reply.send(result);
  });

  app.patch("/sites/:slug/backup/config", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const body = BackupConfigSchema.parse(req.body ?? {});
    const result = await updateSiteBackupConfig(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/run", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await runSiteBackup(slug);
    return reply.send(result);
  });

  app.get("/sites/:slug/backup/snapshots", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await listSiteBackupSnapshots(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/restore", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const body = BackupRestoreSchema.parse(req.body ?? {});
    const result = await restoreSiteBackup(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    requireConfirmDelete(req.body);
    const result = await purgeSiteBackup(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/restore/files", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const body = RestoreFilesSchema.parse(req.body ?? {});
    const result = await restoreSiteFiles(slug, body);
    return reply.send(result);
  });

  app.post("/sites/:slug/restore/db", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const body = RestoreDbSchema.parse(req.body ?? {});
    const result = await restoreSiteDb(slug, body);
    return reply.send(result);
  });

  app.delete("/sites/:slug", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await deleteSite(slug);
    return reply.code(200).send({ ok: true, slug: result.slug });
  });

  app.post("/sites/:slug/purge", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    requireConfirmDelete(req.body);
    const result = await purgeSite(slug);
    return reply.send(result);
  });
}
