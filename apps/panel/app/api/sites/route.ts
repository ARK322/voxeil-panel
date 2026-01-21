import { NextResponse } from "next/server";
import sitesData from "../../../mock-data/sites.json";
import type { Site } from "../../../src/lib/types";

export async function GET(): Promise<NextResponse<Site[]>> {
  return NextResponse.json(sitesData as Site[]);
}

export async function POST(request: Request): Promise<NextResponse<Site>> {
  const body = await request.json();
  // Mock create
  const newSite: Site = {
    id: `site-${Date.now()}`,
    tenantId: body.tenantId || "user-1",
    name: body.name,
    slug: body.slug,
    primaryDomain: body.domain || "",
    domains: body.domain ? [body.domain] : [],
    tls: { enabled: false },
    status: "created",
  };
  return NextResponse.json(newSite, { status: 201 });
}
