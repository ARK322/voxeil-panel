import { NextResponse } from "next/server";
import sitesData from "../../../../mock-data/sites.json";
import type { SiteDetail } from "../../../../src/lib/types";

export async function GET(
  request: Request,
  { params }: { params: { id: string } }
): Promise<NextResponse<SiteDetail>> {
  const id = params.id;
  const site = (sitesData as SiteDetail[]).find((s) => s.id === id);

  if (!site) {
    return NextResponse.json({ error: "Not found" } as any, { status: 404 });
  }

  const siteDetail: SiteDetail = {
    ...site,
    image: "nginx:latest",
    containerPort: 3000,
    env: [
      { key: "NODE_ENV", value: "production", isSecret: false },
      { key: "API_KEY", value: "***", isSecret: true },
    ],
    deployHistory: [
      {
        id: "deploy-1",
        timestamp: site.lastDeployAt || new Date().toISOString(),
        image: "nginx:latest",
        status: "success",
      },
    ],
  };

  return NextResponse.json(siteDetail);
}
