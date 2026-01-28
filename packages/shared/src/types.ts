// Shared types for Voxeil Panel (runtime-independent)

export type HealthStatus = "healthy" | "degraded" | "down";

export type HealthResponse = {
  status: HealthStatus;
  components: {
    controller: HealthStatus;
    postgres: HealthStatus;
    traefik: HealthStatus;
    certManager: HealthStatus;
  };
};

export type Tenant = {
  id: string;
  name: string;
  namespace: string;
  limits: {
    cpu: string;
    mem: string;
    storage: string;
  };
  domainsCount: number;
  sitesCount: number;
};

export type TenantDetail = {
  id: string;
  name: string;
  namespaces: string[];
  quotas: {
    cpu: { request: string; limit: string };
    memory: { request: string; limit: string };
    storage: { limit: string };
  };
  sites: Array<{
    id: string;
    name: string;
    primaryDomain: string;
    status: string;
  }>;
  mail: {
    domains: string[];
    mailboxesCount: number;
  };
  db: {
    databasesCount: number;
  };
};

export type Site = {
  id: string;
  tenantId: string;
  name: string;
  slug: string;
  primaryDomain: string;
  domains: string[];
  tls: {
    enabled: boolean;
    issuer?: string;
  };
  lastDeployAt?: string;
  status: "created" | "deployed" | "error";
};

export type SiteDetail = Site & {
  image?: string;
  containerPort?: number;
  env: Array<{ key: string; value: string; isSecret: boolean }>;
  deployHistory: Array<{
    id: string;
    timestamp: string;
    image: string;
    status: "success" | "failed";
  }>;
};

export type MailInfo = {
  uiUrl: string;
  status: "enabled" | "disabled";
  domains: Array<{
    domain: string;
    mailboxesCount: number;
    aliasesCount: number;
  }>;
};

export type DbInfo = {
  pgAdminUrl: string;
  status: "enabled" | "disabled";
  instances: Array<{
    id: string;
    name: string;
    host: string;
    port: number;
  }>;
};

export type DnsInfo = {
  status: "enabled" | "disabled";
  zones: Array<{
    domain: string;
    recordsCount: number;
  }>;
};

export type BackupInfo = {
  status: "enabled" | "disabled";
  lastBackupAt?: string;
  snapshots: Array<{
    id: string;
    timestamp: string;
    sizeBytes: number;
    type: "full" | "incremental";
  }>;
};

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

export type PanelUser = {
  id: string;
  username: string;
  email: string;
  role: "admin" | "site";
  siteSlug?: string | null;
  active: boolean;
  createdAt: string;
};

export type BackupSnapshot = {
  id: string;
  hasFiles: boolean;
  hasDb: boolean;
  sizeBytes?: number;
};
