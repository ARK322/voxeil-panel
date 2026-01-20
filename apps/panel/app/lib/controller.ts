const CONTROLLER_BASE =
  process.env.CONTROLLER_BASE_URL ?? "http://controller.platform.svc.cluster.local:8080";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is not set (injected via Secret).`);
  }
  return value;
}

const CONTROLLER_API_KEY = requireEnv("CONTROLLER_API_KEY");

type ControllerInit = RequestInit & { headers?: Record<string, string> };

async function controllerFetch(path: string, init?: ControllerInit) {
  const headers = {
    ...(init?.headers ?? {}),
    "x-api-key": CONTROLLER_API_KEY,
    "content-type": init?.headers?.["content-type"] ?? "application/json"
  };

  const res = await fetch(`${CONTROLLER_BASE}${path}`, {
    ...init,
    headers
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Controller error (${res.status}): ${text}`);
  }

  return res;
}

export type SiteInfo = {
  slug: string;
  namespace: string;
  ready: boolean;
  domain?: string;
  image?: string;
  containerPort?: number;
  tlsEnabled?: boolean;
};

export async function listSites(): Promise<SiteInfo[]> {
  const res = await controllerFetch("/sites", { method: "GET" });
  return res.json();
}

export async function createSite(input: {
  domain: string;
  cpu: number;
  ramGi: number;
  diskGi: number;
  tlsEnabled?: boolean;
  tlsIssuer?: string;
}) {
  await controllerFetch("/sites", {
    method: "POST",
    body: JSON.stringify(input)
  });
}

export async function deleteSite(slug: string) {
  await controllerFetch(`/sites/${slug}`, { method: "DELETE" });
}
