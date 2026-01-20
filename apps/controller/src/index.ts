import Fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import { PassThrough } from "node:stream";
import { z } from "zod";
import { registerRoutes } from "./http/routes.js";
import { HttpError } from "./http/errors.js";
import { isIpAllowed, readAllowlist } from "./security/allowlist.js";
import { ensureAdminUserFromEnv } from "./users/user.service.js";

const TRUST_PROXY = process.env.TRUST_PROXY === "true";
const app = Fastify({ logger: true, trustProxy: TRUST_PROXY });
const metrics = {
  requests: 0,
  errors: 0
};

const ADMIN_API_KEY = process.env.ADMIN_API_KEY;
if (!ADMIN_API_KEY) {
  throw new Error("ADMIN_API_KEY env var is required (provided via Secret).");
}

function resolveClientIp(req: FastifyRequest): string | null {
  if (TRUST_PROXY) {
    const header = req.headers["x-forwarded-for"];
    const value = Array.isArray(header) ? header[0] : header;
    if (value) {
      return value.split(",")[0]?.trim() || null;
    }
  }
  return req.ip ?? null;
}

app.addHook("onRequest", async (req: FastifyRequest, reply: FastifyReply) => {
  const allowlist = await readAllowlist();
  if (allowlist.length > 0) {
    const clientIp = resolveClientIp(req);
    if (!clientIp || !isIpAllowed(clientIp, allowlist)) {
      return reply.code(403).send({ error: "forbidden" });
    }
  }
  if (
    req.url.startsWith("/health") ||
    req.url.startsWith("/auth") ||
    req.url.startsWith("/github/webhook")
  ) {
    return;
  }
  const sessionHeader = req.headers["x-session-token"];
  const sessionToken = Array.isArray(sessionHeader) ? sessionHeader[0] : sessionHeader;
  if (sessionToken) return;
  const header = req.headers["x-api-key"];
  const provided = Array.isArray(header) ? header[0] : header;
  if (!provided || provided !== ADMIN_API_KEY) {
    return reply.code(401).send({ error: "unauthorized" });
  }
});

app.addHook("onResponse", async (_req, reply) => {
  metrics.requests += 1;
  if (reply.statusCode >= 400) {
    metrics.errors += 1;
  }
});

app.addHook("preParsing", async (req, _reply, payload) => {
  if (!req.url.startsWith("/github/webhook")) return payload;
  const chunks: Buffer[] = [];
  for await (const chunk of payload) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  const body = Buffer.concat(chunks);
  (req as { rawBody?: Buffer }).rawBody = body;
  const stream = new PassThrough();
  stream.end(body);
  return stream;
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
app.get("/status", async () => ({
  ok: true,
  uptimeSeconds: Math.floor(process.uptime()),
  requests: metrics.requests,
  errors: metrics.errors
}));
app.get("/metrics", async (_req, reply) => {
  reply.header("Content-Type", "text/plain; version=0.0.4");
  return [
    `requests_total ${metrics.requests}`,
    `errors_total ${metrics.errors}`,
    `uptime_seconds ${Math.floor(process.uptime())}`
  ].join("\n");
});

registerRoutes(app);

await ensureAdminUserFromEnv();

const port = Number(process.env.PORT ?? 8080);
app.listen({ host: "0.0.0.0", port });
