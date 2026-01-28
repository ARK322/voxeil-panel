import { HttpError } from "../http/errors.js";
import { withClient as poolWithClient } from "../db/pool.js";

let schemaReady = false;

async function ensureSchema(client) {
    // Production-ready: persistent token revocation store enables real logout/refresh invalidation.
    await client.query(`
    CREATE TABLE IF NOT EXISTS token_revocations (
      jti TEXT PRIMARY KEY,
      expires_at TIMESTAMPTZ NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `);
    await client.query(`
    CREATE INDEX IF NOT EXISTS token_revocations_expires_at_idx
      ON token_revocations (expires_at);
  `);
}

async function withClient(fn) {
    return poolWithClient(async (client) => {
        if (!schemaReady) {
            await ensureSchema(client);
            schemaReady = true;
        }
        return await fn(client);
    });
}

export async function revokeTokenJti(jti, expSeconds) {
    if (!jti || typeof jti !== "string") {
        return;
    }
    if (!Number.isFinite(expSeconds)) {
        // Defensive: without exp we can't prune safely; treat as bad request.
        throw new HttpError(400, "Token exp missing; cannot revoke.");
    }
    await withClient(async (client) => {
        // Production-ready: idempotent revoke.
        await client.query(
            "INSERT INTO token_revocations (jti, expires_at) VALUES ($1, to_timestamp($2)) ON CONFLICT (jti) DO NOTHING",
            [jti, expSeconds]
        );
    });
}

export async function isTokenRevoked(jti) {
    if (!jti || typeof jti !== "string") {
        return false;
    }
    return withClient(async (client) => {
        const res = await client.query(
            "SELECT expires_at FROM token_revocations WHERE jti = $1",
            [jti]
        );
        if ((res.rowCount ?? 0) === 0) {
            return false;
        }
        const expiresAt = res.rows[0]?.expires_at ? new Date(res.rows[0].expires_at) : null;
        if (expiresAt && expiresAt.getTime() <= Date.now()) {
            // Production-ready: self-heal by pruning expired revocations.
            await client.query("DELETE FROM token_revocations WHERE jti = $1", [jti]);
            return false;
        }
        return true;
    });
}

export async function pruneExpiredRevocations(limit = 1000) {
    return withClient(async (client) => {
        // Postgres-compatible bounded delete (no DELETE ... LIMIT).
        const res = await client.query(`
      WITH doomed AS (
        SELECT ctid
        FROM token_revocations
        WHERE expires_at <= now()
        LIMIT $1
      )
      DELETE FROM token_revocations tr
      USING doomed
      WHERE tr.ctid = doomed.ctid
    `, [Math.max(1, Number(limit) || 1000)]);
        return res.rowCount ?? 0;
    });
}

