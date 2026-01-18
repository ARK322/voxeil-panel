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
