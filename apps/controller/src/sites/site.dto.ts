import { z } from "zod";

export const CreateSiteSchema = z.object({
  domain: z.string().min(1),
  cpu: z.number().int().positive(),
  ramGi: z.number().int().positive(),
  diskGi: z.number().int().positive(),
  tlsEnabled: z.boolean().optional()
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

export const TlsIssuerSchema = z.enum(["letsencrypt-staging", "letsencrypt-prod"]);

export const PatchTlsSchema = z.object({
  enabled: z.boolean(),
  issuer: TlsIssuerSchema.optional()
});

export type CreateSiteInput = z.infer<typeof CreateSiteSchema>;
export type PatchLimitsInput = z.infer<typeof PatchLimitsSchema>;
export type DeploySiteInput = z.infer<typeof DeploySiteSchema>;
export type PatchTlsInput = z.infer<typeof PatchTlsSchema>;

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
  cpu?: number;
  ramGi?: number;
  diskGi?: number;
};
