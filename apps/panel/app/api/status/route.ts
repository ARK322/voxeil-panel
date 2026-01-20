const CONTROLLER_BASE =
  process.env.CONTROLLER_BASE_URL ?? "http://controller.platform.svc.cluster.local:8080";

export async function GET() {
  let controllerOk = false;
  try {
    const res = await fetch(`${CONTROLLER_BASE}/health`, { cache: "no-store" });
    controllerOk = res.ok;
  } catch {
    controllerOk = false;
  }
  return new Response(JSON.stringify({ ok: true, controllerOk }), {
    headers: { "content-type": "application/json" }
  });
}
