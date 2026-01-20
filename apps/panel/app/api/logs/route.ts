import { cookies } from "next/headers";

const CONTROLLER_BASE =
  process.env.CONTROLLER_BASE_URL ?? "http://controller.platform.svc.cluster.local:8080";

export async function GET(req: Request) {
  const { searchParams } = new URL(req.url);
  const slug = searchParams.get("slug")?.trim();
  if (!slug) {
    return new Response("slug is required", { status: 400 });
  }
  const token = cookies().get("vhp_panel_session")?.value;
  if (!token) {
    return new Response("unauthorized", { status: 401 });
  }
  const params = new URLSearchParams(searchParams);
  const res = await fetch(`${CONTROLLER_BASE}/sites/${slug}/logs/stream?${params.toString()}`, {
    headers: { "x-session-token": token }
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    return new Response(text || "log stream error", { status: res.status });
  }
  if (!res.body) {
    return new Response("log stream unavailable", { status: 502 });
  }
  return new Response(res.body, {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-cache"
    }
  });
}
