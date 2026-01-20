import k8s from "@kubernetes/client-node";

export const LABELS = {
  managedBy: "vhp-controller",
  siteSlug: "vhp/site-slug"
} as const;

type Clients = {
  kc: k8s.KubeConfig;
  core: k8s.CoreV1Api;
  apps: k8s.AppsV1Api;
  net: k8s.NetworkingV1Api;
  batch: k8s.BatchV1Api;
  rbac: k8s.RbacAuthorizationV1Api;
};

let cached: Clients | null = null;

export function getClients(): Clients {
  if (cached) return cached;
  const kc = new k8s.KubeConfig();
  try {
    kc.loadFromCluster();
  } catch {
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
