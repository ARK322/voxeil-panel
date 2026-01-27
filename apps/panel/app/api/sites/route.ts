import { NextResponse } from "next/server";
import type { Site } from "../../../src/lib/types";

export async function GET(): Promise<NextResponse<Site[]>> {
  // TODO: Connect to real controller API
  // const response = await fetch(`${process.env.CONTROLLER_API_URL}/sites`);
  // return NextResponse.json(await response.json());
  
  // Placeholder response
  return NextResponse.json([] as Site[]);
}

export async function POST(request: Request): Promise<NextResponse<Site>> {
  // TODO: Connect to real controller API
  // const body = await request.json();
  // const response = await fetch(`${process.env.CONTROLLER_API_URL}/sites`, {
  //   method: 'POST',
  //   body: JSON.stringify(body),
  // });
  // return NextResponse.json(await response.json(), { status: 201 });
  
  // Placeholder response
  const body = await request.json();
  return NextResponse.json({
    id: `site-${Date.now()}`,
    tenantId: body.tenantId || "user-1",
    name: body.name,
    slug: body.slug,
    primaryDomain: body.domain || "",
    domains: body.domain ? [body.domain] : [],
    tls: { enabled: false },
    status: "created",
  } as Site, { status: 201 });
}
