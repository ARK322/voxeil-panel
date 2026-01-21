import { NextResponse } from "next/server";
import type { BackupInfo } from "../../../src/lib/types";

export async function GET(): Promise<NextResponse<BackupInfo>> {
  const backupInfo: BackupInfo = {
    status: "enabled",
    lastBackupAt: "2024-01-15T03:00:00Z",
    snapshots: [
      {
        id: "snapshot-1",
        timestamp: "2024-01-15T03:00:00Z",
        sizeBytes: 1024 * 1024 * 500, // 500MB
        type: "full",
      },
      {
        id: "snapshot-2",
        timestamp: "2024-01-14T03:00:00Z",
        sizeBytes: 1024 * 1024 * 100, // 100MB
        type: "incremental",
      },
    ],
  };
  return NextResponse.json(backupInfo);
}
