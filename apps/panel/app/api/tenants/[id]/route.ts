import { NextResponse } from "next/server";
import type { TenantDetail } from "../../../../src/lib/types";

export async function GET(
  request: Request,
  { params }: { params: { id: string } }
): Promise<NextResponse<TenantDetail>> {
  const id = params.id;

  // Mock data
  const tenantDetail: TenantDetail = {
    id,
    name: id === "user-1" ? "Acme Corp" : "Startup Inc",
    namespaces: [`user-${id}`],
    quotas: {
      cpu: { request: "500m", limit: "2" },
      memory: { request: "512Mi", limit: "4Gi" },
      storage: { limit: "50Gi" },
    },
    sites: [
      {
        id: "site-1",
        name: "My App",
        primaryDomain: "app.example.com",
        status: "deployed",
      },
    ],
    mail: {
      domains: id === "user-1" ? ["example.com"] : [],
      mailboxesCount: id === "user-1" ? 5 : 0,
    },
    db: {
      databasesCount: id === "user-1" ? 2 : 0,
    },
  };

  return NextResponse.json(tenantDetail);
}
