import { getClients } from "./k8s.js";

const DEFAULT_MIN = 31000;
const DEFAULT_MAX = 31999;

function parseRange() {
  const min = Number(process.env.SITE_NODEPORT_START ?? DEFAULT_MIN);
  const max = Number(process.env.SITE_NODEPORT_END ?? DEFAULT_MAX);
  if (!Number.isInteger(min) || !Number.isInteger(max) || min < 30000 || max <= min) {
    throw new Error("Invalid NodePort range; check SITE_NODEPORT_START/END env vars.");
  }
  return { min, max };
}

export async function pickFreeNodePort(): Promise<number> {
  const { min, max } = parseRange();
  const { core } = getClients();
  const svcList = await core.listServiceForAllNamespaces();

  const used = new Set<number>();
  for (const svc of svcList.body.items) {
    for (const p of svc.spec?.ports ?? []) {
      if (typeof p.nodePort === "number") used.add(p.nodePort);
    }
  }

  for (let p = min; p <= max; p++) {
    if (!used.has(p)) return p;
  }
  throw new Error(`No free NodePort in range ${min}-${max}`);
}
