import { getSessionToken } from "./session";

const CONTROLLER_BASE =
  process.env.CONTROLLER_BASE_URL ?? "http://controller.platform.svc.cluster.local:8080";

type ControllerInit = RequestInit & { headers?: Record<string, string> };

async function controllerFetch(path: string, init?: ControllerInit) {
  const token = getSessionToken();
  if (!token) {
    throw new Error("Not authenticated.");
  }
  const headers = {
    ...(init?.headers ?? {}),
    "x-session-token": token,
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
  tlsIssuer?: string;
  githubEnabled?: boolean;
  githubRepo?: string;
  githubBranch?: string;
  githubWorkflow?: string;
  githubImage?: string;
  dbEnabled?: boolean;
  dbName?: string;
  dbUser?: string;
  dbHost?: string;
  dbPort?: number;
  dbSecret?: string;
  mailEnabled?: boolean;
  mailDomain?: string;
  dnsEnabled?: boolean;
  dnsDomain?: string;
  dnsTarget?: string;
  backupEnabled?: boolean;
  backupRetentionDays?: number;
  backupSchedule?: string;
  backupLastRunAt?: string;
  cpu?: number;
  ramGi?: number;
  diskGi?: number;
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
  const res = await controllerFetch("/sites", {
    method: "POST",
    body: JSON.stringify(input)
  });
  return res.json();
}

export async function deleteSite(slug: string) {
  await controllerFetch(`/sites/${slug}`, { method: "DELETE" });
}

export async function enableGithub(input: {
  slug: string;
  repo: string;
  branch?: string;
  workflow?: string;
  image: string;
  token: string;
  webhookSecret?: string;
}) {
  await controllerFetch(`/sites/${input.slug}/github/enable`, {
    method: "POST",
    body: JSON.stringify({
      repo: input.repo,
      branch: input.branch,
      workflow: input.workflow,
      image: input.image,
      token: input.token,
      webhookSecret: input.webhookSecret
    })
  });
}

export async function disableGithub(slug: string) {
  await controllerFetch(`/sites/${slug}/github/disable`, { method: "POST" });
}

export async function deployGithub(input: {
  slug: string;
  ref?: string;
  image?: string;
  registryUsername?: string;
  registryToken?: string;
  registryServer?: string;
  registryEmail?: string;
}) {
  await controllerFetch(`/sites/${input.slug}/github/deploy`, {
    method: "POST",
    body: JSON.stringify({
      ref: input.ref,
      image: input.image,
      registryUsername: input.registryUsername,
      registryToken: input.registryToken,
      registryServer: input.registryServer,
      registryEmail: input.registryEmail
    })
  });
}

export async function saveRegistryCredentials(input: {
  slug: string;
  registryUsername: string;
  registryToken: string;
  registryServer?: string;
  registryEmail?: string;
}) {
  await controllerFetch(`/sites/${input.slug}/registry/credentials`, {
    method: "POST",
    body: JSON.stringify({
      registryUsername: input.registryUsername,
      registryToken: input.registryToken,
      registryServer: input.registryServer,
      registryEmail: input.registryEmail
    })
  });
}

export async function deleteRegistryCredentials(slug: string) {
  await controllerFetch(`/sites/${slug}/registry/credentials`, {
    method: "DELETE"
  });
}

export async function getAllowlist(): Promise<string[]> {
  const res = await controllerFetch("/security/allowlist", { method: "GET" });
  const payload = await res.json();
  return Array.isArray(payload.items) ? payload.items : [];
}

export async function updateAllowlist(items: string[]) {
  await controllerFetch("/security/allowlist", {
    method: "PUT",
    body: JSON.stringify({ items })
  });
}

export async function updateSiteTls(input: {
  slug: string;
  enabled: boolean;
  issuer?: string;
  cleanupSecret?: boolean;
}) {
  await controllerFetch(`/sites/${input.slug}/tls`, {
    method: "PATCH",
    body: JSON.stringify({
      enabled: input.enabled,
      issuer: input.issuer,
      cleanupSecret: input.cleanupSecret
    })
  });
}

export async function updateSiteLimits(input: {
  slug: string;
  cpu?: number;
  ramGi?: number;
  diskGi?: number;
}) {
  await controllerFetch(`/sites/${input.slug}/limits`, {
    method: "PATCH",
    body: JSON.stringify({
      cpu: input.cpu,
      ramGi: input.ramGi,
      diskGi: input.diskGi
    })
  });
}

export async function enableSiteDb(slug: string, dbName?: string) {
  await controllerFetch(`/sites/${slug}/db/enable`, {
    method: "POST",
    body: JSON.stringify({ dbName })
  });
}

export async function disableSiteDb(slug: string) {
  await controllerFetch(`/sites/${slug}/db/disable`, { method: "POST" });
}

export async function purgeSiteDb(slug: string) {
  await controllerFetch(`/sites/${slug}/db/purge`, {
    method: "POST",
    body: JSON.stringify({ confirm: "DELETE" })
  });
}

export async function enableSiteMail(slug: string, domain: string) {
  await controllerFetch(`/sites/${slug}/mail/enable`, {
    method: "POST",
    body: JSON.stringify({ domain })
  });
}

export async function disableSiteMail(slug: string) {
  await controllerFetch(`/sites/${slug}/mail/disable`, { method: "POST" });
}

export async function purgeSiteMail(slug: string) {
  await controllerFetch(`/sites/${slug}/mail/purge`, {
    method: "POST",
    body: JSON.stringify({ confirm: "DELETE" })
  });
}

export async function listSiteMailboxes(slug: string): Promise<string[]> {
  const res = await controllerFetch(`/sites/${slug}/mail/mailboxes`, { method: "GET" });
  const payload = await res.json();
  return Array.isArray(payload.mailboxes) ? payload.mailboxes : [];
}

export async function createSiteMailbox(input: {
  slug: string;
  localPart: string;
  password: string;
  quotaMb?: number;
}) {
  await controllerFetch(`/sites/${input.slug}/mail/mailboxes`, {
    method: "POST",
    body: JSON.stringify({
      localPart: input.localPart,
      password: input.password,
      quotaMb: input.quotaMb
    })
  });
}

export async function deleteSiteMailbox(slug: string, address: string) {
  await controllerFetch(`/sites/${slug}/mail/mailboxes/${encodeURIComponent(address)}`, {
    method: "DELETE"
  });
}

export async function listSiteAliases(slug: string): Promise<string[]> {
  const res = await controllerFetch(`/sites/${slug}/mail/aliases`, { method: "GET" });
  const payload = await res.json();
  return Array.isArray(payload.aliases) ? payload.aliases : [];
}

export async function createSiteAlias(input: {
  slug: string;
  sourceLocalPart: string;
  destination: string;
  active?: boolean;
}) {
  await controllerFetch(`/sites/${input.slug}/mail/aliases`, {
    method: "POST",
    body: JSON.stringify({
      sourceLocalPart: input.sourceLocalPart,
      destination: input.destination,
      active: input.active
    })
  });
}

export async function deleteSiteAlias(slug: string, source: string) {
  await controllerFetch(`/sites/${slug}/mail/aliases/${encodeURIComponent(source)}`, {
    method: "DELETE"
  });
}

export async function enableSiteDns(slug: string, domain: string, targetIp: string) {
  await controllerFetch(`/sites/${slug}/dns/enable`, {
    method: "POST",
    body: JSON.stringify({ domain, targetIp })
  });
}

export async function disableSiteDns(slug: string) {
  await controllerFetch(`/sites/${slug}/dns/disable`, { method: "POST" });
}

export async function purgeSiteDns(slug: string) {
  await controllerFetch(`/sites/${slug}/dns/purge`, {
    method: "POST",
    body: JSON.stringify({ confirm: "DELETE" })
  });
}

export async function enableSiteBackup(
  slug: string,
  retentionDays?: number,
  schedule?: string
) {
  await controllerFetch(`/sites/${slug}/backup/enable`, {
    method: "POST",
    body: JSON.stringify({ retentionDays, schedule })
  });
}

export async function disableSiteBackup(slug: string) {
  await controllerFetch(`/sites/${slug}/backup/disable`, { method: "POST" });
}

export async function updateSiteBackupConfig(
  slug: string,
  retentionDays?: number,
  schedule?: string
) {
  await controllerFetch(`/sites/${slug}/backup/config`, {
    method: "PATCH",
    body: JSON.stringify({ retentionDays, schedule })
  });
}

export async function runSiteBackup(slug: string) {
  await controllerFetch(`/sites/${slug}/backup/run`, { method: "POST" });
}

export type BackupSnapshot = {
  id: string;
  hasFiles: boolean;
  hasDb: boolean;
  sizeBytes?: number;
};

export async function listSiteBackupSnapshots(slug: string): Promise<BackupSnapshot[]> {
  const res = await controllerFetch(`/sites/${slug}/backup/snapshots`, { method: "GET" });
  const payload = await res.json();
  return Array.isArray(payload.items) ? payload.items : [];
}

export async function restoreSiteBackup(
  slug: string,
  snapshotId: string,
  restoreFiles: boolean,
  restoreDb: boolean
) {
  await controllerFetch(`/sites/${slug}/backup/restore`, {
    method: "POST",
    body: JSON.stringify({ snapshotId, restoreFiles, restoreDb })
  });
}

export async function purgeSiteBackup(slug: string) {
  await controllerFetch(`/sites/${slug}/backup/purge`, {
    method: "POST",
    body: JSON.stringify({ confirm: "DELETE" })
  });
}

export type PanelUser = {
  id: string;
  username: string;
  email: string;
  role: "admin" | "site";
  siteSlug?: string | null;
  active: boolean;
  createdAt: string;
};

export async function listUsers(): Promise<PanelUser[]> {
  const res = await controllerFetch("/users", { method: "GET" });
  const payload = await res.json();
  return Array.isArray(payload.users) ? payload.users : [];
}

export async function createUser(input: {
  username: string;
  email: string;
  password: string;
  role: "admin" | "site";
  siteSlug?: string;
}) {
  await controllerFetch("/users", {
    method: "POST",
    body: JSON.stringify(input)
  });
}

export async function setUserActive(id: string, active: boolean) {
  await controllerFetch(`/users/${id}`, {
    method: "PATCH",
    body: JSON.stringify({ active })
  });
}

export async function removeUser(id: string) {
  await controllerFetch(`/users/${id}`, { method: "DELETE" });
}

export async function logoutSession() {
  await controllerFetch("/auth/logout", { method: "POST" });
}
