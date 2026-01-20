import { z } from "zod";

export const TlsIssuerSchema = z.enum(["letsencrypt-staging", "letsencrypt-prod"]);

export const CreateSiteSchema = z.object({
  domain: z.string().min(1),
  cpu: z.number().int().positive(),
  ramGi: z.number().int().positive(),
  diskGi: z.number().int().positive(),
  tlsEnabled: z.boolean().optional(),
  tlsIssuer: TlsIssuerSchema.optional()
});

export const PatchLimitsSchema = z
  .object({
    cpu: z.number().int().positive().optional(),
    ramGi: z.number().int().positive().optional(),
    diskGi: z.number().int().positive().optional()
  })
  .refine((value) => Object.keys(value).length > 0, {
    message: "At least one limit must be provided"
  });

export const DeploySiteSchema = z.object({
  image: z.string().min(1),
  containerPort: z.number().int().positive()
});

export const PatchTlsSchema = z.object({
  enabled: z.boolean(),
  issuer: TlsIssuerSchema.optional(),
  cleanupSecret: z.boolean().optional()
});

export const ConfirmDeleteSchema = z.object({
  confirm: z.literal("DELETE")
});

export const MailEnableSchema = z.object({
  domain: z.string().min(1)
});

export const DnsEnableSchema = z.object({
  domain: z.string().min(1),
  targetIp: z.string().min(1)
});

export const GithubEnableSchema = z.object({
  repo: z.string().min(1),
  branch: z.string().min(1).optional(),
  workflow: z.string().min(1).optional(),
  image: z.string().min(1),
  token: z.string().min(1)
});

export const GithubDeploySchema = z.object({
  ref: z.string().min(1).optional(),
  image: z.string().min(1).optional(),
  registryUsername: z.string().min(1).optional(),
  registryToken: z.string().min(1).optional(),
  registryServer: z.string().min(1).optional(),
  registryEmail: z.string().min(1).optional()
});

export const DbEnableSchema = z.object({
  dbName: z.string().min(1).optional()
});

export const MailboxCreateSchema = z.object({
  localPart: z.string().min(1),
  password: z.string().min(1),
  quotaMb: z.number().int().positive().optional()
});

export const AliasCreateSchema = z.object({
  sourceLocalPart: z.string().min(1),
  destination: z.string().min(1),
  active: z.boolean().optional()
});

export type CreateSiteInput = z.infer<typeof CreateSiteSchema>;
export type PatchLimitsInput = z.infer<typeof PatchLimitsSchema>;
export type DeploySiteInput = z.infer<typeof DeploySiteSchema>;
export type PatchTlsInput = z.infer<typeof PatchTlsSchema>;
export type ConfirmDeleteInput = z.infer<typeof ConfirmDeleteSchema>;
export type MailEnableInput = z.infer<typeof MailEnableSchema>;
export type DnsEnableInput = z.infer<typeof DnsEnableSchema>;
export type GithubEnableInput = z.infer<typeof GithubEnableSchema>;
export type GithubDeployInput = z.infer<typeof GithubDeploySchema>;
export type DbEnableInput = z.infer<typeof DbEnableSchema>;
export type MailboxCreateInput = z.infer<typeof MailboxCreateSchema>;
export type AliasCreateInput = z.infer<typeof AliasCreateSchema>;

export type SiteLimits = {
  cpu: number;
  ramGi: number;
  diskGi: number;
  pods: 1;
};

export type CreateSiteResponse = {
  domain: string;
  slug: string;
  namespace: string;
  limits: SiteLimits;
};

export type SiteLimitsResponse = {
  slug: string;
  namespace: string;
  limits: SiteLimits;
};

export type DeploySiteResponse = {
  slug: string;
  namespace: string;
  image: string;
  containerPort: number;
};

export type PatchTlsResponse = {
  ok: true;
  slug: string;
  tlsEnabled: boolean;
  issuer: string;
};

export type SiteListItem = {
  slug: string;
  namespace: string;
  ready: boolean;
  domain?: string;
  image?: string;
  containerPort?: number;
  tlsEnabled?: boolean;
  tlsIssuer?: string;
  dnsEnabled?: boolean;
  dnsDomain?: string;
  dnsTarget?: string;
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
  backupEnabled?: boolean;
  backupRetentionDays?: number;
  backupSchedule?: string;
  backupLastRunAt?: string;
  cpu?: number;
  ramGi?: number;
  diskGi?: number;
};
