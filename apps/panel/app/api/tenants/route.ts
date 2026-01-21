import { NextResponse } from "next/server";
import tenantsData from "../../../mock-data/tenants.json";
import type { Tenant } from "../../../src/lib/types";

export async function GET(): Promise<NextResponse<Tenant[]>> {
  return NextResponse.json(tenantsData as Tenant[]);
}
