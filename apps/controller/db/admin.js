import { randomBytes } from "node:crypto";
import { Client } from "pg";
import { HttpError } from "../http/errors.js";
const DEFAULT_DB_NAME_PREFIX = "db_";
const DEFAULT_DB_USER_PREFIX = "u_";
function requireAdminConfig() {
    const host = process.env.DB_HOST?.trim();
    const port = Number(process.env.DB_PORT ?? "5432");
    const user = process.env.DB_ADMIN_USER?.trim();
    const password = process.env.DB_ADMIN_PASSWORD?.trim();
    if (!host || !user || !password) {
        throw new HttpError(500, "DB admin configuration missing.");
    }
    if (!Number.isInteger(port) || port <= 0) {
        throw new HttpError(500, "DB_PORT must be a positive integer.");
    }
    return { host, port, user, password };
}
function quoteIdent(value) {
    return `"${value.replace(/"/g, "\"\"")}"`;
}
export function resolveDbNamePrefix() {
    return process.env.DB_NAME_PREFIX?.trim() || DEFAULT_DB_NAME_PREFIX;
}
export function resolveDbUserPrefix() {
    return process.env.DB_USER_PREFIX?.trim() || DEFAULT_DB_USER_PREFIX;
}
export function resolveDbName(slug) {
    return `${resolveDbNamePrefix()}${slug}`;
}
export function resolveDbUser(slug) {
    return `${resolveDbUserPrefix()}${slug}`;
}
export function generateDbPassword() {
    return randomBytes(32).toString("base64url");
}
export async function ensureDatabaseAndRole(options) {
    const config = requireAdminConfig();
    const client = new Client({
        host: config.host,
        port: config.port,
        user: config.user,
        password: config.password,
        database: "postgres"
    });
    await client.connect();
    try {
        const roleResult = await client.query("SELECT 1 FROM pg_roles WHERE rolname = $1", [
            options.dbUser
        ]);
        const roleExists = (roleResult.rowCount ?? 0) > 0;
        let userCreated = false;
        if (!roleExists) {
            if (!options.passwordToSet) {
                throw new HttpError(500, "DB user password missing for creation.");
            }
            await client.query(`CREATE ROLE ${quoteIdent(options.dbUser)} LOGIN PASSWORD $1`, [options.passwordToSet]);
            userCreated = true;
        }
        else if (options.passwordToSet && options.setPasswordForExisting) {
            await client.query(`ALTER ROLE ${quoteIdent(options.dbUser)} PASSWORD $1`, [options.passwordToSet]);
        }
        const dbResult = await client.query("SELECT 1 FROM pg_database WHERE datname = $1", [options.dbName]);
        const dbExists = (dbResult.rowCount ?? 0) > 0;
        let dbCreated = false;
        if (!dbExists) {
            await client.query(`CREATE DATABASE ${quoteIdent(options.dbName)} OWNER ${quoteIdent(options.dbUser)}`);
            dbCreated = true;
        }
        else {
            await client.query(`ALTER DATABASE ${quoteIdent(options.dbName)} OWNER TO ${quoteIdent(options.dbUser)}`);
        }
        await client.query(`REVOKE ALL ON DATABASE ${quoteIdent(options.dbName)} FROM PUBLIC`);
        await client.query(`GRANT ALL PRIVILEGES ON DATABASE ${quoteIdent(options.dbName)} TO ${quoteIdent(options.dbUser)}`);
        const dbList = await client.query("SELECT datname FROM pg_database WHERE datallowconn = true");
        for (const row of dbList.rows) {
            if (row.datname === options.dbName) {
                continue;
            }
            await client.query(`REVOKE CONNECT ON DATABASE ${quoteIdent(row.datname)} FROM ${quoteIdent(options.dbUser)}`);
        }
        return { userCreated, dbCreated };
    }
    finally {
        await client.end();
    }
}
export async function dropDatabaseAndRole(options) {
    const config = requireAdminConfig();
    const client = new Client({
        host: config.host,
        port: config.port,
        user: config.user,
        password: config.password,
        database: "postgres"
    });
    await client.connect();
    try {
        await client.query("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1", [
            options.dbName
        ]);
        await client.query(`DROP DATABASE IF EXISTS ${quoteIdent(options.dbName)}`);
        await client.query(`DROP ROLE IF EXISTS ${quoteIdent(options.dbUser)}`);
    }
    finally {
        await client.end();
    }
}
