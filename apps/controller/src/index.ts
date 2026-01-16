import Fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import { z } from "zod";
import { getClients, LABELS } from "./k8s.js";
import { pickFreeNodePort } from "./ports.js";

const app = Fastify({ logger: true });

const ADMIN_API_KEY = process.env.ADMIN_API_KEY;
if (!ADMIN_API_KEY) {
  throw new Error("ADMIN_API_KEY env var is required (provided via Secret).");
}

app.addHook("onRequest", async (req: FastifyRequest, reply: FastifyReply) => {
  if (req.url.startsWith("/health")) return;
  const header = req.headers["x-api-key"];
  const provided = Array.isArray(header) ? header[0] : header;
  if (!provided || provided !== ADMIN_API_KEY) {
    return reply.code(401).send({ error: "unauthorized" });
  }
});

app.get("/health", async () => ({ ok: true }));

const CreateSiteBody = z.object({
  siteId: z.string().min(3).max(40).regex(/^[a-z0-9-]+$/),
  image: z.string().min(3),
  containerPort: z.number().int().positive().default(3000),
  replicas: z.number().int().min(1).max(5).default(1),
  env: z.record(z.string()).optional()
});

async function ensureTenantQuota(ns: string) {
  const { core } = getClients();
  const quotaBody = {
    metadata: { name: "site-quota" },
    spec: {
      hard: {
        "requests.cpu": "1",
        "requests.memory": "1Gi",
        "limits.cpu": "2",
        "limits.memory": "2Gi",
        "pods": "10",
        "services": "5",
        "configmaps": "10",
        "persistentvolumeclaims": "2"
      }
    }
  };
  try {
    await core.createNamespacedResourceQuota(ns, quotaBody as any);
  } catch (e: any) {
    if (e?.response?.statusCode !== 409) throw e;
  }
}

async function ensureTenantLimits(ns: string) {
  const { core } = getClients();
  const limitBody = {
    metadata: { name: "site-limits" },
    spec: {
      limits: [
        {
          type: "Container",
          default: { cpu: "500m", memory: "512Mi" },
          defaultRequest: { cpu: "100m", memory: "128Mi" },
          max: { cpu: "1000m", memory: "1Gi" },
          min: { cpu: "50m", memory: "64Mi" }
        }
      ]
    }
  };
  try {
    await core.createNamespacedLimitRange(ns, limitBody as any);
  } catch (e: any) {
    if (e?.response?.statusCode !== 409) throw e;
  }
}

async function ensureTenantNetworkPolicy(ns: string, siteId: string) {
  const { net } = getClients();
  const policyBody = {
    metadata: {
      name: "default-deny",
      labels: { [LABELS.siteId]: siteId }
    },
    spec: {
      podSelector: {},
      policyTypes: ["Ingress", "Egress"],
      ingress: [],
      // allow DNS only
      egress: [
        {
          to: [
            {
              namespaceSelector: {
                matchLabels: { "kubernetes.io/metadata.name": "kube-system" }
              },
              podSelector: { matchLabels: { "k8s-app": "kube-dns" } }
            }
          ],
          ports: [
            { protocol: "UDP", port: 53 },
            { protocol: "TCP", port: 53 }
          ]
        }
      ]
    }
  };
  try {
    await net.createNamespacedNetworkPolicy(ns, policyBody as any);
  } catch (e: any) {
    if (e?.response?.statusCode !== 409) throw e;
  }
}

async function ensureTenantIngressAllow(ns: string, siteId: string) {
  const { net } = getClients();
  const policyBody = {
    metadata: {
      name: "allow-all-ingress",
      labels: { [LABELS.siteId]: siteId }
    },
    spec: {
      podSelector: {},
      policyTypes: ["Ingress"],
      ingress: [{}] // allow all ingress to permit NodePort traffic
    }
  };
  try {
    await net.createNamespacedNetworkPolicy(ns, policyBody as any);
  } catch (e: any) {
    if (e?.response?.statusCode !== 409) throw e;
  }
}

app.post("/sites", async (req: FastifyRequest, reply: FastifyReply) => {
  const body = CreateSiteBody.parse(req.body);
  const ns = `tenant-${body.siteId}`;

  const { core, apps } = getClients();

  // 1) Namespace
  try {
    await core.createNamespace({
      metadata: {
        name: ns,
        labels: {
          [LABELS.managedBy]: LABELS.managedBy,
          [LABELS.siteId]: body.siteId
        }
      }
    });
  } catch (e: any) {
    if (e?.response?.statusCode !== 409) throw e; // 409 = already exists
  }

  // baseline security for tenant
  await Promise.all([
    ensureTenantQuota(ns),
    ensureTenantLimits(ns),
    ensureTenantNetworkPolicy(ns, body.siteId),
    ensureTenantIngressAllow(ns, body.siteId)
  ]);

  // 2) Deployment
  const deployName = "site";
  await apps.createNamespacedDeployment(ns, {
    metadata: {
      name: deployName,
      labels: { app: "site", [LABELS.siteId]: body.siteId }
    },
    spec: {
      replicas: body.replicas,
      selector: { matchLabels: { app: "site" } },
      template: {
        metadata: {
          labels: { app: "site", [LABELS.siteId]: body.siteId }
        },
        spec: {
          containers: [
            {
              name: "site",
              image: body.image,
              ports: [{ containerPort: body.containerPort }],
              env: Object.entries(body.env ?? {}).map(([name, value]) => ({ name, value })),
              resources: {
                requests: { cpu: "100m", memory: "128Mi" },
                limits: { cpu: "500m", memory: "512Mi" }
              }
            }
          ]
        }
      }
    }
  }).catch((e: any) => {
    if (e?.response?.statusCode === 409) return;
    throw e;
  });

  // 3) Service NodePort
  const nodePort = await pickFreeNodePort();
  const svcName = "site";
  await core.createNamespacedService(ns, {
    metadata: {
      name: svcName,
      labels: { [LABELS.siteId]: body.siteId }
    },
    spec: {
      type: "NodePort",
      selector: { app: "site" },
      ports: [
        {
          name: "http",
          port: body.containerPort,
          targetPort: body.containerPort,
          nodePort
        }
      ]
    }
  }).catch((e: any) => {
    if (e?.response?.statusCode !== 409) throw e;
  });

  return reply.send({
    siteId: body.siteId,
    namespace: ns,
    nodePort,
    url: `http://<VPS_IP>:${nodePort}`
  });
});

app.get("/sites", async () => {
  const { core } = getClients();
  const nss = await core.listNamespace(
    undefined,
    undefined,
    undefined,
    undefined,
    `${LABELS.managedBy}=${LABELS.managedBy}`
  );

  return nss.body.items.map((ns: any) => ({
    namespace: ns.metadata?.name,
    siteId: ns.metadata?.labels?.[LABELS.siteId] ?? null
  }));
});

app.delete("/sites/:siteId", async (req: FastifyRequest, reply: FastifyReply) => {
  const siteId = z.string().parse((req.params as any).siteId);
  const ns = `tenant-${siteId}`;

  const { core } = getClients();
  await core.deleteNamespace(ns).catch((e: any) => {
    if (e?.response?.statusCode === 404) return;
    throw e;
  });

  return reply.send({ ok: true, deleted: ns });
});

const port = Number(process.env.PORT ?? 8080);
app.listen({ host: "0.0.0.0", port });
