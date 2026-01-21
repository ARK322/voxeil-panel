import crypto from "node:crypto";
import { promisify } from "node:util";
import { Client } from "pg";
import { HttpError } from "../http/errors.js";
import { readTenantNamespace } from "../k8s/namespace.js";
import type { CreateUserInput } from "./user.dto.js";
import { loadAndRenderTemplate, USER_TEMPLATES } from "../templates/load-template.js";
import { applyTemplate } from "../k8s/apply.js";
import { getClients } from "../k8s/client.js";
import type { V1Namespace, V1ResourceQuota, V1LimitRange, V1NetworkPolicy, V1RoleBinding } from "@kubernetes/client-node";

const scryptAsync = promisify(crypto.scrypt);

type UserRole = "admin" | "site";

type UserRecord = {
  id: string;
  username: string;
  email: string;
  role: UserRole;
  siteSlug?: string | null;
  active: boolean;
  status: "active" | "error" | "pending";
  createdAt: string;
};

type SessionRecord = {
  token: string;
  user: UserRecord;
  expiresAt: string;
};

let schemaReady = false;
const SESSION_TTL_SECONDS = 60 * 60 * 12;

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
    CREATE TABLE IF NOT EXISTS panel_users (
      id TEXT PRIMARY KEY,
      username TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      email TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('admin', 'site')),
      site_slug TEXT,
      active BOOLEAN NOT NULL DEFAULT true,
      status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'error', 'pending')),
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      CHECK ((role = 'admin' AND site_slug IS NULL) OR (role = 'site' AND site_slug IS NOT NULL))
    );
  `);
  // Add status column if it doesn't exist (migration)
  await client.query(`
    ALTER TABLE panel_users
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'error', 'pending'));
  `);
  await client.query(`
    CREATE UNIQUE INDEX IF NOT EXISTS panel_users_site_idx
    ON panel_users (site_slug)
    WHERE role = 'site';
  `);
  await client.query(`
    CREATE TABLE IF NOT EXISTS panel_sessions (
      token TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES panel_users(id) ON DELETE CASCADE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      expires_at TIMESTAMPTZ NOT NULL
    );
  `);
  await client.query(`
    CREATE INDEX IF NOT EXISTS panel_sessions_user_idx
    ON panel_sessions (user_id);
  `);
}

async function hashPassword(password: string): Promise<string> {
  const salt = crypto.randomBytes(16).toString("hex");
  const hash = (await scryptAsync(password, salt, 64)) as Buffer;
  return `${salt}:${hash.toString("hex")}`;
}

async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const [salt, hashHex] = stored.split(":");
  if (!salt || !hashHex) return false;
  const hash = (await scryptAsync(password, salt, 64)) as Buffer;
  return crypto.timingSafeEqual(Buffer.from(hashHex, "hex"), hash);
}

function mapRow(row: any): UserRecord {
  return {
    id: row.id,
    username: row.username,
    email: row.email,
    role: row.role,
    siteSlug: row.site_slug ?? null,
    active: row.active,
    status: (row.status as "active" | "error" | "pending") || "active",
    createdAt: row.created_at
  };
}

export async function ensureAdminUserFromEnv(): Promise<void> {
  const username = process.env.PANEL_ADMIN_USERNAME?.trim();
  const password = process.env.PANEL_ADMIN_PASSWORD?.trim();
  const email = process.env.PANEL_ADMIN_EMAIL?.trim();
  if (!username || !password || !email) return;

  await withClient(async (client) => {
    const existing = await client.query(
      "SELECT id, password_hash FROM panel_users WHERE username = $1",
      [username]
    );
    if (existing.rowCount === 0) {
      const passwordHash = await hashPassword(password);
      await client.query(
        `INSERT INTO panel_users (id, username, password_hash, email, role, site_slug, active, status)
         VALUES ($1, $2, $3, $4, 'admin', NULL, true, 'active')`,
        [crypto.randomUUID(), username, passwordHash, email]
      );
      return;
    }
    const current = existing.rows[0];
    const matches = await verifyPassword(password, current.password_hash);
    if (!matches) {
      const passwordHash = await hashPassword(password);
      await client.query(
        "UPDATE panel_users SET password_hash = $1, email = $2 WHERE id = $3",
        [passwordHash, email, current.id]
      );
    } else {
      await client.query("UPDATE panel_users SET email = $1 WHERE id = $2", [email, current.id]);
    }
  });
}

export async function listUsers(): Promise<UserRecord[]> {
  return withClient(async (client) => {
    const result = await client.query(
      `SELECT id, username, email, role, site_slug, active, status, created_at
       FROM panel_users
       ORDER BY role, username`
    );
    return result.rows.map(mapRow);
  });
}

export async function createUser(input: CreateUserInput): Promise<UserRecord> {
  if (input.role === "site") {
    await readTenantNamespace(input.siteSlug ?? "");
  }
  const passwordHash = await hashPassword(input.password);
  const id = crypto.randomUUID();
  return withClient(async (client) => {
    try {
      const result = await client.query(
        `INSERT INTO panel_users (id, username, password_hash, email, role, site_slug, active, status)
         VALUES ($1, $2, $3, $4, $5, $6, true, 'pending')
         RETURNING id, username, email, role, site_slug, active, status, created_at`,
        [id, input.username, passwordHash, input.email, input.role, input.siteSlug ?? null]
      );
      return mapRow(result.rows[0]);
    } catch (error: any) {
      if (error?.code === "23505") {
        throw new HttpError(409, "Username or site already exists.");
      }
      throw error;
    }
  });
}

export async function setUserActive(id: string, active: boolean): Promise<UserRecord> {
  return withClient(async (client) => {
    const result = await client.query(
      `UPDATE panel_users
       SET active = $1
       WHERE id = $2
       RETURNING id, username, email, role, site_slug, active, status, created_at`,
      [active, id]
    );
    if (result.rowCount === 0) {
      throw new HttpError(404, "User not found.");
    }
    return mapRow(result.rows[0]);
  });
}

/**
 * Updates user status in the database
 */
export async function setUserStatus(
  id: string,
  status: "active" | "error" | "pending"
): Promise<UserRecord> {
  return withClient(async (client) => {
    const result = await client.query(
      `UPDATE panel_users
       SET status = $1
       WHERE id = $2
       RETURNING id, username, email, role, site_slug, active, status, created_at`,
      [status, id]
    );
    if (result.rowCount === 0) {
      throw new HttpError(404, "User not found.");
    }
    return mapRow(result.rows[0]);
  });
}

export async function deleteUser(id: string): Promise<void> {
  await withClient(async (client) => {
    const result = await client.query("DELETE FROM panel_users WHERE id = $1", [id]);
    if (result.rowCount === 0) {
      throw new HttpError(404, "User not found.");
    }
  });
}

export async function verifyUserCredentials(
  username: string,
  password: string
): Promise<UserRecord> {
  return withClient(async (client) => {
    const result = await client.query(
      `SELECT id, username, email, role, site_slug, active, status, created_at, password_hash
       FROM panel_users
       WHERE username = $1`,
      [username]
    );
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

export async function createSession(userId: string): Promise<SessionRecord> {
  const token = crypto.randomBytes(32).toString("hex");
  const expiresAt = new Date(Date.now() + SESSION_TTL_SECONDS * 1000).toISOString();
  return withClient(async (client) => {
    await client.query(
      `INSERT INTO panel_sessions (token, user_id, expires_at)
       VALUES ($1, $2, $3)`,
      [token, userId, expiresAt]
    );
    const userResult = await client.query(
      `SELECT id, username, email, role, site_slug, active, status, created_at
       FROM panel_users
       WHERE id = $1`,
      [userId]
    );
    return { token, user: mapRow(userResult.rows[0]), expiresAt };
  });
}

export async function getSession(token: string): Promise<SessionRecord> {
  return withClient(async (client) => {
    const result = await client.query(
      `SELECT s.token, s.expires_at, u.id, u.username, u.email, u.role, u.site_slug, u.active, u.status, u.created_at
       FROM panel_sessions s
       JOIN panel_users u ON u.id = s.user_id
       WHERE s.token = $1`,
      [token]
    );
    if (result.rowCount === 0) {
      throw new HttpError(401, "Session not found.");
    }
    const row = result.rows[0];
    if (!row.active) {
      throw new HttpError(403, "User is disabled.");
    }
    if (new Date(row.expires_at).getTime() < Date.now()) {
      await client.query("DELETE FROM panel_sessions WHERE token = $1", [token]);
      throw new HttpError(401, "Session expired.");
    }
    return {
      token: row.token,
      expiresAt: row.expires_at,
      user: mapRow(row)
    };
  });
}

export async function deleteSession(token: string): Promise<void> {
  await withClient(async (client) => {
    await client.query("DELETE FROM panel_sessions WHERE token = $1", [token]);
  });
}

/**
 * Bootstrap user namespace in Kubernetes
 * Creates namespace and applies all required templates in order
 * This is idempotent - if namespace already exists, it verifies and continues
 */
export async function bootstrapUserNamespace(userId: string): Promise<{
  namespace: string;
  resourcesCreated: string[];
}> {
  const namespace = `user-${userId}`;
  const { core } = getClients();
  const resourcesCreated: string[] = [];

  try {
    // Check if namespace already exists (idempotency)
    let namespaceExists = false;
    try {
      await core.readNamespace(namespace);
      namespaceExists = true;
    } catch (error: any) {
      if (error?.response?.statusCode !== 404) {
        throw error;
      }
    }

    // 1. Create namespace if it doesn't exist
    if (!namespaceExists) {
      const nsTemplate = await loadAndRenderTemplate(USER_TEMPLATES.namespace, {
        TENANT_NAMESPACE: namespace
      }) as V1Namespace;
      // Ensure metadata.name is set correctly
      nsTemplate.metadata = nsTemplate.metadata || {};
      nsTemplate.metadata.name = namespace;
      await applyTemplate(nsTemplate, "Namespace");
      resourcesCreated.push("Namespace");
    }

    // 2. Apply ResourceQuota
    const quotaTemplate = await loadAndRenderTemplate(USER_TEMPLATES.resourcequota, {
      TENANT_NAMESPACE: namespace
    }) as V1ResourceQuota;
    quotaTemplate.metadata = quotaTemplate.metadata || {};
    quotaTemplate.metadata.namespace = namespace;
    await applyTemplate(quotaTemplate, "ResourceQuota", namespace);
    resourcesCreated.push("ResourceQuota");

    // 3. Apply LimitRange
    const limitRangeTemplate = await loadAndRenderTemplate(USER_TEMPLATES.limitrange, {
      TENANT_NAMESPACE: namespace
    }) as V1LimitRange;
    limitRangeTemplate.metadata = limitRangeTemplate.metadata || {};
    limitRangeTemplate.metadata.namespace = namespace;
    await applyTemplate(limitRangeTemplate, "LimitRange", namespace);
    resourcesCreated.push("LimitRange");

    // 4. Apply NetworkPolicy (deny-all)
    const networkPolicyTemplate = await loadAndRenderTemplate(USER_TEMPLATES.networkPolicyDenyAll, {
      TENANT_NAMESPACE: namespace
    }) as V1NetworkPolicy;
    networkPolicyTemplate.metadata = networkPolicyTemplate.metadata || {};
    networkPolicyTemplate.metadata.namespace = namespace;
    await applyTemplate(networkPolicyTemplate, "NetworkPolicy", namespace);
    resourcesCreated.push("NetworkPolicy");

    // 5. Apply Controller RoleBinding
    const roleBindingTemplate = await loadAndRenderTemplate(USER_TEMPLATES.controllerRoleBinding, {
      TENANT_NAMESPACE: namespace
    }) as V1RoleBinding;
    roleBindingTemplate.metadata = roleBindingTemplate.metadata || {};
    roleBindingTemplate.metadata.namespace = namespace;
    await applyTemplate(roleBindingTemplate, "RoleBinding", namespace);
    resourcesCreated.push("RoleBinding");

    return { namespace, resourcesCreated };
  } catch (error: any) {
    // Rollback: Delete created resources
    for (const resource of resourcesCreated.reverse()) {
      try {
        if (resource === "Namespace") {
          await core.deleteNamespace(namespace);
        }
        // Other resources will be deleted with namespace
      } catch (rollbackError: any) {
        // Log but don't fail on rollback errors
        console.error(`Failed to rollback ${resource}:`, rollbackError);
      }
    }
    throw error;
  }
}

/**
 * Creates a user with namespace bootstrap
 * This is the main function for admin user creation with full K8s setup
 */
export async function createUserWithBootstrap(input: CreateUserInput): Promise<UserRecord> {
  // Step 1: Create user in DB with 'pending' status
  const user = await createUser(input);
  
  try {
    // Step 2: Bootstrap K8s namespace
    await bootstrapUserNamespace(user.id);
    
    // Step 3: Update user status to 'active'
    return await setUserStatus(user.id, "active");
  } catch (error: any) {
    // Step 4: On error, set user status to 'error'
    try {
      await setUserStatus(user.id, "error");
    } catch (statusError: any) {
      // Log but don't fail
      console.error("Failed to set user status to error:", statusError);
    }
    throw error;
  }
}
