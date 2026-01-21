import { NextResponse } from "next/server";

export async function POST(
  request: Request,
  { params }: { params: { id: string } }
): Promise<NextResponse> {
  const body = await request.json();
  // Mock deploy - in real implementation, this would call the controller
  return NextResponse.json({ ok: true, message: "Deploy triggered" });
}
