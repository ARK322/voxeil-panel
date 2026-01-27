import { NextResponse } from "next/server";
import type { Tenant } from "../../../src/lib/types";

export async function GET(): Promise<NextResponse<Tenant[]>> {
  // TODO: Connect to real controller API
  // const response = await fetch(`${process.env.CONTROLLER_API_URL}/tenants`);
  // return NextResponse.json(await response.json());
  
  // Placeholder response
  return NextResponse.json([] as Tenant[]);
}
