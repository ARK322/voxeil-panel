import { z } from "zod";

export const RestoreFilesSchema = z.object({
  backupFile: z.string().min(1).optional(),
  latest: z.boolean().optional()
});

export const RestoreDbSchema = z.object({
  backupFile: z.string().min(1).optional(),
  latest: z.boolean().optional()
});

export const BackupEnableSchema = z.object({
  retentionDays: z.number().int().positive().optional(),
  schedule: z.string().min(1).optional()
});

export const BackupConfigSchema = z
  .object({
    retentionDays: z.number().int().positive().optional(),
    schedule: z.string().min(1).optional()
  })
  .refine((value) => Object.keys(value).length > 0, {
    message: "At least one backup setting must be provided"
  });

export const BackupRestoreSchema = z.object({
  snapshotId: z.string().min(1),
  restoreFiles: z.boolean().optional(),
  restoreDb: z.boolean().optional()
});

export type RestoreFilesInput = z.infer<typeof RestoreFilesSchema>;
export type RestoreDbInput = z.infer<typeof RestoreDbSchema>;
export type BackupEnableInput = z.infer<typeof BackupEnableSchema>;
export type BackupConfigInput = z.infer<typeof BackupConfigSchema>;
export type BackupRestoreInput = z.infer<typeof BackupRestoreSchema>;
