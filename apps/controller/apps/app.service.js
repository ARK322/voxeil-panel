import crypto from "node:crypto";
import { Client } from "pg";
import { HttpError } from "../http/errors.js";
import { upsertDeployment, upsertService, upsertIngress, upsertSecret } from "../k8s/apply.js";
import { requireNamespace } from "../k8s/namespace.js";
import { buildDeployment, buildService, buildIngress, APP_DEPLOYMENT_NAME, SERVICE_NAME, INGRESS_NAME } from "../k8s/publish.js";
import { getClients, LABELS } from "../k8s/client.js";
import { validateSlug } from "../sites/site.slug.js";
import { logAudit } from "../audit/audit.service.js";

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
    } finally {
        await client.end();
    }
}

async function ensureSchema(client) {
    await client.query(`
        CREATE TABLE IF NOT EXISTS apps (
            id TEXT PRIMARY KEY,
            owner_user_id TEXT NOT NULL REFERENCES panel_users(id) ON DELETE CASCADE,
            slug TEXT NOT NULL,
            domain TEXT,
            image TEXT,
            repo_url TEXT,
            env_json JSONB NOT NULL DEFAULT '{}',
            status TEXT NOT NULL DEFAULT 'created' CHECK (status IN ('created', 'deployed', 'error')),
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            UNIQUE(owner_user_id, slug)
        );
    `);
    await client.query(`
        CREATE INDEX IF NOT EXISTS apps_owner_user_id_idx ON apps (owner_user_id);
    `);
    await client.query(`
        CREATE INDEX IF NOT EXISTS apps_slug_idx ON apps (slug);
    `);
}

function mapRow(row) {
    return {
        id: row.id,
        ownerUserId: row.owner_user_id,
        slug: row.slug,
        domain: row.domain,
        image: row.image,
        repoUrl: row.repo_url,
        envJson: row.env_json ?? {},
        status: row.status ?? "created",
        createdAt: row.created_at,
        updatedAt: row.updated_at
    };
}

export async function listApps(ownerUserId) {
    return withClient(async (client) => {
        const result = await client.query(`
            SELECT id, owner_user_id, slug, domain, image, repo_url, env_json, status, created_at, updated_at
            FROM apps
            WHERE owner_user_id = $1
            ORDER BY created_at DESC
        `, [ownerUserId]);
        return result.rows.map(mapRow);
    });
}

export async function getAppById(appId) {
    return withClient(async (client) => {
        const result = await client.query(`
            SELECT id, owner_user_id, slug, domain, image, repo_url, env_json, status, created_at, updated_at
            FROM apps
            WHERE id = $1
        `, [appId]);
        if (result.rowCount === 0) {
            throw new HttpError(404, "App not found.");
        }
        return mapRow(result.rows[0]);
    });
}

export async function getAppByIdWithOwnershipCheck(appId, userId) {
    const app = await getAppById(appId);
    if (app.ownerUserId !== userId) {
        throw new HttpError(403, "Access denied.");
    }
    return app;
}

export async function createApp(ownerUserId, input) {
    const normalizedSlug = validateSlug(input.slug);
    const id = crypto.randomUUID();
    
    return withClient(async (client) => {
        try {
            const result = await client.query(`
                INSERT INTO apps (id, owner_user_id, slug, domain, repo_url, image, env_json, status)
                VALUES ($1, $2, $3, $4, $5, $6, $7, 'created')
                RETURNING id, owner_user_id, slug, domain, image, repo_url, env_json, status, created_at, updated_at
            `, [
                id,
                ownerUserId,
                normalizedSlug,
                input.domain?.trim() || null,
                input.repoUrl?.trim() || null,
                input.image?.trim() || null,
                JSON.stringify(input.env ?? {})
            ]);
            return mapRow(result.rows[0]);
        } catch (error) {
            if (error?.code === "23505") {
                throw new HttpError(409, "App with this slug already exists for this user.");
            }
            throw error;
        }
    });
}

export async function updateAppStatus(appId, status) {
    return withClient(async (client) => {
        const result = await client.query(`
            UPDATE apps
            SET status = $1, updated_at = now()
            WHERE id = $2
            RETURNING id, owner_user_id, slug, domain, image, repo_url, env_json, status, created_at, updated_at
        `, [status, appId]);
        if (result.rowCount === 0) {
            throw new HttpError(404, "App not found.");
        }
        return mapRow(result.rows[0]);
    });
}

export async function updateAppDeploymentInfo(appId, image, domain) {
    return withClient(async (client) => {
        const result = await client.query(`
            UPDATE apps
            SET image = $1, domain = $2, updated_at = now()
            WHERE id = $3
            RETURNING id, owner_user_id, slug, domain, image, repo_url, env_json, status, created_at, updated_at
        `, [image, domain, appId]);
        if (result.rowCount === 0) {
            throw new HttpError(404, "App not found.");
        }
        return mapRow(result.rows[0]);
    });
}

export async function deployApp(appId, userId, input) {
    // Verify ownership
    const app = await getAppById(appId);
    if (app.ownerUserId !== userId) {
        throw new HttpError(403, "Access denied.");
    }

    const namespace = `user-${userId}`;
    await requireNamespace(namespace);

    // Validate slug before deploy
    const slug = validateSlug(app.slug);
    const image = input.image || app.image;
    const containerPort = input.containerPort || 3000;
    const domain = app.domain?.trim() || null;

    if (!image) {
        throw new HttpError(400, "Image is required.");
    }

    // Create secret for environment variables
    let secretName = null;
    if (app.envJson && Object.keys(app.envJson).length > 0) {
        secretName = `app-${slug}-env`;
        const secret = {
            apiVersion: "v1",
            kind: "Secret",
            metadata: {
                name: secretName,
                namespace,
                labels: {
                    [LABELS.managedBy]: LABELS.managedBy
                }
            },
            type: "Opaque",
            stringData: Object.fromEntries(
                Object.entries(app.envJson).map(([key, value]) => [key, String(value)])
            )
        };
        // Explicitly ensure namespace is set on metadata
        secret.metadata = secret.metadata || {};
        secret.metadata.namespace = namespace;
        await upsertSecret(secret);
    }

    // Build deployment spec
    const appName = `app-${slug}`;
    const deploymentSpec = {
        namespace,
        slug,
        appName,
        image,
        containerPort,
        cpu: 1,
        ramGi: 1,
        imagePullSecretName: undefined,
        uploadDirs: input.uploadDirs,
        envSecretName: secretName || undefined
    };

    // Build deployment with app-${slug} name
    const deploymentName = appName;
    const serviceName = appName;
    const ingressName = appName;

    const deployment = buildDeployment(deploymentSpec);
    deployment.metadata.name = deploymentName;
    deployment.metadata.namespace = namespace;

    const service = buildService(deploymentSpec);
    service.metadata.name = serviceName;
    service.metadata.namespace = namespace;

    // Deploy deployment and service
    await Promise.all([
        upsertDeployment(deployment),
        upsertService(service)
    ]);

    // Deploy ingress ONLY if domain is provided and not empty
    if (domain && domain.trim() !== "") {
        const ingressSpec = {
            ...deploymentSpec,
            host: domain,
            tlsEnabled: false,
            tlsIssuer: undefined
        };
        const ingress = buildIngress(ingressSpec);
        ingress.metadata.name = ingressName;
        ingress.metadata.namespace = namespace;
        // Update ingress to use correct service name
        if (ingress.spec?.rules?.[0]?.http?.paths?.[0]?.backend?.service) {
            ingress.spec.rules[0].http.paths[0].backend.service.name = serviceName;
        }
        await upsertIngress(ingress);
    }

    // Update app status and deployment info
    await updateAppDeploymentInfo(app.id, image, domain);
    await updateAppStatus(app.id, "deployed");

    // Audit log
    await logAudit({
        action: "apps.deploy",
        actorUserId: userId,
        targetType: "app",
        targetId: app.id,
        success: true
    });

    return {
        id: app.id,
        slug,
        namespace,
        image,
        containerPort,
        domain
    };
}
