// Typed API client for the panel

import type {
  HealthResponse,
  Tenant,
  TenantDetail,
  Site,
  SiteDetail,
  MailInfo,
  DbInfo,
  DnsInfo,
} from "./types";

const API_BASE = "/api";

async function fetchAPI<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...options?.headers,
    },
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`API error (${res.status}): ${text}`);
  }

  return res.json();
}

export const api = {
  health: {
    get: (): Promise<HealthResponse> => fetchAPI("/health"),
  },
  tenants: {
    list: (): Promise<Tenant[]> => fetchAPI("/tenants"),
    get: (id: string): Promise<TenantDetail> => fetchAPI(`/tenants/${id}`),
  },
  sites: {
    list: (): Promise<Site[]> => fetchAPI("/sites"),
    get: (id: string): Promise<SiteDetail> => fetchAPI(`/sites/${id}`),
    create: (data: { name: string; slug: string; domain?: string }): Promise<Site> =>
      fetchAPI("/sites", { method: "POST", body: JSON.stringify(data) }),
    deploy: (id: string, data: { image?: string; containerPort?: number }): Promise<void> =>
      fetchAPI(`/sites/${id}/deploy`, { method: "POST", body: JSON.stringify(data) }),
  },
  mail: {
    get: (): Promise<MailInfo> => fetchAPI("/mail"),
  },
  db: {
    get: (): Promise<DbInfo> => fetchAPI("/db"),
  },
  dns: {
    get: (): Promise<DnsInfo> => fetchAPI("/dns"),
  },
};
