const CONTROLLER_BASE =
  process.env.CONTROLLER_BASE_URL ?? "http://controller.platform.svc.cluster.local:8080";
const CONTROLLER_API_KEY = process.env.CONTROLLER_API_KEY;

if (!CONTROLLER_API_KEY) {
  throw new Error("CONTROLLER_API_KEY is not set (injected via Secret).");
}

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
  namespace: string;
  siteId: string | null;
};

export async function listSites(): Promise<SiteInfo[]> {
  const res = await controllerFetch("/sites", { method: "GET" });
  return res.json();
}

export async function createSite(input: {
  siteId: string;
  image: string;
  containerPort: number;
}) {
  await controllerFetch("/sites", {
    method: "POST",
    body: JSON.stringify(input)
  });
}

export async function deleteSite(siteId: string) {
  await controllerFetch(`/sites/${siteId}`, { method: "DELETE" });
}
