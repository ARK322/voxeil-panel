import { NextResponse } from "next/server";
import type { DbInfo } from "../../../src/lib/types";

export async function GET(): Promise<NextResponse<DbInfo>> {
  const dbInfo: DbInfo = {
    pgAdminUrl: "https://db.domain.com",
    status: "enabled",
    instances: [
      {
        id: "postgres-1",
        name: "main-db",
        host: "postgres.infra-db.svc.cluster.local",
        port: 5432,
      },
    ],
  };
  return NextResponse.json(dbInfo);
}
