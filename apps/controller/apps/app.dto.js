import { z } from "zod";

export const CreateAppSchema = z.object({
    slug: z.string().min(1).max(63).regex(/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, {
        message: "Slug must be DNS-1123 compliant (lowercase alphanumeric and hyphens, cannot start/end with hyphen)"
    }),
    domain: z.string().min(1).optional(),
    repoUrl: z.string().url().optional(),
    image: z.string().min(1).optional(),
    env: z.record(z.string(), z.any()).optional()
});

export const DeployAppSchema = z.object({
    image: z.string().min(1).optional(),
    containerPort: z.number().int().positive().optional(),
    uploadDirs: z.array(z.string().min(1)).optional()
});
