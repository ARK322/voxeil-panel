import { z } from "zod";

export const RestoreFilesSchema = z.object({
  backupFile: z.string().min(1).optional(),
  latest: z.boolean().optional()
});

export const RestoreDbSchema = z.object({
  backupFile: z.string().min(1).optional(),
  latest: z.boolean().optional()
});

export type RestoreFilesInput = z.infer<typeof RestoreFilesSchema>;
export type RestoreDbInput = z.infer<typeof RestoreDbSchema>;
