import { randomBytes } from "node:crypto";
import { Client } from "pg";
import { HttpError } from "../http/errors.js";
const DEFAULT_DB_NAME_PREFIX = "db_";
const DEFAULT_DB_USER_PREFIX = "u_";
function requireAdminConfig() {
    const host = process.env.POSTGRES_HOST?.trim() ?? process.env.DB_HOST?.trim();
    const port = Number(process.env.POSTGRES_PORT ?? process.env.DB_PORT ?? "5432");
    const user = process.env.POSTGRES_ADMIN_USER?.trim() ?? process.env.DB_ADMIN_USER?.trim();
    const password = process.env.POSTGRES_ADMIN_PASSWORD?.trim() ?? process.env.DB_ADMIN_PASSWORD?.trim();
    const database = process.env.POSTGRES_DB?.trim() || "postgres";
    if (!host || !user || !password) {
        throw new HttpError(500, "Postgres admin configuration missing.");
    }
    if (!Number.isInteger(port) || port <= 0) {
        throw new HttpError(500, "POSTGRES_PORT must be a positive integer.");
    }
    return { host, port, user, password, database };
}
function quoteIdent(value) {
    return `"${value.replace(/"/g, "\"\"")}"`;
}
function normalizeIdentifier(value, label) {
    const normalized = value.trim().toLowerCase();
    if (!/^[a-z0-9_]+$/.test(normalized)) {
        throw new HttpError(400, `${label} must match [a-z0-9_]+.`);
    }
    return normalized;
}
function normalizePrefix(value, label) {
    const normalized = value.trim().toLowerCase();
    if (!/^[a-z0-9_]*$/.test(normalized)) {
        throw new HttpError(500, `${label} must match [a-z0-9_]*.`);
    }
    return normalized;
}
export function normalizeSlugIdentifier(slug) {
    const normalized = slug.trim().toLowerCase().replace(/-/g, "_");
    return normalizeIdentifier(normalized, "slug");
}
export function normalizeDbName(value) {
    return normalizeIdentifier(value, "dbName");
}
export function normalizeDbUser(value) {
    return normalizeIdentifier(value, "dbUser");
}
export function resolveDbNamePrefix() {
    const prefix = process.env.DB_NAME_PREFIX?.trim() || DEFAULT_DB_NAME_PREFIX;
    return normalizePrefix(prefix, "DB_NAME_PREFIX");
}
export function resolveDbUserPrefix() {
    const prefix = process.env.DB_USER_PREFIX?.trim() || DEFAULT_DB_USER_PREFIX;
    return normalizePrefix(prefix, "DB_USER_PREFIX");
}
export function resolveDbName(slug) {
    const safeSlug = normalizeSlugIdentifier(slug);
    return normalizeDbName(`${resolveDbNamePrefix()}${safeSlug}`);
}
export function resolveDbUser(slug) {
    const safeSlug = normalizeSlugIdentifier(slug);
    return normalizeDbUser(`${resolveDbUserPrefix()}${safeSlug}`);
}
export function generateDbPassword() {
    return randomBytes(32).toString("base64url");
}
async function withAdminClient(fn) {
    const config = requireAdminConfig();
    const client = new Client({
        host: config.host,
        port: config.port,
        user: config.user,
        password: config.password,
        database: config.database
    });
    await client.connect();
    try {
        return await fn(client);
    }
    finally {
        await client.end();
    }
}
export async function ensureRole(username, password) {
    const safeUser = normalizeDbUser(username);
    return withAdminClient(async (client) => {
        const roleResult = await client.query("SELECT 1 FROM pg_roles WHERE rolname = $1", [safeUser]);
        const roleExists = (roleResult.rowCount ?? 0) > 0;
        if (roleExists) {
            await client.query(`ALTER ROLE ${quoteIdent(safeUser)} PASSWORD $1`, [password]);
            return { created: false };
        }
        await client.query(`CREATE ROLE ${quoteIdent(safeUser)} LOGIN PASSWORD $1`, [password]);
        return { created: true };
    });
}
export async function ensureDatabase(dbName, ownerUser) {
    const safeDb = normalizeDbName(dbName);
    const safeOwner = normalizeDbUser(ownerUser);
    return withAdminClient(async (client) => {
        const dbResult = await client.query("SELECT 1 FROM pg_database WHERE datname = $1", [safeDb]);
        const dbExists = (dbResult.rowCount ?? 0) > 0;
        if (!dbExists) {
            await client.query(`CREATE DATABASE ${quoteIdent(safeDb)} OWNER ${quoteIdent(safeOwner)}`);
        }
        else {
            await client.query(`ALTER DATABASE ${quoteIdent(safeDb)} OWNER TO ${quoteIdent(safeOwner)}`);
        }
        await client.query(`REVOKE ALL ON DATABASE ${quoteIdent(safeDb)} FROM PUBLIC`);
        await client.query(`GRANT ALL PRIVILEGES ON DATABASE ${quoteIdent(safeDb)} TO ${quoteIdent(safeOwner)}`);
        const dbList = await client.query("SELECT datname FROM pg_database WHERE datallowconn = true");
        for (const row of dbList.rows) {
            if (row.datname === safeDb)
                continue;
            await client.query(`REVOKE CONNECT ON DATABASE ${quoteIdent(row.datname)} FROM ${quoteIdent(safeOwner)}`);
        }
        return { created: !dbExists };
    });
}
export async function revokeAndTerminate(dbName) {
    const safeDb = normalizeDbName(dbName);
    await withAdminClient(async (client) => {
        const dbResult = await client.query("SELECT 1 FROM pg_database WHERE datname = $1", [safeDb]);
        if ((dbResult.rowCount ?? 0) === 0)
            return;
        await client.query(`REVOKE CONNECT ON DATABASE ${quoteIdent(safeDb)} FROM PUBLIC`);
        await client.query("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1", [
            safeDb
        ]);
    });
}
export async function dropDatabase(dbName) {
    const safeDb = normalizeDbName(dbName);
    await withAdminClient(async (client) => {
        await client.query(`DROP DATABASE IF EXISTS ${quoteIdent(safeDb)}`);
    });
}
export async function dropRole(username) {
    const safeUser = normalizeDbUser(username);
    await withAdminClient(async (client) => {
        await client.query(`DROP ROLE IF EXISTS ${quoteIdent(safeUser)}`);
    });
}
