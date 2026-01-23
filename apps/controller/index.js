import Fastify from "fastify";
import { PassThrough } from "node:stream";
import { z } from "zod";
import { registerRoutes } from "./http/routes.js";
import { HttpError } from "./http/errors.js";
import { isIpAllowed, readAllowlist } from "./security/allowlist.js";
import { ensureAdminUserFromEnv } from "./users/user.service.js";
import { verifyToken, extractTokenFromHeader } from "./auth/jwt.js";
const TRUST_PROXY = process.env.TRUST_PROXY === "true";
const app = Fastify({ logger: true, trustProxy: TRUST_PROXY });
const metrics = {
    requests: 0,
    errors: 0
};
function resolveClientIp(req) {
    if (TRUST_PROXY) {
        const header = req.headers["x-forwarded-for"];
        const value = Array.isArray(header) ? header[0] : header;
        if (value) {
            return value.split(",")[0]?.trim() || null;
        }
    }
    return req.ip ?? null;
}
app.addHook("onRequest", async (req, reply) => {
    const allowlist = await readAllowlist();
    if (allowlist.length > 0) {
        const clientIp = resolveClientIp(req);
        if (!clientIp || !isIpAllowed(clientIp, allowlist)) {
            return reply.code(403).send({ error: "forbidden" });
        }
    }
    if (req.url.startsWith("/health") ||
        req.url.startsWith("/auth/login") ||
        req.url.startsWith("/github/webhook")) {
        return;
    }
    const token = extractTokenFromHeader(req.headers);
    if (!token) {
        return reply.code(401).send({ error: "unauthorized" });
    }
    try {
        const payload = verifyToken(token);
        req.user = payload;
    } catch (error) {
        if (error instanceof HttpError) {
            return reply.code(error.statusCode).send({ error: error.message });
        }
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
    if (!req.url.startsWith("/github/webhook"))
        return payload;
    const chunks = [];
    for await (const chunk of payload) {
        chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
    const body = Buffer.concat(chunks);
    req.rawBody = body;
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
app.get("/health", async () => {
    const { Client } = await import("pg");
    const { getClients } = await import("./k8s/client.js");
    
    const checks = {
        db: false,
        k8s: false
    };
    
    try {
        const dbConfig = {
            host: process.env.POSTGRES_HOST,
            port: Number(process.env.POSTGRES_PORT ?? "5432"),
            user: process.env.POSTGRES_ADMIN_USER,
            password: process.env.POSTGRES_ADMIN_PASSWORD,
            database: process.env.POSTGRES_DB
        };
        if (dbConfig.host && dbConfig.user && dbConfig.password && dbConfig.database) {
            const client = new Client(dbConfig);
            await client.connect();
            await client.query("SELECT 1");
            await client.end();
            checks.db = true;
        }
    } catch (error) {
        checks.db = false;
    }
    
    try {
        const { core } = getClients();
        await core.listNamespace();
        checks.k8s = true;
    } catch (error) {
        checks.k8s = false;
    }
    
    const ok = checks.db && checks.k8s;
    return {
        ok,
        checks
    };
});
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
