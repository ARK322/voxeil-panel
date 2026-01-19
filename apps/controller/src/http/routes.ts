import type { FastifyInstance } from "fastify";
import { z } from "zod";
import {
  CreateSiteSchema,
  DeploySiteSchema,
  PatchLimitsSchema,
  PatchTlsSchema
} from "../sites/site.dto.js";
import {
  createSite,
  deleteSite,
  deploySite,
  listSites,
  updateSiteTls,
  updateSiteLimits
} from "../sites/site.service.js";

const SlugParamSchema = z.string().min(1, "Slug is required.");

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

  app.delete("/sites/:slug", async (req, reply) => {
    const slug = SlugParamSchema.parse((req.params as { slug?: string }).slug ?? "");
    const result = await deleteSite(slug);
    return reply.code(200).send({ ok: true, slug: result.slug });
  });
}
