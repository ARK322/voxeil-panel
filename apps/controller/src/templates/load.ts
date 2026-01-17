import { promises as fs, existsSync } from "node:fs";
import path from "node:path";
import k8s from "@kubernetes/client-node";
import type {
  V1LimitRange,
  V1NetworkPolicy,
  V1ResourceQuota
} from "@kubernetes/client-node";

export type TenantTemplates = {
  resourceQuota: V1ResourceQuota;
  limitRange: V1LimitRange;
  networkPolicyDenyAll: V1NetworkPolicy;
  networkPolicyAllowIngress: V1NetworkPolicy;
};

let cached: TenantTemplates | null = null;

function resolveTemplatesDir(): string {
  const candidates = [
    path.resolve(process.cwd(), "infra", "k8s", "templates", "tenant"),
    path.resolve(process.cwd(), "..", "..", "infra", "k8s", "templates", "tenant"),
    path.resolve(process.cwd(), "..", "infra", "k8s", "templates", "tenant")
  ];

  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }

  return candidates[0];
}

async function readYaml<T>(filePath: string): Promise<T> {
  const raw = await fs.readFile(filePath, "utf8");
  return k8s.loadYaml(raw) as T;
}

export async function loadTenantTemplates(): Promise<TenantTemplates> {
  if (cached) return cached;
  const dir = resolveTemplatesDir();
  const resourceQuota = await readYaml<V1ResourceQuota>(path.join(dir, "resourcequota.yaml"));
  const limitRange = await readYaml<V1LimitRange>(path.join(dir, "limitrange.yaml"));
  const networkPolicyDenyAll = await readYaml<V1NetworkPolicy>(
    path.join(dir, "networkpolicy-deny-all.yaml")
  );
  const networkPolicyAllowIngress = await readYaml<V1NetworkPolicy>(
    path.join(dir, "networkpolicy-allow-ingress.yaml")
  );

  cached = {
    resourceQuota,
    limitRange,
    networkPolicyDenyAll,
    networkPolicyAllowIngress
  };
  return cached;
}
