import k8s from "@kubernetes/client-node";
export const LABELS = {
    managedBy: "vhp-controller"
};
let cached = null;
export function getClients() {
    if (cached)
        return cached;
    const kc = new k8s.KubeConfig();
    try {
        kc.loadFromCluster();
    }
    catch {
        kc.loadFromDefault();
    }
    cached = {
        kc,
        core: kc.makeApiClient(k8s.CoreV1Api),
        apps: kc.makeApiClient(k8s.AppsV1Api),
        net: kc.makeApiClient(k8s.NetworkingV1Api),
        batch: kc.makeApiClient(k8s.BatchV1Api),
        rbac: kc.makeApiClient(k8s.RbacAuthorizationV1Api)
    };
    return cached;
}
