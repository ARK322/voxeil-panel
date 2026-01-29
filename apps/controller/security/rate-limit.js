import { withClient as poolWithClient } from "../db/pool.js";

// Production-ready rate limiting:
// - default: in-memory (single instance)
// - optional: postgres (multi-instance) via RATE_LIMIT_STORE=postgres
const STORE_MODE = (process.env.RATE_LIMIT_STORE ?? "memory").toLowerCase();

// ---- Memory store (fallback) ----
const store = new Map(); // key -> { count, resetAt, lastSeen }
const PRUNE_INTERVAL_MS = Number(process.env.RATE_LIMIT_PRUNE_INTERVAL_MS ?? "60000"); // 1 minute
const MAX_ENTRIES = Number(process.env.RATE_LIMIT_MAX_ENTRIES ?? "10000");
let pruneInterval = null;
let signalsRegistered = false;

function registerSignalCleanupOnce() {
    if (signalsRegistered)
        return;
    signalsRegistered = true;
    const cleanup = () => {
        if (pruneInterval) {
            clearInterval(pruneInterval);
            pruneInterval = null;
        }
    };
    process.on("SIGTERM", cleanup);
    process.on("SIGINT", cleanup);
}

function startPruneInterval() {
    if (pruneInterval)
        return;
    registerSignalCleanupOnce();
    pruneInterval = setInterval(() => {
        void pruneRateLimitStore().catch(() => undefined);
    }, PRUNE_INTERVAL_MS);
}

function enforceMaxEntries(now) {
    if (store.size <= MAX_ENTRIES)
        return;
    // Production-ready: prune first, then evict oldest to cap memory usage deterministically.
    for (const [k, v] of store.entries()) {
        if (now >= v.resetAt) {
            store.delete(k);
        }
    }
    if (store.size <= MAX_ENTRIES)
        return;
    // Evict oldest by lastSeen.
    const entries = Array.from(store.entries()).sort((a, b) => (a[1].lastSeen ?? 0) - (b[1].lastSeen ?? 0));
    const toRemove = Math.max(0, store.size - MAX_ENTRIES);
    for (let i = 0; i < toRemove; i++) {
        store.delete(entries[i][0]);
    }
}

async function ensurePgSchema(client) {
    await client.query(`
    CREATE TABLE IF NOT EXISTS rate_limits (
      key TEXT PRIMARY KEY,
      count INTEGER NOT NULL,
      reset_at TIMESTAMPTZ NOT NULL
    );
  `);
    await client.query(`
    CREATE INDEX IF NOT EXISTS rate_limits_reset_at_idx
      ON rate_limits (reset_at);
  `);
}

let pgSchemaReady = false;
async function withPgClient(fn) {
    return poolWithClient(async (client) => {
        if (!pgSchemaReady) {
            await ensurePgSchema(client);
            pgSchemaReady = true;
        }
        return await fn(client);
    });
}

export async function checkRateLimit(key, config) {
    const limit = Math.max(1, Number(config?.limit) || 1);
    const windowMs = Math.max(1, Number(config?.windowMs) || 1);

    if (STORE_MODE === "postgres") {
        // Production-ready: multi-instance safe store (Postgres).
        const row = await withPgClient(async (client) => {
            const res = await client.query(`
        WITH upsert AS (
          INSERT INTO rate_limits (key, count, reset_at)
          VALUES ($1, 1, now() + ($2 * interval '1 millisecond'))
          ON CONFLICT (key) DO UPDATE SET
            count = CASE
              WHEN rate_limits.reset_at <= now() THEN 1
              ELSE LEAST(rate_limits.count + 1, $3)
            END,
            reset_at = CASE
              WHEN rate_limits.reset_at <= now() THEN EXCLUDED.reset_at
              ELSE rate_limits.reset_at
            END
          RETURNING count, reset_at
        )
        SELECT count, reset_at FROM upsert;
      `, [key, windowMs, limit]);
            return res.rows[0];
        });
        const count = Number(row?.count ?? 0);
        const resetAtMs = row?.reset_at ? new Date(row.reset_at).getTime() : Date.now() + windowMs;
        const allowed = count <= limit;
        return { allowed, remaining: Math.max(0, limit - count), resetAt: resetAtMs };
    }

    // Default: memory store.
    startPruneInterval();
    const now = Date.now();
    enforceMaxEntries(now);

    const entry = store.get(key);
    if (!entry || now >= entry.resetAt) {
        store.set(key, { count: 1, resetAt: now + windowMs, lastSeen: now });
        return { allowed: true, remaining: limit - 1, resetAt: now + windowMs };
    }
    entry.lastSeen = now;
    if (entry.count >= limit) {
        return { allowed: false, remaining: 0, resetAt: entry.resetAt };
    }
    entry.count += 1;
    return { allowed: true, remaining: limit - entry.count, resetAt: entry.resetAt };
}

export async function pruneRateLimitStore() {
    if (STORE_MODE === "postgres") {
        // Production-ready: prune expired keys.
        return withPgClient(async (client) => {
            const res = await client.query("DELETE FROM rate_limits WHERE reset_at <= now()");
            return res.rowCount ?? 0;
        });
    }

    const now = Date.now();
    let pruned = 0;
    for (const [key, entry] of store.entries()) {
        if (now >= entry.resetAt) {
            store.delete(key);
            pruned++;
        }
    }
    return pruned;
}

export function getRateLimitStats() {
    return {
        mode: STORE_MODE,
        entries: STORE_MODE === "postgres" ? null : store.size,
        maxSize: MAX_ENTRIES
    };
}

// Auto-cleanup mechanism
let cleanupInterval = null;

/**
 * Start automatic rate limit store cleanup
 */
export function startAutoCleanup() {
    if (cleanupInterval) {
        return; // Already started
    }
    
    const intervalMs = Number(process.env.RATE_LIMIT_CLEANUP_INTERVAL_MS ?? "300000"); // 5 min
    
    cleanupInterval = setInterval(() => {
        pruneRateLimitStore().catch((err) => {
            console.error("Failed to prune rate limit store:", err);
        });
    }, intervalMs);
    
    console.info("Rate limit auto-cleanup started (interval: %dms)", intervalMs);
}

/**
 * Stop automatic cleanup
 */
export function stopAutoCleanup() {
    if (cleanupInterval) {
        clearInterval(cleanupInterval);
        cleanupInterval = null;
        console.info("Rate limit auto-cleanup stopped");
    }
}