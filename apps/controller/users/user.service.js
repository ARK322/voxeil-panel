import crypto from "node:crypto";
import { promisify } from "node:util";
import { HttpError } from "../http/errors.js";
import { withClient as poolWithClient } from "../db/pool.js";
const scryptAsync = promisify(crypto.scrypt);
let schemaReady = false;

// Use shared connection pool (production-ready: prevents connection exhaustion)
async function withClient(fn) {
    return poolWithClient(async (client) => {
        if (!schemaReady) {
            await ensureSchema(client);
            schemaReady = true;
        }
        return await fn(client);
    });
}
async function ensureSchema(client) {
    await client.query(`
    CREATE TABLE IF NOT EXISTS panel_users (
      id TEXT PRIMARY KEY,
      username TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      email TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('admin', 'user')),
      status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'error')),
      active BOOLEAN NOT NULL DEFAULT true,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `);
}
async function hashPassword(password) {
    const salt = crypto.randomBytes(16).toString("hex");
    const hash = (await scryptAsync(password, salt, 64));
    return `${salt}:${hash.toString("hex")}`;
}
async function verifyPassword(password, stored) {
    const [salt, hashHex] = stored.split(":");
    if (!salt || !hashHex) {
        return false;
    }
    const hash = (await scryptAsync(password, salt, 64));
    return crypto.timingSafeEqual(Buffer.from(hashHex, "hex"), hash);
}
function mapRow(row) {
    return {
        id: row.id,
        username: row.username,
        email: row.email,
        role: row.role,
        status: row.status ?? "pending",
        active: row.active,
        createdAt: row.created_at
    };
}
export async function ensureAdminUserFromEnv() {
    const username = process.env.PANEL_ADMIN_USERNAME?.trim();
    const password = process.env.PANEL_ADMIN_PASSWORD?.trim();
    const email = process.env.PANEL_ADMIN_EMAIL?.trim();
    if (!username || !password || !email) {
        return;
    }
    await withClient(async (client) => {
        const existing = await client.query("SELECT id, password_hash FROM panel_users WHERE username = $1", [username]);
        if (existing.rowCount === 0) {
            const passwordHash = await hashPassword(password);
            await client.query(`INSERT INTO panel_users (id, username, password_hash, email, role, status, active)
         VALUES ($1, $2, $3, $4, 'admin', 'active', true)`, [crypto.randomUUID(), username, passwordHash, email]);
            return;
        }
        const current = existing.rows[0];
        const matches = await verifyPassword(password, current.password_hash);
        if (!matches) {
            const passwordHash = await hashPassword(password);
            await client.query("UPDATE panel_users SET password_hash = $1, email = $2 WHERE id = $3", [passwordHash, email, current.id]);
        }
        else {
            await client.query("UPDATE panel_users SET email = $1 WHERE id = $2", [email, current.id]);
        }
    });
}
export async function listUsers() {
    return withClient(async (client) => {
        const result = await client.query(`SELECT id, username, email, role, status, active, created_at
       FROM panel_users
       ORDER BY role, username`);
        return result.rows.map(mapRow);
    });
}
export async function createUser(input) {
    const passwordHash = await hashPassword(input.password);
    const id = crypto.randomUUID();
    return withClient(async (client) => {
        try {
            const result = await client.query(`INSERT INTO panel_users (id, username, password_hash, email, role, status, active)
         VALUES ($1, $2, $3, $4, $5, 'pending', true)
         RETURNING id, username, email, role, status, active, created_at`, [id, input.username, passwordHash, input.email, input.role]);
            return mapRow(result.rows[0]);
        }
        catch (error) {
            if (error?.code === "23505") {
                throw new HttpError(409, "Username already exists.");
            }
            throw error;
        }
    });
}

export async function updateUserStatus(id, status) {
    return withClient(async (client) => {
        const result = await client.query(`UPDATE panel_users
       SET status = $1
       WHERE id = $2
       RETURNING id, username, email, role, status, active, created_at`, [status, id]);
        if (result.rowCount === 0) {
            throw new HttpError(404, "User not found.");
        }
        return mapRow(result.rows[0]);
    });
}

export async function getUserById(id) {
    return withClient(async (client) => {
        const result = await client.query(`SELECT id, username, email, role, status, active, created_at
       FROM panel_users
       WHERE id = $1`, [id]);
        if (result.rowCount === 0) {
            throw new HttpError(404, "User not found.");
        }
        return mapRow(result.rows[0]);
    });
}
export async function setUserActive(id, active) {
    return withClient(async (client) => {
        const result = await client.query(`UPDATE panel_users
       SET active = $1
       WHERE id = $2
       RETURNING id, username, email, role, status, active, created_at`, [active, id]);
        if (result.rowCount === 0) {
            throw new HttpError(404, "User not found.");
        }
        return mapRow(result.rows[0]);
    });
}
export async function deleteUser(id) {
    await withClient(async (client) => {
        const result = await client.query("DELETE FROM panel_users WHERE id = $1", [id]);
        if (result.rowCount === 0) {
            throw new HttpError(404, "User not found.");
        }
    });
}
export async function verifyUserCredentials(username, password) {
    return withClient(async (client) => {
        const result = await client.query(`SELECT id, username, email, role, status, active, created_at, password_hash
       FROM panel_users
       WHERE username = $1`, [username]);
        if (result.rowCount === 0) {
            throw new HttpError(401, "Invalid credentials.");
        }
        const row = result.rows[0];
        if (!row.active) {
            throw new HttpError(403, "User is disabled.");
        }
        const matches = await verifyPassword(password, row.password_hash);
        if (!matches) {
            throw new HttpError(401, "Invalid credentials.");
        }
        return mapRow(row);
    });
}
