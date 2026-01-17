import type { FastifyInstance } from "fastify";
import { CreateSiteSchema, PatchLimitsSchema } from "../sites/site.dto.js";
import { createSite, listSites, updateSiteLimits } from "../sites/site.service.js";

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
}
