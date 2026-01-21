import { NextResponse } from "next/server";
import type { DnsInfo } from "../../../src/lib/types";

export async function GET(): Promise<NextResponse<DnsInfo>> {
  const dnsInfo: DnsInfo = {
    status: "enabled",
    zones: [
      {
        domain: "example.com",
        recordsCount: 10,
      },
    ],
  };
  return NextResponse.json(dnsInfo);
}
