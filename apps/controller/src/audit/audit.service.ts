import crypto from "node:crypto";
import { Client } from "pg";
import { HttpError } from "../http/errors.js";

export type AuditEntry = {
  action: string;
  actorUserId?: string | null;
  actorUsername?: string | null;
  target?: string | null;
  ip?: string | null;
  meta?: Record<string, unknown> | null;
};

let schemaReady = false;

function requireEnv(name: string): string {
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

async function withClient<T>(fn: (client: Client) => Promise<T>): Promise<T> {
  const client = new Client(dbConfig());
  await client.connect();
  try {
    if (!schemaReady) {
      await ensureSchema(client);
      schemaReady = true;
    }
    return await fn(client);
  } finally {
    await client.end();
  }
}

async function ensureSchema(client: Client): Promise<void> {
  await client.query(`
    CREATE TABLE IF NOT EXISTS panel_audit_logs (
      id TEXT PRIMARY KEY,
      action TEXT NOT NULL,
      actor_user_id TEXT,
      actor_username TEXT,
      target TEXT,
      ip TEXT,
      meta JSONB,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `);
  await client.query(`
    CREATE INDEX IF NOT EXISTS panel_audit_logs_action_idx
    ON panel_audit_logs (action, created_at DESC);
  `);
}

export async function logAudit(entry: AuditEntry): Promise<void> {
  const payload = {
    id: crypto.randomUUID(),
    action: entry.action,
    actorUserId: entry.actorUserId ?? null,
    actorUsername: entry.actorUsername ?? null,
    target: entry.target ?? null,
    ip: entry.ip ?? null,
    meta: entry.meta ?? null
  };
  await withClient(async (client) => {
    await client.query(
      `INSERT INTO panel_audit_logs (id, action, actor_user_id, actor_username, target, ip, meta)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [
        payload.id,
        payload.action,
        payload.actorUserId,
        payload.actorUsername,
        payload.target,
        payload.ip,
        payload.meta ? JSON.stringify(payload.meta) : null
      ]
    );
  });
}
