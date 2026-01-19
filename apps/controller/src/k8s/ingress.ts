import type { V1Ingress } from "@kubernetes/client-node";
import { getClients } from "./client.js";
import { HttpError } from "../http/errors.js";

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
