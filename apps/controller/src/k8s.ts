import k8s from "@kubernetes/client-node";

export function getClients() {
  const kc = new k8s.KubeConfig();
  // inside cluster -> uses ServiceAccount
  // local dev -> uses ~/.kube/config
  try {
    kc.loadFromCluster();
  } catch {
    kc.loadFromDefault();
  }

  return {
    kc,
    core: kc.makeApiClient(k8s.CoreV1Api),
    apps: kc.makeApiClient(k8s.AppsV1Api),
    net: kc.makeApiClient(k8s.NetworkingV1Api)
  };
}

// Avoid hardcoded vendor domains; keep labels generic and repo-agnostic.
export const LABELS = {
  managedBy: "vhp-controller",
  siteId: "vhp/site-id"
} as const;
