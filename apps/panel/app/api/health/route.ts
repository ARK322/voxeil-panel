import { NextResponse } from "next/server";
import healthData from "../../../mock-data/health.json";
import type { HealthResponse } from "../../../src/lib/types";

export async function GET(): Promise<NextResponse<HealthResponse>> {
  return NextResponse.json(healthData as HealthResponse);
}
