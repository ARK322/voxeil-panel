import Fastify from "fastify";
import { PassThrough } from "node:stream";
import crypto from "node:crypto";
import { z } from "zod";
import { registerRoutes } from "./http/routes.js";
import { HttpError } from "./http/errors.js";
import { isIpAllowed, readAllowlist } from "./security/allowlist.js";
import { ensureAdminUserFromEnv } from "./users/user.service.js";
import { verifyToken, extractTokenFromHeader } from "./auth/jwt.js";
import { checkPoolHealth, closePool } from "./db/pool.js";
const TRUST_PROXY = process.env.TRUST_PROXY === "true";
const isProduction = process.env.NODE_ENV === "production";

// Production-ready: structured JSON logging + security config
const app = Fastify({
    logger: {
        level: process.env.LOG_LEVEL ?? (isProduction ? "info" : "debug"),
        serializers: {
            req: (req) => ({
                method: req.method,
                url: req.url,
                ip: req.ip,
                userAgent: req.headers["user-agent"]
            }),
            res: (res) => ({
                statusCode: res.statusCode
            }),
            err: (err) => ({
                type: err.constructor.name,
                message: err.message,
                stack: isProduction ? undefined : err.stack
            })
        }
    },
    trustProxy: TRUST_PROXY,
    requestIdLogLabel: "requestId",
    requestIdHeader: "x-request-id",
    disableRequestLogging: false,
    // Production-ready: request size limits (prevent DoS)
    bodyLimit: Number(process.env.REQUEST_BODY_LIMIT_BYTES ?? "1048576") // 1MB default
});
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
// Production-ready security headers middleware
app.addHook("onRequest", async (req, reply) => {
    // Security headers (production-ready)
    reply.header("X-Content-Type-Options", "nosniff");
    reply.header("X-Frame-Options", "DENY");
    reply.header("Referrer-Policy", "strict-origin-when-cross-origin");
    reply.header("Permissions-Policy", "geolocation=(), microphone=(), camera=()");
    // API-only service: safest CSP is deny-all.
    reply.header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
    if (isProduction) {
        reply.header("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
    }
    
    // Request timeout (production-ready: prevents hanging requests)
    const requestTimeout = Number(process.env.REQUEST_TIMEOUT_MS ?? "30000"); // 30s default
    req.requestTimeout = setTimeout(() => {
        if (!reply.sent) {
            reply.code(408).send({ error: "request_timeout" });
        }
    }, requestTimeout);
    
    const allowlist = await readAllowlist();
    if (allowlist.length > 0) {
        const clientIp = resolveClientIp(req);
        if (!clientIp || !isIpAllowed(clientIp, allowlist)) {
            clearTimeout(req.requestTimeout);
            return reply.code(403).send({ error: "forbidden" });
        }
    }
    if (req.url.startsWith("/health") ||
        req.url.startsWith("/auth/login") ||
        req.url.startsWith("/github/webhook") ||
        req.url.startsWith("/metrics")) {
        return;
    }
    const token = extractTokenFromHeader(req.headers);
    if (!token) {
        clearTimeout(req.requestTimeout);
        return reply.code(401).send({ error: "unauthorized" });
    }
    try {
        const payload = await verifyToken(token);
        req.user = payload;
        // Production-ready: expose token metadata to handlers (logout/refresh revocation).
        req.auth = { token, payload };
    } catch (error) {
        clearTimeout(req.requestTimeout);
        if (error instanceof HttpError) {
            return reply.code(error.statusCode).send({ error: error.message });
        }
        return reply.code(401).send({ error: "unauthorized" });
    }
});

// Clear timeout on response (production-ready)
app.addHook("onResponse", async (req, reply) => {
    if (req.requestTimeout) {
        clearTimeout(req.requestTimeout);
    }
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
// Production-ready error handler: tracks error IDs, hides stack traces in production
app.setErrorHandler((error, req, reply) => {
    const errorId = crypto.randomUUID();
    const isProduction = process.env.NODE_ENV === "production";
    
    // Structured error logging (production-ready)
    app.log.error({
        err: error,
        errorId,
        path: req.url,
        method: req.method,
        ip: req.ip,
        userId: req.user?.sub,
        stack: isProduction ? undefined : error.stack
    }, "Request error");
    
    if (error instanceof HttpError) {
        return reply.code(error.statusCode).send({
            error: error.message,
            ...(isProduction ? { errorId } : { errorId, details: error.stack })
        });
    }
    
    if (error instanceof z.ZodError) {
        return reply.code(400).send({
            error: "invalid_request",
            details: error.flatten(),
            ...(isProduction ? { errorId } : { errorId })
        });
    }
    
    // Generic error: never expose stack trace in production
    return reply.code(500).send({
        error: "internal_error",
        ...(isProduction ? { errorId } : { errorId, message: error.message })
    });
});
// Production-ready health check: uses connection pool, includes timeout
app.get("/health", async (req, reply) => {
    const timeout = Number(process.env.HEALTH_CHECK_TIMEOUT_MS ?? "5000");
    const startTime = Date.now();
    
    const checks = {
        db: false,
        k8s: false,
        pool: null
    };
    
    // Check database pool health (production-ready: uses pool, not new connection)
    try {
        const poolHealth = await Promise.race([
            checkPoolHealth(),
            new Promise((_, reject) => setTimeout(() => reject(new Error("Timeout")), timeout))
        ]);
        checks.db = poolHealth.healthy;
        checks.pool = poolHealth;
    } catch (error) {
        checks.db = false;
        app.log.warn({ err: error }, "Database health check failed");
    }
    
    // Check Kubernetes API
    try {
        const { getClients } = await import("./k8s/client.js");
        const k8sCheck = await Promise.race([
            (async () => {
                const { core } = getClients();
                await core.listNamespace();
                return true;
            })(),
            new Promise((_, reject) => setTimeout(() => reject(new Error("Timeout")), timeout))
        ]);
        checks.k8s = k8sCheck === true;
    } catch (error) {
        checks.k8s = false;
        app.log.warn({ err: error }, "Kubernetes health check failed");
    }
    
    const ok = checks.db && checks.k8s;
    const statusCode = ok ? 200 : 503;
    
    if (!ok) {
        reply.code(statusCode);
    }
    
    return {
        ok,
        checks,
        responseTimeMs: Date.now() - startTime
    };
});
app.get("/status", async () => ({
    ok: true,
    uptimeSeconds: Math.floor(process.uptime()),
    requests: metrics.requests,
    errors: metrics.errors
}));
// Production-ready Prometheus metrics endpoint
app.get("/metrics", async (_req, reply) => {
    reply.header("Content-Type", "text/plain; version=0.0.4");
    
    const { getRateLimitStats } = await import("./security/rate-limit.js");
    const rateLimitStats = getRateLimitStats();
    const poolHealth = await checkPoolHealth().catch(() => ({ healthy: false }));
    
    const metricsLines = [
        `# HELP requests_total Total number of HTTP requests`,
        `# TYPE requests_total counter`,
        `requests_total ${metrics.requests}`,
        ``,
        `# HELP errors_total Total number of HTTP errors`,
        `# TYPE errors_total counter`,
        `errors_total ${metrics.errors}`,
        ``,
        `# HELP uptime_seconds Application uptime in seconds`,
        `# TYPE uptime_seconds gauge`,
        `uptime_seconds ${Math.floor(process.uptime())}`,
        ``,
        `# HELP rate_limit_entries Current number of rate limit entries`,
        `# TYPE rate_limit_entries gauge`,
        `rate_limit_entries ${rateLimitStats.entries}`,
        ``,
        `# HELP db_pool_total Database connection pool total connections`,
        `# TYPE db_pool_total gauge`,
        `db_pool_total ${poolHealth.totalCount ?? 0}`,
        ``,
        `# HELP db_pool_idle Database connection pool idle connections`,
        `# TYPE db_pool_idle gauge`,
        `db_pool_idle ${poolHealth.idleCount ?? 0}`,
        ``,
        `# HELP db_pool_waiting Database connection pool waiting requests`,
        `# TYPE db_pool_waiting gauge`,
        `db_pool_waiting ${poolHealth.waitingCount ?? 0}`,
        ``,
        `# HELP db_pool_healthy Database connection pool health status`,
        `# TYPE db_pool_healthy gauge`,
        `db_pool_healthy ${poolHealth.healthy ? 1 : 0}`
    ];
    
    return metricsLines.join("\n");
});
registerRoutes(app);
await ensureAdminUserFromEnv();
const port = Number(process.env.PORT ?? 8080);

// Production-ready: graceful shutdown closes HTTP server + DB pools cleanly.
async function shutdown(signal) {
    try {
        app.log.info({ signal }, "Shutting down");
        await app.close();
    } catch (err) {
        app.log.error({ err, signal }, "Shutdown error");
    } finally {
        await closePool().catch((err) => app.log.error({ err }, "Failed to close DB pools"));
        process.exit(0);
    }
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("unhandledRejection", (err) => {
    app.log.error({ err }, "Unhandled promise rejection");
});
process.on("uncaughtException", (err) => {
    app.log.fatal({ err }, "Uncaught exception");
    void shutdown("uncaughtException");
});

app.listen({ host: "0.0.0.0", port });
