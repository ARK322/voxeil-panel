import type { V1Ingress } from "@kubernetes/client-node";
import { getClients } from "./client.js";
import { HttpError } from "../http/errors.js";

const STAGING_ISSUER = "letsencrypt-staging";
const PROD_ISSUER = "letsencrypt-prod";

export type IngressPatch = {
  metadata?: {
    annotations?: Record<string, string | null>;
  };
  spec?: {
    tls?: Array<{
      hosts?: string[];
      secretName?: string;
    }> | null;
  };
};

export async function getIngress(name: string, namespace: string): Promise<V1Ingress> {
  const { net } = getClients();
  try {
    const result = await net.readNamespacedIngress(name, namespace);
    return result.body;
  } catch (error: any) {
    if (error?.response?.statusCode === 404) {
      throw new HttpError(404, "Ingress not found.");
    }
    throw error;
  }
}

export async function patchIngress(
  name: string,
  namespace: string,
  patchBody: IngressPatch
): Promise<void> {
  const { net } = getClients();
  const patch = net.patchNamespacedIngress as unknown as (
    name: string,
    namespace: string,
    body: unknown,
    pretty?: string,
    dryRun?: string,
    fieldManager?: string,
    fieldValidation?: string,
    force?: boolean,
    options?: { headers: { "Content-Type": string } }
  ) => Promise<unknown>;
  await patch(
    name,
    namespace,
    patchBody,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    { headers: { "Content-Type": "application/merge-patch+json" } }
  );
}

async function hasTlsSecret(namespace: string, slug: string): Promise<boolean> {
  const { core } = getClients();
  try {
    await core.readNamespacedSecret(`tls-${slug}`, namespace);
    return true;
  } catch (error: any) {
    if (error?.response?.statusCode === 404) return false;
    throw error;
  }
}

export async function resolveIngressIssuer(
  namespace: string,
  slug: string,
  desiredIssuer?: string
): Promise<string> {
  const requested = desiredIssuer ?? STAGING_ISSUER;
  if (requested !== STAGING_ISSUER && requested !== PROD_ISSUER) {
    return requested;
  }
  const verified = await hasTlsSecret(namespace, slug);
  return verified ? PROD_ISSUER : STAGING_ISSUER;
}
