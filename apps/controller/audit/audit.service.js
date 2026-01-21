import crypto from "node:crypto";
import { Client } from "pg";
import { HttpError } from "../http/errors.js";
let schemaReady = false;
function requireEnv(name) {
    const value = process.env[name];
    if (!value) {
        throw new HttpError(500, `${name} is required.`);
    }
    return value;
}
function dbConfig() {
    return {
        host: requireEnv("POSTGRES_HOST"),
        port: Number(process.env.POSTGRES_PORT ?? "5432"),
        user: requireEnv("POSTGRES_ADMIN_USER"),
        password: requireEnv("POSTGRES_ADMIN_PASSWORD"),
        database: requireEnv("POSTGRES_DB")
    };
}
async function withClient(fn) {
    const client = new Client(dbConfig());
    await client.connect();
    try {
        if (!schemaReady) {
            await ensureSchema(client);
            schemaReady = true;
        }
        return await fn(client);
    }
    finally {
        await client.end();
    }
}
async function ensureSchema(client) {
    await client.query(`
    CREATE TABLE IF NOT EXISTS panel_audit_logs (
      id TEXT PRIMARY KEY,
      action TEXT NOT NULL,
      actor_user_id TEXT,
      actor_username TEXT,
      target_type TEXT,
      target_id TEXT,
      target TEXT,
      ip TEXT,
      success BOOLEAN,
      error TEXT,
      meta JSONB,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `);
    await client.query(`
    CREATE INDEX IF NOT EXISTS panel_audit_logs_action_idx
    ON panel_audit_logs (action, created_at DESC);
  `);
}
export async function logAudit(entry) {
    const payload = {
        id: crypto.randomUUID(),
        action: entry.action,
        actorUserId: entry.actorUserId ?? null,
        actorUsername: entry.actorUsername ?? null,
        targetType: entry.targetType ?? null,
        targetId: entry.targetId ?? entry.target ?? null,
        target: entry.target ?? null,
        ip: entry.ip ?? null,
        success: entry.success ?? true,
        error: entry.error ?? null,
        meta: entry.meta ?? null
    };
    await withClient(async (client) => {
        await client.query(`INSERT INTO panel_audit_logs (id, action, actor_user_id, actor_username, target_type, target_id, target, ip, success, error, meta)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`, [
            payload.id,
            payload.action,
            payload.actorUserId,
            payload.actorUsername,
            payload.targetType,
            payload.targetId,
            payload.target,
            payload.ip,
            payload.success,
            payload.error,
            payload.meta ? JSON.stringify(payload.meta) : null
        ]);
    });
}
