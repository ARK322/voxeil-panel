import { Pool } from "pg";
import { HttpError } from "../http/errors.js";
import { logger } from "../config/logger.js";
import { parseEnvNumber } from "../config/env.js";

// Shared database pool for all services
// Production-ready: connection pooling prevents connection exhaustion
let pool = null;
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
        port: parseEnvNumber("POSTGRES_PORT", 5432, { min: 1, max: 65535 }),
        user: requireEnv("POSTGRES_ADMIN_USER"),
        password: requireEnv("POSTGRES_ADMIN_PASSWORD"),
        database: requireEnv("POSTGRES_DB"),
        max: parseEnvNumber("DB_POOL_MAX", 20, { min: 1, max: 100 }),
        min: parseEnvNumber("DB_POOL_MIN", 2, { min: 0, max: 50 }),
        idleTimeoutMillis: parseEnvNumber("DB_POOL_IDLE_TIMEOUT", 30000, { min: 1000 }),
        connectionTimeoutMillis: parseEnvNumber("DB_POOL_CONNECTION_TIMEOUT", 10000, { min: 1000 }),
        statement_timeout: parseEnvNumber("DB_STATEMENT_TIMEOUT", 30000, { min: 1000 }),
    };
}

// Initialize pool singleton
function getPool() {
    if (!pool) {
        pool = new Pool(dbConfig());
        
        // Handle pool errors (don't crash on idle client errors)
        pool.on("error", (err) => {
            logger.error({ err, component: "db-pool" }, "Unexpected database pool error");
        });
        
        // Handle client errors
        pool.on("connect", (client) => {
            client.on("error", (err) => {
                logger.error({ err, component: "db-client" }, "Database client error");
            });
        });
    }
    return pool;
}

// Get a client from the pool (production-ready: reuses connections, retry on failure)
export async function withClient(fn, retries = 3) {
    const poolInstance = getPool();
    let lastError;
    
    for (let attempt = 1; attempt <= retries; attempt++) {
        let client;
        try {
            // Production-ready: retry connection on failure
            client = await poolInstance.connect();
            try {
                if (!schemaReady) {
                    // Schema initialization will be handled by individual services
                    schemaReady = true;
                }
                return await fn(client);
            } finally {
                // Release client back to pool (doesn't close connection)
                client.release();
            }
        } catch (error) {
            lastError = error;
            // Retry on connection errors, but not on query errors
            if (attempt < retries && (
                error.code === "ECONNREFUSED" ||
                error.code === "ETIMEDOUT" ||
                error.message?.includes("connection") ||
                error.message?.includes("timeout")
            )) {
                const delay = Math.min(1000 * attempt, 5000); // Exponential backoff, max 5s
                await new Promise(resolve => setTimeout(resolve, delay));
                continue;
            }
            throw error;
        }
    }
    
    throw lastError;
}

// Admin pool for postgres admin operations (different database/user)
let adminPool = null;

function adminDbConfig() {
    const host = process.env.POSTGRES_HOST?.trim() ?? process.env.DB_HOST?.trim();
    const port = parseEnvNumber("POSTGRES_PORT", 5432, { min: 1, max: 65535 });
    const user = process.env.POSTGRES_ADMIN_USER?.trim() ?? process.env.DB_ADMIN_USER?.trim();
    const password = process.env.POSTGRES_ADMIN_PASSWORD?.trim() ?? process.env.DB_ADMIN_PASSWORD?.trim();
    const database = process.env.POSTGRES_DB?.trim() || "postgres";

    if (!host || !user || !password) {
        throw new HttpError(500, "Postgres admin configuration missing.");
    }

    return {
        host,
        port,
        user,
        password,
        database,
        max: parseEnvNumber("DB_ADMIN_POOL_MAX", 10, { min: 1, max: 100 }),
        min: parseEnvNumber("DB_ADMIN_POOL_MIN", 1, { min: 0, max: 50 }),
        idleTimeoutMillis: parseEnvNumber("DB_POOL_IDLE_TIMEOUT", 30000, { min: 1000 }),
        connectionTimeoutMillis: parseEnvNumber("DB_POOL_CONNECTION_TIMEOUT", 10000, { min: 1000 }),
        statement_timeout: parseEnvNumber("DB_STATEMENT_TIMEOUT", 30000, { min: 1000 }),
    };
}

function getAdminPool() {
    if (!adminPool) {
        adminPool = new Pool(adminDbConfig());
        adminPool.on("error", (err) => {
            logger.error({ err, component: "db-admin-pool" }, "Unexpected admin database pool error");
        });
    }
    return adminPool;
}

// Get admin client from admin pool (production-ready: retry on failure)
export async function withAdminClient(fn, retries = 3) {
    const poolInstance = getAdminPool();
    let lastError;
    
    for (let attempt = 1; attempt <= retries; attempt++) {
        let client;
        try {
            // Production-ready: retry connection on failure
            client = await poolInstance.connect();
            try {
                return await fn(client);
            } finally {
                client.release();
            }
        } catch (error) {
            lastError = error;
            // Retry on connection errors, but not on query errors
            if (attempt < retries && (
                error.code === "ECONNREFUSED" ||
                error.code === "ETIMEDOUT" ||
                error.message?.includes("connection") ||
                error.message?.includes("timeout")
            )) {
                const delay = Math.min(1000 * attempt, 5000); // Exponential backoff, max 5s
                await new Promise(resolve => setTimeout(resolve, delay));
                continue;
            }
            throw error;
        }
    }
    
    throw lastError;
}

// Close pool (for graceful shutdown)
export async function closePool() {
    if (pool) {
        await pool.end();
        pool = null;
        schemaReady = false;
    }
    if (adminPool) {
        await adminPool.end();
        adminPool = null;
    }
}

// Health check: verify pool is healthy
export async function checkPoolHealth() {
    try {
        const poolInstance = getPool();
        const client = await poolInstance.connect();
        try {
            await client.query("SELECT 1");
            return { healthy: true, totalCount: poolInstance.totalCount, idleCount: poolInstance.idleCount, waitingCount: poolInstance.waitingCount };
        } finally {
            client.release();
        }
    } catch (error) {
        return { healthy: false, error: error.message };
    }
}
