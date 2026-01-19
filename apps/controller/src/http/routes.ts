import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { HttpError } from "./errors.js";
import {
  CreateSiteSchema,
  DeploySiteSchema,
  MailEnableSchema,
  MailboxCreateSchema,
  PatchLimitsSchema,
  PatchTlsSchema
} from "../sites/site.dto.js";
import { RestoreDbSchema, RestoreFilesSchema } from "../backup/backup.dto.js";
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
  createSiteMailbox,
  deleteSiteMailbox,
  listSiteMailboxes,
  listSites,
  purgeSite,
  purgeSiteBackup,
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
    const result = await enableSiteDb(slug);
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

  app.delete("/sites/:slug/mail/mailboxes/:address", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const address = String((req.params as { address?: string }).address ?? "").trim();
    if (!address) {
      throw new HttpError(400, "Mailbox address is required.");
    }
    const result = await deleteSiteMailbox(slug, address);
    return reply.send(result);
  });

  app.get("/sites/:slug/mail/mailboxes", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await listSiteMailboxes(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/enable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await enableSiteBackup(slug);
    return reply.send(result);
  });

  app.post("/sites/:slug/backup/disable", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await disableSiteBackup(slug);
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
