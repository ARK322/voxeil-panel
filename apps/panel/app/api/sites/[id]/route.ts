import { NextResponse } from "next/server";
import type { SiteDetail } from "../../../../src/lib/types";

export async function GET(
  request: Request,
  { params }: { params: { id: string } }
): Promise<NextResponse<SiteDetail>> {
  // TODO: Connect to real controller API
  // const response = await fetch(`${process.env.CONTROLLER_API_URL}/sites/${params.id}`);
  // if (!response.ok) {
  //   return NextResponse.json({ error: "Not found" } as any, { status: 404 });
  // }
  // return NextResponse.json(await response.json());
  
  // Placeholder response
  return NextResponse.json({ error: "Not found" } as any, { status: 404 });
}
