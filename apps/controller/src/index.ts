import Fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import { z } from "zod";
import { registerRoutes } from "./http/routes.js";
import { HttpError } from "./http/errors.js";
import { ensureAdminUserFromEnv } from "./users/user.service.js";

const app = Fastify({ logger: true });

const ADMIN_API_KEY = process.env.ADMIN_API_KEY;
if (!ADMIN_API_KEY) {
  throw new Error("ADMIN_API_KEY env var is required (provided via Secret).");
}

app.addHook("onRequest", async (req: FastifyRequest, reply: FastifyReply) => {
  if (req.url.startsWith("/health") || req.url.startsWith("/auth")) return;
  const sessionHeader = req.headers["x-session-token"];
  const sessionToken = Array.isArray(sessionHeader) ? sessionHeader[0] : sessionHeader;
  if (sessionToken) return;
  const header = req.headers["x-api-key"];
  const provided = Array.isArray(header) ? header[0] : header;
  if (!provided || provided !== ADMIN_API_KEY) {
    return reply.code(401).send({ error: "unauthorized" });
  }
});

app.setErrorHandler((error, _req, reply) => {
  if (error instanceof HttpError) {
    return reply.code(error.statusCode).send({ error: error.message });
  }
  if (error instanceof z.ZodError) {
    return reply.code(400).send({ error: "invalid_request", details: error.flatten() });
  }
  app.log.error({ err: error }, "Unhandled error");
  return reply.code(500).send({ error: "internal_error" });
});

app.get("/health", async () => ({ ok: true }));

registerRoutes(app);

await ensureAdminUserFromEnv();

const port = Number(process.env.PORT ?? 8080);
app.listen({ host: "0.0.0.0", port });
