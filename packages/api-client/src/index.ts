// Typed API client for Voxeil Controller
// This package provides a typed client that can be used in both server and client contexts

import type {
  SiteInfo,
  PanelUser,
  BackupSnapshot,
} from "@voxeil/shared/types";

export type TokenGetter = () => string | null;

const DEFAULT_CONTROLLER_BASE =
  process.env.CONTROLLER_BASE_URL ?? "http://controller.platform.svc.cluster.local:8080";

type ControllerInit = RequestInit & { headers?: Record<string, string> };

function createControllerFetch(
  baseUrl: string,
  getToken: TokenGetter
) {
  return async function controllerFetch(path: string, init?: ControllerInit) {
    const token = getToken();
    if (!token) {
      throw new Error("Not authenticated.");
    }
    const headers = {
      ...(init?.headers ?? {}),
      "x-session-token": token,
      "content-type": init?.headers?.["content-type"] ?? "application/json"
    };

    const res = await fetch(`${baseUrl}${path}`, {
      ...init,
      headers
    });

    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`Controller error (${res.status}): ${text}`);
    }

    return res;
  };
}

export function createControllerClient(
  getToken: TokenGetter,
  baseUrl: string = DEFAULT_CONTROLLER_BASE
) {
  const fetch = createControllerFetch(baseUrl, getToken);

  return {
    sites: {
      list: (): Promise<SiteInfo[]> => fetch("/sites", { method: "GET" }).then(r => r.json()),
      create: (input: {
        domain: string;
        cpu: number;
        ramGi: number;
        diskGi: number;
        tlsEnabled?: boolean;
        tlsIssuer?: string;
      }) => fetch("/sites", {
        method: "POST",
        body: JSON.stringify(input)
      }).then(r => r.json()),
      delete: (slug: string) => fetch(`/sites/${slug}`, { method: "DELETE" }),
      enableGithub: (input: {
        slug: string;
        repo: string;
        branch?: string;
        workflow?: string;
        image: string;
        token: string;
        webhookSecret?: string;
      }) => fetch(`/sites/${input.slug}/github/enable`, {
        method: "POST",
        body: JSON.stringify({
          repo: input.repo,
          branch: input.branch,
          workflow: input.workflow,
          image: input.image,
          token: input.token,
          webhookSecret: input.webhookSecret
        })
      }),
      disableGithub: (slug: string) => fetch(`/sites/${slug}/github/disable`, { method: "POST" }),
      deployGithub: (input: {
        slug: string;
        ref?: string;
        image?: string;
        registryUsername?: string;
        registryToken?: string;
        registryServer?: string;
        registryEmail?: string;
      }) => fetch(`/sites/${input.slug}/github/deploy`, {
        method: "POST",
        body: JSON.stringify({
          ref: input.ref,
          image: input.image,
          registryUsername: input.registryUsername,
          registryToken: input.registryToken,
          registryServer: input.registryServer,
          registryEmail: input.registryEmail
        })
      }),
      saveRegistryCredentials: (input: {
        slug: string;
        registryUsername: string;
        registryToken: string;
        registryServer?: string;
        registryEmail?: string;
      }) => fetch(`/sites/${input.slug}/registry/credentials`, {
        method: "POST",
        body: JSON.stringify({
          registryUsername: input.registryUsername,
          registryToken: input.registryToken,
          registryServer: input.registryServer,
          registryEmail: input.registryEmail
        })
      }),
      deleteRegistryCredentials: (slug: string) => fetch(`/sites/${slug}/registry/credentials`, {
        method: "DELETE"
      }),
      updateTls: (input: {
        slug: string;
        enabled: boolean;
        issuer?: string;
        cleanupSecret?: boolean;
      }) => fetch(`/sites/${input.slug}/tls`, {
        method: "PATCH",
        body: JSON.stringify({
          enabled: input.enabled,
          issuer: input.issuer,
          cleanupSecret: input.cleanupSecret
        })
      }),
      updateLimits: (input: {
        slug: string;
        cpu?: number;
        ramGi?: number;
        diskGi?: number;
      }) => fetch(`/sites/${input.slug}/limits`, {
        method: "PATCH",
        body: JSON.stringify({
          cpu: input.cpu,
          ramGi: input.ramGi,
          diskGi: input.diskGi
        })
      }),
      enableDb: (slug: string, dbName?: string) => fetch(`/sites/${slug}/db/enable`, {
        method: "POST",
        body: JSON.stringify({ dbName })
      }),
      disableDb: (slug: string) => fetch(`/sites/${slug}/db/disable`, { method: "POST" }),
      purgeDb: (slug: string) => fetch(`/sites/${slug}/db/purge`, {
        method: "POST",
        body: JSON.stringify({ confirm: "DELETE" })
      }),
      enableMail: (slug: string, domain: string) => fetch(`/sites/${slug}/mail/enable`, {
        method: "POST",
        body: JSON.stringify({ domain })
      }),
      disableMail: (slug: string) => fetch(`/sites/${slug}/mail/disable`, { method: "POST" }),
      purgeMail: (slug: string) => fetch(`/sites/${slug}/mail/purge`, {
        method: "POST",
        body: JSON.stringify({ confirm: "DELETE" })
      }),
      listMailboxes: (slug: string): Promise<string[]> => fetch(`/sites/${slug}/mail/mailboxes`, { method: "GET" })
        .then(r => r.json())
        .then(payload => Array.isArray(payload.mailboxes) ? payload.mailboxes : []),
      createMailbox: (input: {
        slug: string;
        localPart: string;
        password: string;
        quotaMb?: number;
      }) => fetch(`/sites/${input.slug}/mail/mailboxes`, {
        method: "POST",
        body: JSON.stringify({
          localPart: input.localPart,
          password: input.password,
          quotaMb: input.quotaMb
        })
      }),
      deleteMailbox: (slug: string, address: string) => fetch(`/sites/${slug}/mail/mailboxes/${encodeURIComponent(address)}`, {
        method: "DELETE"
      }),
      listAliases: (slug: string): Promise<string[]> => fetch(`/sites/${slug}/mail/aliases`, { method: "GET" })
        .then(r => r.json())
        .then(payload => Array.isArray(payload.aliases) ? payload.aliases : []),
      createAlias: (input: {
        slug: string;
        sourceLocalPart: string;
        destination: string;
        active?: boolean;
      }) => fetch(`/sites/${input.slug}/mail/aliases`, {
        method: "POST",
        body: JSON.stringify({
          sourceLocalPart: input.sourceLocalPart,
          destination: input.destination,
          active: input.active
        })
      }),
      deleteAlias: (slug: string, source: string) => fetch(`/sites/${slug}/mail/aliases/${encodeURIComponent(source)}`, {
        method: "DELETE"
      }),
      enableDns: (slug: string, domain: string, targetIp: string) => fetch(`/sites/${slug}/dns/enable`, {
        method: "POST",
        body: JSON.stringify({ domain, targetIp })
      }),
      disableDns: (slug: string) => fetch(`/sites/${slug}/dns/disable`, { method: "POST" }),
      purgeDns: (slug: string) => fetch(`/sites/${slug}/dns/purge`, {
        method: "POST",
        body: JSON.stringify({ confirm: "DELETE" })
      }),
      enableBackup: (
        slug: string,
        retentionDays?: number,
        schedule?: string
      ) => fetch(`/sites/${slug}/backup/enable`, {
        method: "POST",
        body: JSON.stringify({ retentionDays, schedule })
      }),
      disableBackup: (slug: string) => fetch(`/sites/${slug}/backup/disable`, { method: "POST" }),
      updateBackupConfig: (
        slug: string,
        retentionDays?: number,
        schedule?: string
      ) => fetch(`/sites/${slug}/backup/config`, {
        method: "PATCH",
        body: JSON.stringify({ retentionDays, schedule })
      }),
      runBackup: (slug: string) => fetch(`/sites/${slug}/backup/run`, { method: "POST" }),
      listBackupSnapshots: (slug: string): Promise<BackupSnapshot[]> => fetch(`/sites/${slug}/backup/snapshots`, { method: "GET" })
        .then(r => r.json())
        .then(payload => Array.isArray(payload.items) ? payload.items : []),
      restoreBackup: (
        slug: string,
        snapshotId: string,
        restoreFiles: boolean,
        restoreDb: boolean
      ) => fetch(`/sites/${slug}/backup/restore`, {
        method: "POST",
        body: JSON.stringify({ snapshotId, restoreFiles, restoreDb })
      }),
      purgeBackup: (slug: string) => fetch(`/sites/${slug}/backup/purge`, {
        method: "POST",
        body: JSON.stringify({ confirm: "DELETE" })
      }),
    },
    security: {
      getAllowlist: (): Promise<string[]> => fetch("/security/allowlist", { method: "GET" })
        .then(r => r.json())
        .then(payload => Array.isArray(payload.items) ? payload.items : []),
      updateAllowlist: (items: string[]) => fetch("/security/allowlist", {
        method: "PUT",
        body: JSON.stringify({ items })
      }),
    },
    users: {
      list: (): Promise<PanelUser[]> => fetch("/users", { method: "GET" })
        .then(r => r.json())
        .then(payload => Array.isArray(payload.users) ? payload.users : []),
      create: (input: {
        username: string;
        email: string;
        password: string;
        role: "admin" | "site";
        siteSlug?: string;
      }) => fetch("/users", {
        method: "POST",
        body: JSON.stringify(input)
      }),
      setActive: (id: string, active: boolean) => fetch(`/users/${id}`, {
        method: "PATCH",
        body: JSON.stringify({ active })
      }),
      remove: (id: string) => fetch(`/users/${id}`, { method: "DELETE" }),
    },
    auth: {
      logout: () => fetch("/auth/logout", { method: "POST" }),
    },
  };
}

// Re-export types for convenience
export type { SiteInfo, PanelUser, BackupSnapshot } from "@voxeil/shared/types";
