import type { V1Secret } from "@kubernetes/client-node";
import { getClients, LABELS } from "./client.js";
import { HttpError } from "../http/errors.js";

export const GHCR_PULL_SECRET_NAME = "ghcr-pull-secret";
export const PLATFORM_NAMESPACE = process.env.PLATFORM_NAMESPACE ?? "platform";

async function readPlatformSecret(name: string): Promise<V1Secret> {
  const { core } = getClients();
  try {
    const result = await core.readNamespacedSecret(name, PLATFORM_NAMESPACE);
    return result.body;
  } catch (error: any) {
    if (error?.response?.statusCode === 404) {
      throw new HttpError(
        500,
        `Missing ${name} secret in ${PLATFORM_NAMESPACE} namespace.`
      );
    }
    throw error;
  }
}

export async function ensureGhcrPullSecret(namespace: string, slug: string): Promise<void> {
  const { core } = getClients();
  const source = await readPlatformSecret(GHCR_PULL_SECRET_NAME);
  const secret: V1Secret = {
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      name: GHCR_PULL_SECRET_NAME,
      namespace,
      labels: {
        [LABELS.managedBy]: LABELS.managedBy,
        [LABELS.siteSlug]: slug
      }
    },
    type: source.type ?? "kubernetes.io/dockerconfigjson",
    data: source.data ?? {}
  };

  try {
    await core.createNamespacedSecret(namespace, secret);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
  }
}

export async function readSecret(namespace: string, name: string): Promise<V1Secret | null> {
  const { core } = getClients();
  try {
    const result = await core.readNamespacedSecret(name, namespace);
    return result.body;
  } catch (error: any) {
    if (error?.response?.statusCode === 404) return null;
    throw error;
  }
}

export async function upsertSecret(secret: V1Secret): Promise<void> {
  const { core } = getClients();
  const name = secret.metadata?.name;
  const namespace = secret.metadata?.namespace;
  if (!name || !namespace) {
    throw new HttpError(500, "Secret name/namespace missing.");
  }
  try {
    await core.createNamespacedSecret(namespace, secret);
  } catch (error: any) {
    if (error?.response?.statusCode !== 409) throw error;
    const patch = core.patchNamespacedSecret as unknown as (
      name: string,
      namespace: string,
      body: unknown,
      pretty?: string,
      dryRun?: string,
      fieldManager?: string,
      fieldValidation?: string,
      options?: { headers: { "Content-Type": string } }
    ) => Promise<unknown>;
    await patch(
      name,
      namespace,
      secret,
      undefined,
      undefined,
      undefined,
      undefined,
      { headers: { "Content-Type": "application/merge-patch+json" } }
    );
  }
}

export async function deleteSecret(namespace: string, name: string): Promise<void> {
  const { core } = getClients();
  try {
    await core.deleteNamespacedSecret(name, namespace);
  } catch (error: any) {
    if (error?.response?.statusCode === 404) return;
    throw error;
  }
}