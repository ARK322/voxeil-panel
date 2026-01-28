import { Pool } from "pg";
import { HttpError } from "../http/errors.js";

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
        port: Number(process.env.POSTGRES_PORT ?? "5432"),
        user: requireEnv("POSTGRES_ADMIN_USER"),
        password: requireEnv("POSTGRES_ADMIN_PASSWORD"),
        database: requireEnv("POSTGRES_DB"),
        // Production-ready pool configuration
        max: Number(process.env.DB_POOL_MAX ?? "20"), // Maximum pool size
        min: Number(process.env.DB_POOL_MIN ?? "2"), // Minimum pool size
        idleTimeoutMillis: Number(process.env.DB_POOL_IDLE_TIMEOUT ?? "30000"), // 30s
        connectionTimeoutMillis: Number(process.env.DB_POOL_CONNECTION_TIMEOUT ?? "10000"), // 10s
        statement_timeout: Number(process.env.DB_STATEMENT_TIMEOUT ?? "30000"), // 30s query timeout
    };
}

// Initialize pool singleton
function getPool() {
    if (!pool) {
        pool = new Pool(dbConfig());
        
        // Handle pool errors (don't crash on idle client errors)
        pool.on("error", (err) => {
            console.error("Unexpected database pool error:", err);
        });
        
        // Handle client errors
        pool.on("connect", (client) => {
            client.on("error", (err) => {
                console.error("Database client error:", err);
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
    const port = Number(process.env.POSTGRES_PORT ?? process.env.DB_PORT ?? "5432");
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
        max: Number(process.env.DB_ADMIN_POOL_MAX ?? "10"),
        min: Number(process.env.DB_ADMIN_POOL_MIN ?? "1"),
        idleTimeoutMillis: Number(process.env.DB_POOL_IDLE_TIMEOUT ?? "30000"),
        connectionTimeoutMillis: Number(process.env.DB_POOL_CONNECTION_TIMEOUT ?? "10000"),
        statement_timeout: Number(process.env.DB_STATEMENT_TIMEOUT ?? "30000"),
    };
}

function getAdminPool() {
    if (!adminPool) {
        adminPool = new Pool(adminDbConfig());
        adminPool.on("error", (err) => {
            console.error("Unexpected admin database pool error:", err);
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
