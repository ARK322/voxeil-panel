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
    containerPort: z.number().int().positive(),
    uploadDirs: z.array(z.string().min(1)).optional()
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
    token: z.string().min(1),
    webhookSecret: z.string().min(1).optional()
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
