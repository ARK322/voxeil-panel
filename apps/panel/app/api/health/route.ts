import { NextResponse } from "next/server";
import type { HealthResponse } from "../../../src/lib/types";

export async function GET(): Promise<NextResponse<HealthResponse>> {
  // TODO: Connect to real controller API
  // const response = await fetch(`${process.env.CONTROLLER_API_URL}/health`);
  // return NextResponse.json(await response.json());
  
  // Placeholder response
  return NextResponse.json({
    status: "healthy",
    components: {
      controller: "healthy",
      postgres: "healthy",
      traefik: "healthy",
      certManager: "healthy"
    }
  } as HealthResponse);
}
