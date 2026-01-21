import { getClients } from "./client.js";
import { HttpError } from "../http/errors.js";
const STAGING_ISSUER = "letsencrypt-staging";
const PROD_ISSUER = "letsencrypt-prod";
export async function getIngress(name, namespace) {
    const { net } = getClients();
    try {
        const result = await net.readNamespacedIngress(name, namespace);
        return result.body;
    }
    catch (error) {
        if (error?.response?.statusCode === 404) {
            throw new HttpError(404, "Ingress not found.");
        }
        throw error;
    }
}
export async function patchIngress(name, namespace, patchBody) {
    const { net } = getClients();
    const patch = net.patchNamespacedIngress;
    await patch(name, namespace, patchBody, undefined, undefined, undefined, undefined, undefined, { headers: { "Content-Type": "application/merge-patch+json" } });
}
async function hasTlsSecret(namespace, slug) {
    const { core } = getClients();
    try {
        await core.readNamespacedSecret(`tls-${slug}`, namespace);
        return true;
    }
    catch (error) {
        if (error?.response?.statusCode === 404)
            return false;
        throw error;
    }
}
export async function resolveIngressIssuer(namespace, slug, desiredIssuer) {
    const requested = desiredIssuer ?? STAGING_ISSUER;
    if (requested !== STAGING_ISSUER && requested !== PROD_ISSUER) {
        return requested;
    }
    const verified = await hasTlsSecret(namespace, slug);
    return verified ? PROD_ISSUER : STAGING_ISSUER;
}
