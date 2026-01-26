import { cookies } from "next/headers";

const CONTROLLER_BASE =
  process.env.CONTROLLER_BASE_URL ?? "http://controller.platform.svc.cluster.local:8080";

export async function GET() {
  const token = cookies().get("vhp_panel_session")?.value;
  if (!token) {
    return new Response("unauthorized", { status: 401 });
  }

  const res = await fetch(`${CONTROLLER_BASE}/admin/security/logs`, {
    headers: { "x-session-token": token },
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    return new Response(text || "Failed to fetch security logs", { status: res.status });
  }

  const data = await res.json();
  return Response.json(data);
}
